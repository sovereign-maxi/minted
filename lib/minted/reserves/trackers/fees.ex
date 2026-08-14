defmodule Minted.Reserves.Trackers.Fees do
  @moduledoc """
  Tracks fees collected via EventBus subscriptions.

  Lifetime totals are stored in `Locker.Counter` (named
  `Minted.Reserves.FeeCounter`). A rolling 24-hour window is maintained in
  an ETS ordered set keyed by monotonic insertion sequence so the dashboard
  can show recent house income without scanning the WAL.
  """

  use GenServer

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents

  require Logger

  @counter Minted.Reserves.FeeCounter
  @window_table __MODULE__.Window
  @window_seconds 86_400

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec current() :: %{total_collected: non_neg_integer(), event_count: non_neg_integer()}
  def current do
    counters = Locker.Counter.read_all(@counter)

    %{
      total_collected: Map.get(counters, :total_fees_collected, 0),
      event_count: Map.get(counters, :total_fee_events, 0)
    }
  end

  @doc """
  Returns rolling 24-hour totals derived from the in-memory window.

  Keys: `:total` (sats), `:count` (events), `:avg` (integer sats, 0 when count is 0).
  """
  @spec last_24h() :: %{total: non_neg_integer(), count: non_neg_integer(), avg: non_neg_integer()}
  def last_24h do
    cutoff = System.system_time(:second) - @window_seconds

    entries =
      :ets.select(@window_table, [
        {{:"$1", :"$2", :"$3"}, [{:>=, :"$2", cutoff}], [:"$3"]}
      ])

    total = Enum.sum(entries)
    count = length(entries)
    avg = if count > 0, do: div(total, count), else: 0

    %{total: total, count: count, avg: avg}
  rescue
    ArgumentError -> %{total: 0, count: 0, avg: 0}
  end

  @spec reset_counters() :: :ok
  def reset_counters do
    Locker.Counter.reset(@counter)

    try do
      :ets.delete_all_objects(@window_table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @spec restore_counters(non_neg_integer()) :: :ok
  def restore_counters(amount) when is_integer(amount) and amount > 0 do
    Locker.Counter.increment(@counter, :total_fees_collected, amount)
    :ok
  end

  def restore_counters(_amount), do: :ok

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@window_table, [:named_table, :public, :ordered_set, read_concurrency: true])
    EventBus.subscribe(MintEvents.FeesCollected)

    # A crash between the WAL write and the EventBus dispatch could
    # leave the counter behind — the WAL entry is durable but the
    # counter increment is not. Reconcile once on boot: sum every
    # :fees_collected WAL entry and adjust upward if the counter is
    # low. Same pattern as Minted.Mint.House.Store; idempotent.
    reconcile_counter_from_wal()

    {:ok, %{seq: 0}}
  end

  @impl true
  def handle_info(%MintEvents.FeesCollected{amount: amount}, state)
      when is_integer(amount) and amount > 0 do
    new_total = Locker.Counter.increment(@counter, :total_fees_collected, amount)
    Locker.Counter.increment(@counter, :total_fee_events, 1)

    now = System.system_time(:second)
    seq = state.seq + 1
    :ets.insert(@window_table, {seq, now, amount})
    prune_window(now - @window_seconds)

    :telemetry.execute(
      [:minted, :fees, :collected],
      %{amount: amount, total: new_total},
      %{}
    )

    {:noreply, %{state | seq: seq}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Remove entries older than the cutoff. Bounded scan from the head of the
  # ordered set — cheap because inserts are strictly monotonic.
  defp prune_window(cutoff) do
    stale =
      :ets.select(@window_table, [
        {{:"$1", :"$2", :_}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(stale, &:ets.delete(@window_table, &1))
  end

  # Sum every :fees_collected WAL entry and bump the counter if it
  # is behind. Idempotent. Note the WAL provides CRC32 integrity
  # (bitrot/torn writes), not authenticity — a hand-forged entry with
  # a valid CRC would pass, so the data dir and backups must stay
  # access-controlled. If the counter is AHEAD of the WAL sum,
  # leave it alone (the counter's DETS is authoritative; WAL may be
  # pruned but counters persist across prunes).
  defp reconcile_counter_from_wal do
    case Minted.Storage.Facade.read_all_wal() do
      {:ok, entries} ->
        wal_sum =
          Enum.reduce(entries, 0, fn
            %Locker.WAL.Entry{type: :fees_collected, payload: %{amount: n}}, acc
            when is_integer(n) ->
              acc + n

            _, acc ->
              acc
          end)

        current = Locker.Counter.read(@counter, :total_fees_collected)

        cond do
          wal_sum == current ->
            :ok

          wal_sum > current ->
            Locker.Counter.increment(@counter, :total_fees_collected, wal_sum - current)

            Logger.info(
              "Fees: reconciled :total_fees_collected from WAL, " <>
                "delta=+#{wal_sum - current} sats"
            )

          wal_sum < current ->
            Logger.debug(
              "Fees: counter :total_fees_collected (#{current}) exceeds " <>
                "WAL-derived sum (#{wal_sum}); leaving counter untouched."
            )
        end

      {:error, reason} ->
        Logger.warning("Fees: WAL reconcile skipped: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Fees: WAL reconcile crashed: #{inspect(e)}")
  end
end
