defmodule Minted.Telemetry.Health.Cache do
  @moduledoc """
  Event-subscribed GenServer that caches cross-domain health state.

  Replaces Manager/Exporter's direct polling of other domains
  with cached reads populated via EventBus subscriptions and initial facade
  bootstrap.

  ## Cached Keys

  - `:proof_of_reserves` — from `ReservesEvents.ProofGenerated`
  - `:liquidity_status` — from `LiquidityLow`/`LiquidityCritical`/`LiquidityRecovered`
  - `:active_keyset` — from `KeysetRotated`
  - `:double_spend_count` — from `DoubleSpendDetected`
  - `:backup_age` — from backup file mtime checks
  - `:spent_count` — from periodic telemetry poll
  - `:rate_limiter_rejections` — placeholder for rate limit events
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Events.Reserves, as: ReservesEvents

  alias Minted.Events.Telemetry, as: TelemetryEvents

  @table Minted.Telemetry.Health.Cache
  @poll_interval_ms 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the cached value for the given key, or `:unknown` if not yet populated.
  """
  @spec get(atom()) :: term()
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    subscribe_to_events()
    bootstrap_from_facades()
    schedule_poll()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_spent_count()
    bootstrap_liquidity()
    schedule_poll()
    {:noreply, state}
  end

  # --- Reserves events ---

  def handle_info(%ReservesEvents.ProofGenerated{} = event, state) do
    :ets.insert(
      @table,
      {:proof_of_reserves,
       %{
         proof_id: event.proof_id,
         ratio: event.ratio,
         status: event.status,
         timestamp: event.timestamp
       }}
    )

    {:noreply, state}
  end

  # --- Lightning liquidity events ---

  def handle_info(%LightningEvents.LiquidityLow{} = event, state) do
    :ets.insert(
      @table,
      {:liquidity_status,
       %{
         balance_sats: event.balance_sats,
         status: :low,
         timestamp: event.timestamp
       }}
    )

    {:noreply, state}
  end

  def handle_info(%LightningEvents.LiquidityCritical{} = event, state) do
    :ets.insert(
      @table,
      {:liquidity_status,
       %{
         balance_sats: event.balance_sats,
         status: :critical,
         timestamp: event.timestamp
       }}
    )

    {:noreply, state}
  end

  def handle_info(%LightningEvents.LiquidityRecovered{} = event, state) do
    :ets.insert(
      @table,
      {:liquidity_status,
       %{
         balance_sats: event.balance_sats,
         status: :healthy,
         timestamp: event.timestamp
       }}
    )

    {:noreply, state}
  end

  # --- Storage events ---

  def handle_info(%TelemetryEvents.KeysetRotated{} = event, state) do
    :ets.insert(
      @table,
      {:active_keyset,
       %{
         new_keyset_id: event.new_keyset_id,
         timestamp: event.timestamp
       }}
    )

    {:noreply, state}
  end

  # --- Mint events ---

  def handle_info(%MintEvents.DoubleSpendDetected{}, state) do
    current =
      case :ets.lookup(@table, :double_spend_count) do
        [{:double_spend_count, count}] -> count
        [] -> 0
      end

    :ets.insert(@table, {:double_spend_count, current + 1})
    {:noreply, state}
  end

  def handle_info(%MintEvents.OrphanDepositReconciled{}, state) do
    current =
      case :ets.lookup(@table, :orphan_burns_total) do
        [{:orphan_burns_total, count}] -> count
        [] -> 0
      end

    :ets.insert(@table, {:orphan_burns_total, current + 1})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp subscribe_to_events do
    EventBus.subscribe(ReservesEvents.ProofGenerated)
    EventBus.subscribe(LightningEvents.LiquidityLow)
    EventBus.subscribe(LightningEvents.LiquidityCritical)
    EventBus.subscribe(LightningEvents.LiquidityRecovered)
    EventBus.subscribe(TelemetryEvents.KeysetRotated)
    EventBus.subscribe(MintEvents.DoubleSpendDetected)
    EventBus.subscribe(MintEvents.OrphanDepositReconciled)
  rescue
    e ->
      Logger.warning("Cache: event subscription failed: #{inspect(e)}")
  end

  defp bootstrap_from_facades do
    bootstrap_proof_of_reserves()
    bootstrap_liquidity()
    bootstrap_epoch()
    bootstrap_active_keyset()
    bootstrap_backup_list()
    poll_spent_count()
    :ets.insert(@table, {:double_spend_count, 0})
  end

  defp bootstrap_proof_of_reserves do
    case Minted.Reserves.Facade.latest_proof() do
      nil ->
        :ok

      proof ->
        snap = Map.get(proof, :snapshot, %{})

        :ets.insert(
          @table,
          {:proof_of_reserves,
           %{
             proof_id: Map.get(proof, :id),
             ratio: Map.get(snap, :reserve_ratio),
             status: :bootstrapped,
             timestamp: DateTime.utc_now()
           }}
        )
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp bootstrap_liquidity do
    {balance, status} = Minted.Lightning.Facade.liquidity_status()

    :ets.insert(
      @table,
      {:liquidity_status,
       %{
         balance_sats: balance,
         status: status,
         timestamp: DateTime.utc_now()
       }}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp bootstrap_epoch do
    # Epoch ID is unused; cached as 0 for schema compatibility.
    :ets.insert(@table, {:epoch_id, 0})
  end

  defp bootstrap_active_keyset do
    case Minted.Storage.Facade.get_active_keyset() do
      [keyset | _] ->
        :ets.insert(
          @table,
          {:active_keyset,
           %{
             new_keyset_id: Map.get(keyset, :id),
             timestamp: DateTime.utc_now()
           }}
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp bootstrap_backup_list do
    backup_dir = Minted.Storage.Facade.backup_dir()

    case File.ls(backup_dir) do
      {:ok, files} ->
        latest =
          files
          |> Enum.filter(&String.starts_with?(&1, "minted-backup-"))
          |> Enum.sort(:desc)
          |> List.first()

        if latest do
          path = Path.join(backup_dir, latest)

          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{mtime: mtime}} ->
              :ets.insert(@table, {:backup_age, %{path: path, mtime: mtime}})

            _ ->
              :ok
          end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp poll_spent_count do
    count = Minted.Mint.Facade.spent_count()
    :ets.insert(@table, {:spent_count, count})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
