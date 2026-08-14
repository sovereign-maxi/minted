defmodule Minted.Mint.House.Store do
  @moduledoc """
  Persistent counters + WAL-backed event log for house-income
  accounting.

  Two independent counters, both survive process restart via
  `Locker.Counter`:

    * `:total_fees_collected` — cumulative fees ever earned by the
      house. Managed by `Minted.Reserves.Trackers.Fees` on incoming
      `FeesCollected` events. This module READS from it but never
      writes.

    * `:total_house_withdrawn` — cumulative sats the operator has
      drawn out as house income. Managed here; incremented on
      successful withdrawal completion.

  Withdrawable = collected - withdrawn - in_flight.

  The `:in_flight` register tracks amounts that have been REQUESTED
  but not yet completed/rejected. That prevents a race where two
  concurrent withdrawal requests each pass the half-cap check
  because neither knows about the other's amount.

  WAL entries for the withdrawal lifecycle land under type bytes
  0x17, 0x18, 0x19 (see `Minted.Storage.WAL`). On boot the store
  replays the WAL to rebuild the `:in_flight` register — completed
  and rejected requests drop out, requested-only stays.
  """

  use GenServer

  alias Locker.WAL.Entry
  alias Minted.Events.EventBus
  alias Minted.Events.House, as: HouseEvents
  alias Minted.Storage.Facade, as: StorageFacade

  require Logger

  @counter Minted.Reserves.FeeCounter
  @in_flight_table __MODULE__.InFlight

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Total fees ever collected by the mint. Read-only from this module's POV."
  @spec total_earned() :: non_neg_integer()
  def total_earned do
    Locker.Counter.read(@counter, :total_fees_collected)
  end

  @doc "Total sats drawn out as house income. Cumulative, never resets."
  @spec total_drawn() :: non_neg_integer()
  def total_drawn do
    Locker.Counter.read(@counter, :total_house_withdrawn)
  end

  @doc "Sats currently held as house income that hasn't been requested for withdrawal."
  @spec in_flight() :: non_neg_integer()
  def in_flight do
    :ets.foldl(fn {_id, amount}, acc -> acc + amount end, 0, @in_flight_table)
  rescue
    ArgumentError -> 0
  end

  @doc """
  Currently withdrawable = earned - drawn - in_flight.

  Accepts pending (requested-but-not-completed) withdrawals as
  claims against the pool. That prevents a race where two
  simultaneous withdrawal requests each independently see the full
  balance and both pass the half-cap check.
  """
  @spec withdrawable() :: non_neg_integer()
  def withdrawable do
    max(0, total_earned() - total_drawn() - in_flight())
  end

  @doc """
  Half-cap ceiling for a single withdrawal request.

  Security control (mirrors PERP WALK's federation-income rule):
  a single request cannot exceed half of the current withdrawable
  balance. Bounds the blast radius of a compromised admin session.
  DO NOT "fix" — the rule is deliberate.
  """
  @spec max_single_request() :: non_neg_integer()
  def max_single_request do
    div(withdrawable(), 2)
  end

  @doc """
  Registers a withdrawal request. Guards check withdrawable balance
  + half-cap + minimum. On success, records the amount in the
  in-flight register (subtracted from withdrawable), writes a
  WAL entry, and publishes `WithdrawalRequested` on the EventBus.
  """
  @spec register_request(String.t(), pos_integer(), String.t()) ::
          {:ok, HouseEvents.WithdrawalRequested.t()}
          | {:error, :insufficient_withdrawable | :half_cap_exceeded | :below_minimum}
  def register_request(request_id, amount_sats, invoice)
      when is_binary(request_id) and is_integer(amount_sats) and amount_sats > 0 and
             is_binary(invoice) do
    GenServer.call(__MODULE__, {:register_request, request_id, amount_sats, invoice})
  end

  @doc """
  Marks a request as completed. Increments the `:total_house_withdrawn`
  counter, drops the amount from the in-flight register, writes
  the WAL entry, and publishes `WithdrawalCompleted`.
  """
  @spec complete_request(String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def complete_request(request_id, fee_sats)
      when is_binary(request_id) and is_integer(fee_sats) and fee_sats >= 0 do
    GenServer.call(__MODULE__, {:complete_request, request_id, fee_sats})
  end

  @doc """
  Marks a request as rejected. Drops the amount from the in-flight
  register (restoring withdrawable), writes the WAL entry, and
  publishes `WithdrawalRejected`.
  """
  @spec reject_request(String.t(), HouseEvents.WithdrawalRejected.reason()) ::
          :ok | {:error, :not_found}
  def reject_request(request_id, reason)
      when is_binary(request_id) and is_atom(reason) do
    GenServer.call(__MODULE__, {:reject_request, request_id, reason})
  end

  @doc "Clears all state — for tests and disaster recovery."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    :ets.new(@in_flight_table, [:named_table, :public, :set, read_concurrency: true])

    wal_server = Keyword.get(opts, :wal_server, Minted.Storage.WAL)
    replay_wal(wal_server)

    {:ok, %{wal_server: wal_server}}
  end

  @impl true
  def handle_call({:register_request, request_id, amount_sats, invoice}, _from, state) do
    cond do
      amount_sats < minimum_withdrawal() ->
        {:reply, {:error, :below_minimum}, state}

      amount_sats > withdrawable() ->
        {:reply, {:error, :insufficient_withdrawable}, state}

      amount_sats > max_single_request() ->
        {:reply, {:error, :half_cap_exceeded}, state}

      true ->
        event = %HouseEvents.WithdrawalRequested{
          request_id: request_id,
          amount_sats: amount_sats,
          invoice: invoice,
          timestamp: DateTime.utc_now()
        }

        # WAL BEFORE mutating in-flight state — durable record precedes
        # the ETS write. If the WAL append fails, halt: no ETS mutation,
        # no event publish, caller sees the error and can decide whether
        # to retry.
        case write_wal(:house_withdrawal_requested, Map.from_struct(event)) do
          :ok ->
            :ets.insert(@in_flight_table, {request_id, amount_sats})
            EventBus.publish(event)
            {:reply, {:ok, event}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:complete_request, request_id, fee_sats}, _from, state) do
    case :ets.lookup(@in_flight_table, request_id) do
      [{^request_id, amount_sats}] ->
        event = %HouseEvents.WithdrawalCompleted{
          request_id: request_id,
          amount_sats: amount_sats,
          fee_sats: fee_sats,
          timestamp: DateTime.utc_now()
        }

        # WAL BEFORE counter + ETS mutation. Order matters: if WAL succeeds
        # but the process crashes before the counter increment lands, the
        # replay path at apply_replay/1 (:house_withdrawal_completed) rebuilds
        # the counter idempotently on next boot.
        # The routing fee comes out of the SAME channel balance
        # that backs user ecash — every sat phoenixd paid to route
        # this withdrawal reduces reserve capacity too. Prior impl
        # incremented by amount_sats only, so withdrawable() drifted
        # positive by the accumulated fees; over time the operator
        # could withdraw more than the channel actually holds
        # (against user-backed reserves).
        drawn = amount_sats + fee_sats

        case write_wal(:house_withdrawal_completed, Map.from_struct(event)) do
          :ok ->
            Locker.Counter.increment(@counter, :total_house_withdrawn, drawn)
            :ets.delete(@in_flight_table, request_id)
            EventBus.publish(event)
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:reject_request, request_id, reason}, _from, state) do
    case :ets.lookup(@in_flight_table, request_id) do
      [{^request_id, amount_sats}] ->
        event = %HouseEvents.WithdrawalRejected{
          request_id: request_id,
          amount_sats: amount_sats,
          reason: reason,
          timestamp: DateTime.utc_now()
        }

        case write_wal(:house_withdrawal_rejected, Map.from_struct(event)) do
          :ok ->
            :ets.delete(@in_flight_table, request_id)
            EventBus.publish(event)
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@in_flight_table)
    {:reply, :ok, state}
  end

  # --- Internals ---

  # Minimum single withdrawal — filters accidental 1-sat requests.
  # Configurable but rarely overridden.
  defp minimum_withdrawal do
    Application.get_env(:minted, :house_income_min_withdrawal_sats, 1_000)
  end

  defp write_wal(type, payload) do
    case StorageFacade.write_wal(type, payload) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error("House.Store: WAL append failed type=#{type} reason=#{inspect(reason)}")
        err
    end
  end

  defp replay_wal(wal_server) do
    case Locker.WAL.read_all(wal_server) do
      {:ok, entries} ->
        verified = Enum.filter(entries, &owned?/1)

        # First pass: rebuild the in-flight ETS register. WAL is
        # already crash-safe; ETS is a fresh table on every boot.
        Enum.each(verified, &apply_replay/1)

        # Second pass: rebuild the :total_house_withdrawn counter from
        # scratch by summing every verified :house_withdrawal_completed
        # entry. Necessary because:
        #   (a) Recovery.reset_fee_counters/0 zeros this key alongside
        #       fee counters (they share the same Locker.Counter).
        #   (b) A crash between the WAL write and the Locker.Counter
        #       increment in :complete_request would lose the increment
        #       without this rebuild.
        # Idempotent by construction — we set the counter to the exact
        # sum, so replaying the same WAL always yields the same value.
        # Note: `verified` is only type-filtered — the WAL carries
        # CRC32 integrity (bitrot), not authenticity, so the data dir
        # and backups must stay access-controlled.
        rebuild_house_withdrawn_counter(verified)

        pending = :ets.info(@in_flight_table, :size)
        Logger.debug("House.Store: WAL replay complete, in_flight=#{pending}")

      {:error, reason} ->
        Logger.warning("House.Store: WAL replay failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("House.Store: WAL replay skipped: #{inspect(e)}")
  end

  defp owned?(%Entry{type: type})
       when type in [
              :house_withdrawal_requested,
              :house_withdrawal_completed,
              :house_withdrawal_rejected
            ],
       do: true

  defp owned?(_), do: false

  defp apply_replay(%Entry{type: :house_withdrawal_requested, payload: event}) do
    :ets.insert(@in_flight_table, {event.request_id, event.amount_sats})
  end

  defp apply_replay(%Entry{type: type, payload: event})
       when type in [:house_withdrawal_completed, :house_withdrawal_rejected] do
    :ets.delete(@in_flight_table, event.request_id)
  end

  defp rebuild_house_withdrawn_counter(entries) do
    sum =
      Enum.reduce(entries, 0, fn
        # Match the on-line increment: routing fee counts against
        # withdrawable capacity because it drains the same channel
        # balance user ecash is backed by.
        %Entry{type: :house_withdrawal_completed, payload: %{amount_sats: n, fee_sats: f}}, acc
        when is_integer(n) and is_integer(f) ->
          acc + n + f

        %Entry{type: :house_withdrawal_completed, payload: %{amount_sats: n}}, acc
        when is_integer(n) ->
          acc + n

        _, acc ->
          acc
      end)

    current = Locker.Counter.read(@counter, :total_house_withdrawn)

    cond do
      sum == current ->
        :ok

      sum > current ->
        Locker.Counter.increment(@counter, :total_house_withdrawn, sum - current)

        Logger.info(
          "House.Store: rebuilt :total_house_withdrawn from WAL, " <>
            "delta=+#{sum - current} sats"
        )

      sum < current ->
        # WAL says less than the counter — either the WAL was truncated
        # or a legacy state predates the rebuild. Log loudly; do NOT
        # decrement the counter (would risk double-withdrawal).
        Logger.warning(
          "House.Store: counter :total_house_withdrawn (#{current}) exceeds " <>
            "WAL-derived total (#{sum}); leaving counter untouched."
        )
    end
  end
end
