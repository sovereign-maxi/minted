defmodule Minted.Lightning.MonitorIntegrationTest do
  @moduledoc "Integration tests for lightning node monitor ETS state tracking."

  use Minted.IntegrationCase

  alias Minted.Lightning.Monitor

  @table FireBird.Monitor

  setup do
    # Ensure the ETS table exists for testing.
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      _ref ->
        :ets.delete_all_objects(@table)
    end

    on_exit(fn ->
      case :ets.whereis(@table) do
        :undefined -> :ok
        _ref -> :ets.delete_all_objects(@table)
      end
    end)

    :ok
  end

  describe "get_status/0" do
    test "returns {0, :unknown} when no balance is set" do
      assert {0, :unknown} = Monitor.get_status()
    end

    test "returns :healthy when balance is above high watermark" do
      Monitor.set_status(500_000, :healthy)

      {balance, status} = Monitor.get_status()
      assert balance == 500_000
      assert status == :healthy
    end

    test "returns :low when balance is between low and high watermarks" do
      # Default thresholds: high=100_000, low=10_000
      Monitor.set_status(50_000, :low)

      {balance, status} = Monitor.get_status()
      assert balance == 50_000
      assert status == :low
    end

    test "returns :critical when balance is below low watermark" do
      Monitor.set_status(5_000, :critical)

      {balance, status} = Monitor.get_status()
      assert balance == 5_000
      assert status == :critical
    end
  end

  describe "balance updates" do
    test "set_status/3 updates balance in ETS" do
      Monitor.set_status(200_000, :healthy)
      {balance_1, _} = Monitor.get_status()
      assert balance_1 == 200_000

      Monitor.set_status(8_000, :critical)
      {balance_2, _} = Monitor.get_status()
      assert balance_2 == 8_000
    end
  end

  describe "sufficient?/1" do
    test "returns true when balance exceeds requested amount" do
      Monitor.set_status(100_000, :healthy)
      assert Monitor.sufficient?(50_000) == true
    end

    test "returns false when balance is below requested amount" do
      Monitor.set_status(100_000, :healthy)
      assert Monitor.sufficient?(200_000) == false
    end

    test "returns false when status is unknown" do
      :ets.delete_all_objects(@table)
      assert Monitor.sufficient?(1) == false
    end
  end

  describe "get_inbound_liquidity/0" do
    test "returns 0 when no inbound liquidity is set" do
      assert Monitor.get_inbound_liquidity() == 0
    end

    test "returns inbound liquidity when set in ETS" do
      :ets.insert(@table, {:inbound_liquidity, 1_000_000})
      assert Monitor.get_inbound_liquidity() == 1_000_000
    end
  end

  describe "clear/0" do
    test "clears all entries from the ETS table" do
      Monitor.set_status(100_000, :healthy)
      :ets.insert(@table, {:inbound_liquidity, 500_000})

      Monitor.clear()

      assert {0, :unknown} = Monitor.get_status()
      assert Monitor.get_inbound_liquidity() == 0
    end
  end
end
