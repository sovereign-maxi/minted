defmodule Minted.Telemetry.Events.Stream do
  @moduledoc """
  Batches domain events every 100ms and broadcasts privacy-safe events
  to the `telemetry:stream` PubSub topic for LiveView dashboards.

  All events are sanitized — no token secrets, circuit IDs, blinding
  factors, or individual user data are included.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.{Lightning, Mint, Reserves, Storage}

  @event_modules [
    Mint.TokensMinted,
    Mint.TokensBurned,
    Mint.TokensSwapped,
    Mint.QuoteCreated,
    Lightning.InvoicePaid,
    Lightning.InvoiceExpired,
    Lightning.LiquidityLow,
    Lightning.LiquidityCritical,
    Lightning.LiquidityRecovered,
    Reserves.ProofGenerated,
    Storage.LegacyKeyDecryptFallback
  ]

  # Pre-create underscored atoms for all known event types so that
  # safe_to_atom/1 can use String.to_existing_atom/1 at runtime.
  # Storing them in a module attribute embeds them in the literal pool.
  @known_event_types Map.new(@event_modules, fn mod ->
                       name = mod |> Module.split() |> List.last() |> Macro.underscore()
                       {name, String.to_atom(name)}
                     end)

  @safe_fields MapSet.new([
                 :aad,
                 :amount,
                 :keyset_id,
                 :quote_id,
                 :epoch_id,
                 :status,
                 :ratio,
                 :balance_sats,
                 :duration_ms,
                 :count,
                 :state,
                 :proof_id,
                 :amount_sats
               ])

  @max_batch_size 100

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Minted.PubSub, "telemetry:stream")
  end

  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(Minted.PubSub, "telemetry:stream")
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    batch_ms = Keyword.get(opts, :batch_ms, get_config(:stream_batch_ms, 100))

    Enum.each(@event_modules, &EventBus.subscribe/1)
    schedule_flush(batch_ms)

    {:ok, %{batch: [], batch_ms: batch_ms}}
  end

  @impl true
  def handle_info(%{__struct__: _} = event, state) do
    sanitized = sanitize_event(event)
    batch = [sanitized | state.batch]
    batch_len = length(batch)

    batch =
      if batch_len > @max_batch_size do
        dropped = batch_len - @max_batch_size

        Logger.warning("Stream: dropped #{dropped} event(s) (batch overflow)")

        :telemetry.execute(
          [:minted, :event_stream, :overflow],
          %{dropped: dropped}
        )

        Enum.take(batch, @max_batch_size)
      else
        batch
      end

    {:noreply, %{state | batch: batch}}
  end

  def handle_info(:flush, %{batch: []} = state) do
    schedule_flush(state.batch_ms)
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    events = Enum.reverse(state.batch)

    Phoenix.PubSub.broadcast(
      Minted.PubSub,
      "telemetry:stream",
      {:telemetry_events, events}
    )

    schedule_flush(state.batch_ms)
    {:noreply, %{state | batch: []}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_flush(batch_ms) do
    Process.send_after(self(), :flush, batch_ms)
  end

  defp sanitize_event(%{__struct__: module} = event) do
    # M17: Use to_existing_atom to prevent atom table exhaustion from
    # untrusted module names. Module names are compile-time atoms so
    # their underscored form is guaranteed to already exist.
    type =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> safe_to_atom()

    topic =
      module
      |> Module.split()
      |> Enum.drop(2)
      |> Enum.take(1)
      |> Enum.map_join(":", &Macro.underscore/1)

    event
    |> Map.from_struct()
    |> Map.take(MapSet.to_list(@safe_fields))
    |> Map.put(:type, type)
    |> Map.put(:topic, topic)
    |> Map.put(:timestamp, System.system_time(:millisecond))
  end

  # M17: Safe atom conversion — looks up known event types first, then falls back
  # to existing atoms. Returns string for unknown types to prevent atom table exhaustion.
  defp safe_to_atom(str) do
    case Map.fetch(@known_event_types, str) do
      {:ok, atom} -> atom
      :error -> String.to_existing_atom(str)
    end
  rescue
    ArgumentError ->
      Logger.warning("Stream: unexpected event type not in atom table: #{str}")
      str
  end

  defp get_config(key, default) do
    Application.get_env(:minted, :telemetry, [])
    |> Keyword.get(key, default)
  end
end
