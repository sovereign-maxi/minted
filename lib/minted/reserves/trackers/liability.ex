defmodule Minted.Reserves.Trackers.Liability do
  @moduledoc """
  Tracks total minted and burned sats via EventBus subscriptions.

  Delegates counter storage to `Locker.Counter` (named `Minted.Reserves.LiabilityCounter`).
  This module is a thin event subscriber — all persistence is handled by Locker.
  """

  use GenServer

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents

  require Logger

  @counter Minted.Reserves.LiabilityCounter

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec current() :: %{
          minted: non_neg_integer(),
          burned: non_neg_integer(),
          outstanding: integer()
        }
  def current do
    counters = Locker.Counter.read_all(@counter)
    minted = Map.get(counters, :total_minted, 0)
    burned = Map.get(counters, :total_burned, 0)
    %{minted: minted, burned: burned, outstanding: minted - burned}
  end

  @spec minted_total() :: non_neg_integer()
  def minted_total, do: Locker.Counter.read(@counter, :total_minted)

  @spec burned_total() :: non_neg_integer()
  def burned_total, do: Locker.Counter.read(@counter, :total_burned)

  @doc "Resets both counters to zero. Used during crash recovery."
  @spec reset_counters() :: :ok
  def reset_counters, do: Locker.Counter.reset(@counter)

  @doc "Restores a counter from WAL replay."
  @spec restore_counters(:minted | :burned, non_neg_integer()) :: :ok
  def restore_counters(:minted, amount) when is_integer(amount) and amount > 0 do
    Locker.Counter.increment(@counter, :total_minted, amount)
    :ok
  end

  def restore_counters(:burned, amount) when is_integer(amount) and amount > 0 do
    Locker.Counter.increment(@counter, :total_burned, amount)
    :ok
  end

  def restore_counters(_type, _amount), do: :ok

  @doc "Verifies counter consistency."
  @spec verify_counters() :: :ok | {:drift, map()}
  def verify_counters, do: Locker.Counter.verify(@counter)

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    EventBus.subscribe(MintEvents.TokensMinted)
    EventBus.subscribe(MintEvents.TokensBurned)
    EventBus.subscribe(MintEvents.TokensSwapped)

    {:ok, %{}}
  end

  @impl true
  def handle_info(%MintEvents.TokensMinted{amount: amount}, state)
      when is_integer(amount) and amount > 0 do
    new_val = Locker.Counter.increment(@counter, :total_minted, amount)

    :telemetry.execute(
      [:minted, :liability, :minted],
      %{amount: amount, total: new_val},
      %{}
    )

    {:noreply, state}
  end

  def handle_info(%MintEvents.TokensBurned{amount: amount}, state)
      when is_integer(amount) and amount > 0 do
    new_val = Locker.Counter.increment(@counter, :total_burned, amount)

    minted = Locker.Counter.read(@counter, :total_minted)

    :telemetry.execute(
      [:minted, :liability, :burned],
      %{amount: amount, total: new_val},
      %{}
    )

    if new_val > minted do
      Logger.error("Liability: INVARIANT VIOLATION — burned=#{new_val}, minted=#{minted}")
    end

    {:noreply, state}
  end

  def handle_info(%MintEvents.TokensSwapped{amount: amount}, state)
      when is_integer(amount) and amount > 0 do
    new_val = Locker.Counter.increment(@counter, :total_minted, amount)

    :telemetry.execute(
      [:minted, :liability, :swap_compensated],
      %{amount: amount, total_minted: new_val},
      %{}
    )

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
