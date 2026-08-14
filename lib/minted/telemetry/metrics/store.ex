defmodule Minted.Telemetry.Metrics.Store do
  @moduledoc """
  Persistent counter store for platform-wide metrics.

  Subscribes to mint events via EventBus and maintains running
  counters in ETS (fast reads) backed by DETS (crash recovery).

  ## Stored keys

    * `:deposit_count` — incremented by proof count on each `TokensMinted` event
    * `:deposit_history` — `[%{at: DateTime.t(), count: integer}]`, capped at 144 entries
    * `:burn_count` — incremented by `count` on each `TokensBurned` event

  ## Public API

  All reads go directly to ETS — no GenServer call required.

      Store.get(:deposit_count)   #=> integer | nil
      Store.get(:deposit_history)  #=> [%{at: DateTime.t(), count: integer}] | nil
      Store.get(:burn_count)       #=> integer | nil
  """

  use GenServer

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Storage.Facade, as: StorageFacade

  require Logger

  @table Minted.Telemetry.Metrics.Store
  @dets_table Minted.Telemetry.Metrics.Store.Durable
  @history_cap 144

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(atom()) :: term() | nil
  def get(:deposit_count), do: read_counter(:deposit_count)
  def get(:deposit_history), do: read_value(:deposit_history)
  def get(:burn_count), do: read_counter(:burn_count)
  def get(_), do: nil

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(@table, [:named_table, :protected, :set])

    dets_path =
      StorageFacade.telemetry_metrics_path()

    File.mkdir_p!(Path.dirname(dets_path))

    {:ok, _} = :dets.open_file(@dets_table, file: String.to_charlist(dets_path), type: :set)

    restore_from_dets(table)

    EventBus.subscribe(MintEvents.TokensMinted)
    EventBus.subscribe(MintEvents.TokensBurned)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(%MintEvents.TokensMinted{count: count, timestamp: timestamp}, state)
      when is_integer(count) and count > 0 do
    new_count =
      :ets.update_counter(state.table, :deposit_count, {2, count}, {:deposit_count, 0})

    append_history(timestamp, new_count)

    sync_to_dets(:deposit_count)
    sync_to_dets(:deposit_history)

    {:noreply, state}
  end

  def handle_info(%MintEvents.TokensBurned{count: count}, state)
      when is_integer(count) and count > 0 do
    :ets.update_counter(state.table, :burn_count, {2, count}, {:burn_count, 0})

    sync_to_dets(:burn_count)

    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@dets_table)
    :dets.close(@dets_table)
    :ok
  end

  # --- Recovery ---

  @doc """
  Restores a counter from WAL replay. Called during crash recovery.
  """
  @spec restore_counter(atom(), non_neg_integer()) :: :ok
  def restore_counter(key, value) when key in [:deposit_count, :burn_count] do
    new_val = :ets.update_counter(@table, key, value, {key, 0})
    :dets.insert(@dets_table, {key, new_val})
    :dets.sync(@dets_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def restore_counter(_, _), do: :ok

  # --- Private ---

  defp restore_from_dets(table) do
    Enum.each([:deposit_count, :burn_count], fn key ->
      case :dets.lookup(@dets_table, key) do
        [{^key, value}] -> :ets.insert(table, {key, value})
        [] -> :ok
      end
    end)

    case :dets.lookup(@dets_table, :deposit_history) do
      [{:deposit_history, history}] -> :ets.insert(table, {:deposit_history, history})
      [] -> :ok
    end
  end

  defp read_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp read_value(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp append_history(timestamp, new_count) do
    current =
      case :ets.lookup(@table, :deposit_history) do
        [{:deposit_history, history}] -> history
        [] -> []
      end

    updated =
      [%{at: timestamp, count: new_count} | current]
      |> Enum.take(@history_cap)

    :ets.insert(@table, {:deposit_history, updated})
  end

  defp sync_to_dets(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        :dets.insert(@dets_table, {key, value})
        :dets.sync(@dets_table)

      [] ->
        :ok
    end
  end
end
