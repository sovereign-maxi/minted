defmodule Minted.Mint.FeesIntegrationTest do
  @moduledoc "Integration tests for fee schedule calculation and boundary conditions."

  use Minted.IntegrationCase

  alias Minted.Mint.Fees

  @schedule %Fees{
    deposit_ppm: 1_000,
    withdrawal_ppm: 2_000,
    min_fee: 1,
    max_fee: 1_000_000
  }

  describe "calculate/3" do
    test "deposit fee with 1000 ppm (0.1%)" do
      assert {:ok, 1} = Fees.calculate(@schedule, 100, :deposit)
      assert {:ok, 1} = Fees.calculate(@schedule, 1_000, :deposit)
      assert {:ok, 10} = Fees.calculate(@schedule, 10_000, :deposit)
      assert {:ok, 100} = Fees.calculate(@schedule, 100_000, :deposit)
    end

    test "withdrawal fee with 2000 ppm (0.2%)" do
      assert {:ok, 1} = Fees.calculate(@schedule, 100, :withdrawal)
      assert {:ok, 2} = Fees.calculate(@schedule, 1_000, :withdrawal)
      assert {:ok, 20} = Fees.calculate(@schedule, 10_000, :withdrawal)
    end

    test "fees always round up (ceiling division)" do
      # 50 * 1000 / 1_000_000 = 0.05 -> ceil to 1
      assert {:ok, 1} = Fees.calculate(@schedule, 50, :deposit)
      # 99 * 1000 / 1_000_000 = 0.099 -> ceil to 1
      assert {:ok, 1} = Fees.calculate(@schedule, 99, :deposit)
    end

    test "zero ppm returns zero fee" do
      schedule = %{@schedule | deposit_ppm: 0}
      assert {:ok, 0} = Fees.calculate(schedule, 1_000, :deposit)
    end

    test "any positive amount is accepted" do
      assert {:ok, _} = Fees.calculate(@schedule, 1, :deposit)
      assert {:ok, _} = Fees.calculate(@schedule, 100_000_000, :deposit)
    end

    test "ppm capped at 1_000_000 in calculate (#39)" do
      # A schedule with ppm > 1_000_000 should be clamped to 100% fee.
      schedule = %Fees{
        deposit_ppm: 2_000_000,
        withdrawal_ppm: -500,
        min_fee: 1,
        max_fee: 1_000_000_000
      }

      # 2_000_000 ppm capped to 1_000_000 -> fee = amount (100%)
      assert {:ok, 1_000} = Fees.calculate(schedule, 1_000, :deposit)

      # Negative ppm clamped to 0 -> fee = 0
      assert {:ok, 0} = Fees.calculate(schedule, 1_000, :withdrawal)
    end

    test "large amounts with valid ppm produce correct fees (#39)" do
      schedule = %Fees{
        deposit_ppm: 1_000,
        withdrawal_ppm: 1_000,
        min_fee: 1,
        max_fee: 2_100_000_000_000_000
      }

      # 21M BTC in sats = 2_100_000_000_000_000
      assert {:ok, fee} = Fees.calculate(schedule, 2_100_000_000_000_000, :deposit)
      assert fee == 2_100_000_000_000
    end
  end

  describe "deposit at 2000 ppm (0.2%)" do
    @deposit_schedule %Fees{
      deposit_ppm: 2_000,
      withdrawal_ppm: 0,
      min_fee: 1,
      max_fee: 1_000_000
    }

    test "0.2% deposit fee calculation" do
      assert {:ok, 2} = Fees.calculate(@deposit_schedule, 1_000, :deposit)
      assert {:ok, 20} = Fees.calculate(@deposit_schedule, 10_000, :deposit)
      assert {:ok, 200} = Fees.calculate(@deposit_schedule, 100_000, :deposit)
    end

    test "withdrawal returns 0 fee when withdrawal_ppm is 0" do
      assert {:ok, 0} = Fees.calculate(@deposit_schedule, 1_000, :withdrawal)
      assert {:ok, 0} = Fees.calculate(@deposit_schedule, 10_000, :withdrawal)
      assert {:ok, 0} = Fees.calculate(@deposit_schedule, 100_000, :withdrawal)
    end
  end

  describe "from_config/0" do
    test "returns a fee schedule struct with correct ppm values" do
      schedule = Fees.from_config()
      assert %Fees{} = schedule
      assert schedule.deposit_ppm == 7_500
      assert schedule.withdrawal_ppm == 0
      assert is_integer(schedule.min_fee)
    end
  end

  describe "ppm validation (#39)" do
    setup do
      prev = Application.get_env(:minted, :lightning)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:minted, :lightning, prev),
          else: Application.delete_env(:minted, :lightning)
      end)

      :ok
    end

    test "from_config clamps negative ppm to 0" do
      Application.put_env(:minted, :lightning,
        fee_ppm: -100,
        fee_min_sats: 1,
        fee_max_sats: 100_000
      )

      schedule = Fees.from_config()
      assert schedule.deposit_ppm == 0
      assert schedule.withdrawal_ppm == 0
    end
  end
end
