defmodule Minted.Lightning.FeesTest do
  @moduledoc "Unit tests for Minted.Lightning.Fees."

  use ExUnit.Case, async: true

  alias Minted.Lightning.Fees

  describe "calculate/2" do
    test "calculates fee for standard amount" do
      # 10,000 sats at 1000 ppm = 10 sats
      assert Fees.calculate(10_000, 1_000) == 10
    end

    test "rounds up to nearest satoshi" do
      # 100 sats at 1000 ppm = 0.1 -> rounds up to 1
      assert Fees.calculate(100, 1_000) == 1
    end

    test "rounds up for smallest amount" do
      # 1 sat at 1000 ppm = 0.001 -> rounds up to 1
      assert Fees.calculate(1, 1_000) == 1
    end

    test "returns 0 for zero amount" do
      assert Fees.calculate(0, 1_000) == 0
    end

    test "returns 0 for zero ppm" do
      assert Fees.calculate(10_000, 0) == 0
    end

    test "handles very large amounts without overflow" do
      # 21 million BTC in sats = 2_100_000_000_000_000
      result = Fees.calculate(2_100_000_000_000_000, 1_000)
      assert result == 2_100_000_000_000
    end

    test "calculates correctly for 100% fee rate" do
      # 1_000_000 ppm = 100%
      assert Fees.calculate(1000, 1_000_000) == 1000
    end

    test "ceiling division is correct for exact divisions" do
      # 1_000_000 sats at 1000 ppm = exactly 1000
      assert Fees.calculate(1_000_000, 1_000) == 1000
    end

    test "ceiling division rounds up for non-exact divisions" do
      # 999_999 sats at 1000 ppm = 999.999 -> 1000
      assert Fees.calculate(999_999, 1_000) == 1000
    end

    test "raises on amount exceeding max sats" do
      assert_raise ArgumentError, ~r/amount exceeds maximum/, fn ->
        Fees.calculate(2_100_000_000_000_001, 1_000)
      end
    end

    test "accepts exactly max amount sats" do
      result = Fees.calculate(2_100_000_000_000_000, 1_000)
      assert result == 2_100_000_000_000
    end
  end

  describe "deposit_fee/1" do
    test "uses configured ppm rate" do
      # Configured at 7500 ppm (0.75%): 10_000 sats -> 75 sats fee
      assert Fees.deposit_fee(10_000) == 75
    end

    test "returns 0 for zero amount" do
      assert Fees.deposit_fee(0) == 0
    end

    test "respects minimum fee" do
      # 1 sat at 2000 ppm = ceiling(0.002) = 1 sat, min is 1
      assert Fees.deposit_fee(1) >= 1
    end
  end

  describe "withdrawal_fee/1" do
    test "returns routing fee estimate" do
      # Configured at 5000 ppm routing estimate: 10_000 sats -> 50 sats
      assert Fees.withdrawal_fee(10_000) == 50
    end

    test "returns 0 for zero amount" do
      assert Fees.withdrawal_fee(0) == 0
    end
  end
end
