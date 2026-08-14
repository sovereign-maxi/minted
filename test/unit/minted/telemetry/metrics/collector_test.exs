defmodule Minted.Telemetry.Metrics.CollectorTest do
  @moduledoc "Unit tests for Minted.Telemetry.Metrics.Collector."

  use ExUnit.Case, async: false

  alias Minted.Events.EventBus
  alias Minted.Events.{Identity, Lightning, Mint}
  alias Minted.Telemetry.Metrics.Collector

  # Collector is started by the application supervisor.
  # Drain pending messages before reading snapshots.

  setup do
    :sys.get_state(Collector)
    :ok
  end

  describe "counter/1" do
    test "returns 0 for unknown keys" do
      assert Collector.counter(:nonexistent) == 0
    end

    test "increments on telemetry counter events" do
      before = Collector.counter(:tokens_minted_sats)

      :telemetry.execute([:minted, :tokens, :minted], %{total: 5_000}, %{})
      :sys.get_state(Collector)

      assert Collector.counter(:tokens_minted_sats) >= before + 5_000
    end

    test "increments by 1 for events with no measurement field" do
      before = Collector.counter(:quote_expired)

      :telemetry.execute([:minted, :mint, :quote, :expired], %{}, %{quote_id: "q1"})
      :sys.get_state(Collector)

      assert Collector.counter(:quote_expired) >= before + 1
    end

    test "increments by measurement count for sign events" do
      before = Collector.counter(:sign_total)

      :telemetry.execute([:minted, :mint, :sign], %{count: 10}, %{keyset_id: "ks1"})
      :sys.get_state(Collector)

      assert Collector.counter(:sign_total) >= before + 10
    end

    test "increments on spent_set commit_failure by count" do
      before = Collector.counter(:spent_set_commit_failure)

      :telemetry.execute([:minted, :spent_set, :commit_failure], %{count: 3}, %{})
      :sys.get_state(Collector)

      assert Collector.counter(:spent_set_commit_failure) >= before + 3
    end
  end

  describe "gauge/1" do
    test "returns nil for unknown keys" do
      assert Collector.gauge(:nonexistent) == nil
    end

    test "updates on vm memory telemetry" do
      :telemetry.execute(
        [:minted, :vm, :memory],
        %{total: 100_000, processes: 50_000, ets: 20_000},
        %{}
      )

      :sys.get_state(Collector)

      assert Collector.gauge(:vm_memory_total) == 100_000
      assert Collector.gauge(:vm_memory_processes) == 50_000
      assert Collector.gauge(:vm_memory_ets) == 20_000
    end

    test "updates spent set gauges" do
      :telemetry.execute(
        [:minted, :spent_set, :size],
        %{spent: 100, y_index: 50, queue_depth: 5, memory_bytes: 4096, pending_count: 2},
        %{}
      )

      :sys.get_state(Collector)

      assert Collector.gauge(:spent_set_queue_depth) == 5
      assert Collector.gauge(:spent_set_memory_bytes) == 4096
      assert Collector.gauge(:spent_set_pending_count) == 2
    end

    test "updates tor health status" do
      :telemetry.execute([:minted, :tor, :health_check], %{status: 1}, %{})
      :sys.get_state(Collector)

      assert Collector.gauge(:tor_health_status) == 1
    end

    test "updates liability gauges" do
      :telemetry.execute([:minted, :liability, :minted], %{amount: 1000, total: 5000}, %{})
      :telemetry.execute([:minted, :liability, :burned], %{amount: 200, total: 3000}, %{})
      :sys.get_state(Collector)

      assert Collector.gauge(:liability_minted_sats) == 5000
      assert Collector.gauge(:liability_burned_sats) == 3000
    end

    test "updates fees collected gauge" do
      :telemetry.execute([:minted, :fees, :collected], %{amount: 50, total: 1500}, %{})
      :sys.get_state(Collector)

      assert Collector.gauge(:fees_collected_sats) == 1500
    end
  end

  describe "EventBus subscriptions" do
    test "increments double_spend_detected on DoubleSpendDetected event" do
      before = Collector.counter(:double_spend_detected)

      EventBus.publish(%Mint.DoubleSpendDetected{
        secret_hash: <<1, 2, 3>>,
        keyset_id: "ks1",
        timestamp: DateTime.utc_now()
      })

      :sys.get_state(Collector)

      assert Collector.counter(:double_spend_detected) >= before + 1
    end

    test "increments rate_limit_escalations on RateLimitEscalated event" do
      before = Collector.counter(:rate_limit_escalations)

      EventBus.publish(%Identity.RateLimitEscalated{
        circuit_id_hash: <<4, 5, 6>>,
        multiplier: 2.0,
        cooldown_seconds: 60,
        timestamp: DateTime.utc_now()
      })

      :sys.get_state(Collector)

      assert Collector.counter(:rate_limit_escalations) >= before + 1
    end

    test "increments payment_exhausted on PaymentExhausted event" do
      before = Collector.counter(:payment_exhausted)

      EventBus.publish(%Lightning.PaymentExhausted{
        payment_id: "pay1",
        error: :route_not_found,
        attempts: 3,
        timestamp: DateTime.utc_now()
      })

      :sys.get_state(Collector)

      assert Collector.counter(:payment_exhausted) >= before + 1
    end
  end
end
