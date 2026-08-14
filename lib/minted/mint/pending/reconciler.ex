defmodule Minted.Mint.Pending.Reconciler do
  @moduledoc """
  Periodic sweep that closes the phantom-liability hole left when a
  client never ACKs deposit signatures.

  Background: signing writes `:tokens_minted` to the WAL before the
  client confirms storage. If the client drops the signatures (browser
  crash, never returns, etc.) the mint's liability counter shows
  outstanding tokens that no holder can ever redeem. Without a sweep,
  this drift grows over time.

  Reconciliation: for every entry in `Pending` older than the configured
  threshold, write a compensating `:tokens_burned` to the WAL and delete
  the entry. The orphaned signatures are now matched by an offsetting
  burn — outstanding == minted - burned reads as 0 for that quote, which
  is the correct economic picture (no holder owns the tokens; they're
  effectively destroyed).

  The sweep is conservative: only entries strictly older than the
  threshold are touched, giving slow clients ample time to ACK on
  their own. Re-run is safe: the recovery dedups orphan burns by
  `quote_id + reason`, so a Reconciler crash between the WAL append
  and `Pending.delete` cannot double-count.

  ## Configuration

      config :minted, Minted.Mint.Pending.Reconciler,
        sweep_interval_ms: 60_000,
        reconcile_after_ms: 3_600_000
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Mint.Pending
  alias Minted.Storage.Facade, as: StorageFacade

  @default_sweep_interval_ms 60_000
  @default_reconcile_after_ms 60 * 60 * 1_000

  # Phoenix.PubSub topic that wallet LiveView sessions subscribe to so
  # they can clean up client-side `_blindingStates` when a deposit is
  # reconciled. Connected sessions receive a server-pushed
  # `wallet:quote_expired` event; disconnected sessions catch up via
  # the client-side retry counter.
  @pubsub_topic "wallet:reconciled"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate sweep. Returns the number of entries
  reconciled. Used by tests and by an operator iex session.
  """
  @spec sweep_now() :: non_neg_integer()
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now)
  end

  @doc "Topic emitted on Phoenix.PubSub when an entry is reconciled."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @impl true
  def init(opts) do
    config = Application.get_env(:minted, __MODULE__, [])

    interval =
      Keyword.get(opts, :sweep_interval_ms) ||
        Keyword.get(config, :sweep_interval_ms, @default_sweep_interval_ms)

    threshold =
      Keyword.get(opts, :reconcile_after_ms) ||
        Keyword.get(config, :reconcile_after_ms, @default_reconcile_after_ms)

    schedule_sweep(interval)

    {:ok, %{interval: interval, threshold: threshold}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.threshold)
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, sweep(state.threshold), state}
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp sweep(threshold) do
    cutoff = System.system_time(:millisecond) - threshold
    expired = Pending.expired_before(cutoff)

    {ok, failed} =
      Enum.reduce(expired, {0, 0}, fn entry, {ok, failed} ->
        case safe_reconcile(entry) do
          :ok -> {ok + 1, failed}
          :error -> {ok, failed + 1}
        end
      end)

    if ok > 0 or failed > 0 do
      Logger.warning("Reconciler: sweep complete, ok=#{ok} failed=#{failed} threshold_ms=#{threshold}")
    end

    :telemetry.execute(
      [:minted, :mint, :reconciler, :sweep],
      %{ok_count: ok, failed_count: failed, expired_count: length(expired)},
      %{threshold_ms: threshold}
    )

    ok + failed
  end

  # Catches exceptions from a single reconcile so one bad entry can't
  # crash the GenServer mid-sweep and leave the remaining entries
  # unreconciled until the next tick.
  defp safe_reconcile(entry) do
    reconcile(entry)
    :ok
  rescue
    e ->
      Logger.error("Reconciler: reconcile raised, entry=#{inspect(entry)} error=#{inspect(e)}")
      :error
  catch
    kind, reason ->
      Logger.error("Reconciler: reconcile #{kind}, entry=#{inspect(entry)} reason=#{inspect(reason)}")
      :error
  end

  defp reconcile({quote_id, %{total_amount: amount}}) when is_integer(amount) and amount > 0 do
    Logger.warning(
      "Reconciler: orphan deposit, quote_id=#{quote_id} amount=#{amount} — " <>
        "writing compensating :tokens_burned"
    )

    # WAL write first. If we crash here, the next sweep re-runs the
    # same entry — recovery dedups by {quote_id, :orphaned_deposit} so
    # the second WAL append doesn't double-count the burn.
    #
    # `keyset_id: nil` is a deliberate sentinel: this burn isn't tied
    # to any active keyset (the original signing keyset may have been
    # rotated out by the time we reconcile).
    case StorageFacade.write_wal(:tokens_burned, %{
           amount: amount,
           keyset_id: nil,
           reason: :orphaned_deposit,
           quote_id: quote_id
         }) do
      :ok ->
        Pending.force_delete(quote_id)
        broadcast_reconciled(quote_id)

        now = DateTime.utc_now()

        # Publish TokensBurned in addition to OrphanDepositReconciled
        # so the live liability counter reflects the burn immediately.
        # Without this the counter drifted overstated until a from-
        # scratch WAL rebuild — which only fires when every counter
        # already reads zero (never on a real restart).
        EventBus.publish(%MintEvents.TokensBurned{
          amount: amount,
          count: 1,
          timestamp: now
        })

        EventBus.publish(%MintEvents.OrphanDepositReconciled{
          quote_id: quote_id,
          amount: amount,
          timestamp: now
        })

      {:error, reason} ->
        Logger.error(
          "Reconciler: WAL write failed quote_id=#{quote_id} reason=#{inspect(reason)} — " <>
            "entry retained for next sweep"
        )
    end
  end

  defp reconcile({quote_id, payload}) do
    Logger.error(
      "Reconciler: orphan deposit with malformed payload, quote_id=#{quote_id} " <>
        "payload=#{inspect(payload)} — deleting without WAL compensation"
    )

    Pending.force_delete(quote_id)
    broadcast_reconciled(quote_id)
  end

  defp broadcast_reconciled(quote_id) do
    Phoenix.PubSub.broadcast(
      Minted.PubSub,
      @pubsub_topic,
      {:quote_reconciled, quote_id}
    )
  rescue
    e ->
      Logger.warning("Reconciler: PubSub broadcast failed: #{inspect(e)}")
  end
end
