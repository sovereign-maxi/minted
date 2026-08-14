defmodule Minted.Mint.FeesTest do
  @moduledoc "Unit tests for Minted.Mint.Fees."

  use ExUnit.Case, async: true

  alias Minted.Mint.Fees

  defp schedule(overrides \\ []) do
    defaults = %Fees{
      deposit_ppm: 3_500,
      withdrawal_ppm: 3_500,
      min_fee: 1,
      max_fee: 2_100_000_000_000_000
    }

    struct!(defaults, overrides)
  end

  describe "calculate/3 - Lightning fees" do
    test "calculates deposit fee at 0.35%" do
      # 100,000 sats at 3500 ppm = 350 sats
      assert {:ok, 350} = Fees.calculate(schedule(), 100_000, :deposit)
    end

    test "calculates withdrawal fee at 0.35%" do
      assert {:ok, 350} = Fees.calculate(schedule(), 100_000, :withdrawal)
    end

    test "returns 0 for zero amount" do
      assert {:ok, 0} = Fees.calculate(schedule(), 0, :deposit)
      assert {:ok, 0} = Fees.calculate(schedule(), 0, :withdrawal)
    end

    test "respects min_fee" do
      # 100 sats at 3500 ppm = 0.35 → rounds up to 1 (min_fee = 1)
      assert {:ok, 1} = Fees.calculate(schedule(), 100, :deposit)
    end

    test "respects max_fee" do
      s = schedule(max_fee: 100)
      assert {:ok, 100} = Fees.calculate(s, 1_000_000, :deposit)
    end

    test "returns 0 when ppm is 0" do
      s = schedule(deposit_ppm: 0)
      assert {:ok, 0} = Fees.calculate(s, 100_000, :deposit)
    end
  end

  describe "from_config/0" do
    test "returns a valid schedule" do
      schedule = Fees.from_config()
      assert %Fees{} = schedule
      assert schedule.deposit_ppm >= 0
      assert schedule.withdrawal_ppm >= 0
    end
  end
end
