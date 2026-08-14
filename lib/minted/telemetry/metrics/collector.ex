defmodule Minted.Telemetry.Metrics.Collector do
  @moduledoc """
  Accumulates telemetry events into ETS-backed counters and gauges for the
  admin LiveView dashboard and in-process introspection.

  Creates an ETS table `:metric_collector` for fast reads. Attaches to
  telemetry events via `:telemetry.attach_many/4` and subscribes to
  EventBus events not available as telemetry.

  ## Public API

  All reads go directly to ETS — no GenServer call required.

      Collector.counter(:tokens_minted_sats)  #=> 0
      Collector.gauge(:vm_memory_total)        #=> 123456 | nil
  """

  use GenServer

  alias Minted.Events.EventBus
  alias Minted.Events.{Identity, Lightning, Mint}

  @table Minted.Telemetry.Metrics.Collector

  # --- Telemetry event → counter key mapping ---

  @counter_events [
    {[:minted, :tokens, :minted], :tokens_minted_sats, :total},
    {[:minted, :tokens, :burned], :tokens_burned_sats, :total},
    {[:minted, :tokens, :swapped], :tokens_swapped, :_one},
    {[:minted, :mint, :sign], :sign_total, :count},
    {[:minted, :mint, :sign_failed], :sign_failed, :_one},
    {[:minted, :mint, :quote, :created], :quote_created, :_one},
    {[:minted, :mint, :quote, :expired], :quote_expired, :_one},
    {[:minted, :wal, :write_failure], :wal_write_failure, :_one},
    {[:minted, :wal, :writes_halted], :wal_writes_halted, :_one},
    {[:minted, :wal, :rotation_failure], :wal_rotation_failure, :_one},
    {[:minted, :lightning, :payment, :timeout], :payment_timeout, :_one},
    {[:minted, :lightning, :invoice, :underpaid], :invoice_underpaid, :_one},
    {[:minted, :melt, :settlement_timeout], :melt_settlement_timeout, :_one},
    {[:minted, :melt, :commit_failed_after_payment], :melt_commit_failed, :_one},
    {[:minted, :spent_set, :overloaded], :spent_set_overloaded, :_one},
    {[:minted, :spent_set, :commit_failure], :spent_set_commit_failure, :count},
    {[:minted, :liability, :invariant_violation], :liability_invariant_violation, :_one},
    {[:minted, :fees, :collected], :fees_collected_events, :_one},
    {[:minted, :recovery, :incomplete_melts], :recovery_incomplete_melts, :count},
    {[:minted, :recovery, :incomplete_swaps], :recovery_incomplete_swaps, :count}
  ]

  # --- Gauge telemetry events ---

  @gauge_events [
    [:minted, :spent_set, :size],
    [:minted, :vm, :memory],
    [:minted, :tor, :health_check],
    [:minted, :liability, :minted],
    [:minted, :liability, :burned],
    [:minted, :fees, :collected]
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec counter(atom()) :: non_neg_integer()
  def counter(key) do
    case :ets.lookup(@table, {:counter, key}) do
      [{{:counter, ^key}, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @spec gauge(atom()) :: number() | nil
  def gauge(key) do
    case :ets.lookup(@table, {:gauge, key}) do
      [{{:gauge, ^key}, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    attach_counter_events()
    attach_gauge_events()

    EventBus.subscribe(Mint.DoubleSpendDetected)
    EventBus.subscribe(Identity.RateLimitEscalated)
    EventBus.subscribe(Lightning.PaymentExhausted)

    {:ok, %{}}
  end

  @impl true
  def handle_info({:telemetry_counter, key, increment}, state) do
    :ets.update_counter(@table, {:counter, key}, {2, increment}, {{:counter, key}, 0})
    {:noreply, state}
  end

  def handle_info({:telemetry_gauge, updates}, state) when is_list(updates) do
    Enum.each(updates, fn {key, value} ->
      :ets.insert(@table, {{:gauge, key}, value})
    end)

    {:noreply, state}
  end

  def handle_info(%Mint.DoubleSpendDetected{}, state) do
    :ets.update_counter(
      @table,
      {:counter, :double_spend_detected},
      {2, 1},
      {{:counter, :double_spend_detected}, 0}
    )

    {:noreply, state}
  end

  def handle_info(%Identity.RateLimitEscalated{}, state) do
    :ets.update_counter(
      @table,
      {:counter, :rate_limit_escalations},
      {2, 1},
      {{:counter, :rate_limit_escalations}, 0}
    )

    {:noreply, state}
  end

  def handle_info(%Lightning.PaymentExhausted{}, state) do
    :ets.update_counter(
      @table,
      {:counter, :payment_exhausted},
      {2, 1},
      {{:counter, :payment_exhausted}, 0}
    )

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Telemetry handler (runs in caller process, sends to GenServer) ---

  @doc false
  def handle_telemetry_counter(event, measurements, _metadata, _config) do
    Enum.each(@counter_events, fn {ev, key, field} ->
      if ev == event do
        increment =
          case field do
            :_one -> 1
            f -> Map.get(measurements, f, 1)
          end

        safe_send({:telemetry_counter, key, increment})
      end
    end)
  end

  @doc false
  def handle_telemetry_gauge(event, measurements, _metadata, _config) do
    updates = gauge_updates(event, measurements)

    if updates != [] do
      safe_send({:telemetry_gauge, updates})
    end
  end

  # The handler runs in the CALLER's process; a send to the registered
  # name raises ArgumentError while the Collector is mid-restart, and
  # telemetry auto-detaches a raising handler — freezing every counter
  # until the next app restart. Drop the update instead.
  defp safe_send(msg) do
    send(__MODULE__, msg)
  rescue
    ArgumentError -> :ok
  end

  # --- Private ---

  defp attach_counter_events do
    events = Enum.map(@counter_events, fn {ev, _key, _field} -> ev end) |> Enum.uniq()

    :telemetry.attach_many(
      "metric-collector-counters",
      events,
      &__MODULE__.handle_telemetry_counter/4,
      nil
    )
  end

  defp attach_gauge_events do
    :telemetry.attach_many(
      "metric-collector-gauges",
      @gauge_events,
      &__MODULE__.handle_telemetry_gauge/4,
      nil
    )
  end

  defp gauge_updates([:minted, :spent_set, :size], m) do
    [
      {:spent_set_queue_depth, Map.get(m, :queue_depth, 0)},
      {:spent_set_memory_bytes, Map.get(m, :memory_bytes, 0)},
      {:spent_set_pending_count, Map.get(m, :pending_count, 0)}
    ]
  end

  defp gauge_updates([:minted, :vm, :memory], m) do
    [
      {:vm_memory_total, Map.get(m, :total, 0)},
      {:vm_memory_processes, Map.get(m, :processes, 0)},
      {:vm_memory_ets, Map.get(m, :ets, 0)}
    ]
  end

  defp gauge_updates([:minted, :tor, :health_check], m) do
    [{:tor_health_status, Map.get(m, :status, 0)}]
  end

  defp gauge_updates([:minted, :liability, :minted], m) do
    [{:liability_minted_sats, Map.get(m, :total, 0)}]
  end

  defp gauge_updates([:minted, :liability, :burned], m) do
    [{:liability_burned_sats, Map.get(m, :total, 0)}]
  end

  defp gauge_updates([:minted, :fees, :collected], m) do
    [{:fees_collected_sats, Map.get(m, :total, 0)}]
  end

  defp gauge_updates(_event, _measurements), do: []
end
