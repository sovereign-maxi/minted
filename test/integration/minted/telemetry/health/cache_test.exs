defmodule Minted.Telemetry.Health.CacheIntegrationTest do
  @moduledoc "Integration tests for health cache event-driven counter updates."

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Telemetry.Health.Cache

  describe "initial state" do
    test "double_spend_count starts at 0 or existing value" do
      result = Cache.get(:double_spend_count)
      assert is_integer(result) or result == :unknown
    end
  end

  describe "get/1 for unknown keys" do
    test "returns :unknown for unset keys" do
      assert Cache.get(:nonexistent_key) == :unknown
    end
  end

  describe "health updates from events" do
    test "LiquidityLow updates liquidity_status" do
      EventBus.publish(%LightningEvents.LiquidityLow{
        balance_sats: 50_000,
        previous_status: :healthy,
        current_status: :low,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        case Cache.get(:liquidity_status) do
          %{status: :low} -> true
          _ -> false
        end
      end)

      assert Cache.get(:liquidity_status).status == :low
    end

    test "LiquidityCritical updates liquidity_status" do
      EventBus.publish(%LightningEvents.LiquidityCritical{
        balance_sats: 7_777,
        previous_status: :low,
        current_status: :critical,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        case Cache.get(:liquidity_status) do
          %{status: :critical} -> true
          _ -> false
        end
      end)

      assert Cache.get(:liquidity_status).status == :critical
    end

    test "LiquidityRecovered updates liquidity_status" do
      EventBus.publish(%LightningEvents.LiquidityRecovered{
        balance_sats: 200_000,
        previous_status: :critical,
        current_status: :healthy,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        case Cache.get(:liquidity_status) do
          %{status: :healthy} -> true
          _ -> false
        end
      end)

      assert Cache.get(:liquidity_status).status == :healthy
    end

    test "DoubleSpendDetected increments counter" do
      initial = Cache.get(:double_spend_count)
      initial = if initial == :unknown, do: 0, else: initial

      EventBus.publish(%MintEvents.DoubleSpendDetected{
        secret_hash: :crypto.strong_rand_bytes(32),
        keyset_id: "test-keyset",
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        current = Cache.get(:double_spend_count)
        is_integer(current) and current > initial
      end)

      assert Cache.get(:double_spend_count) > initial
    end

    test "KeysetRotated updates active_keyset_id" do
      EventBus.publish(%Minted.Events.Telemetry.KeysetRotated{
        old_keyset_id: "old-abc",
        new_keyset_id: "new-def",
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        case Cache.get(:active_keyset) do
          %{new_keyset_id: "new-def"} -> true
          _ -> false
        end
      end)

      assert Cache.get(:active_keyset).new_keyset_id == "new-def"
    end
  end
end
