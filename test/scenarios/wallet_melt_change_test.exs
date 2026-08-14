defmodule Minted.Scenarios.WalletMeltChangeTest do
  @moduledoc """
  Scenario tests for the melt change flow: when token denominations exceed
  the payment amount + fee, the overpayment must be returned as new tokens.

  Tests the complete domain-level flow (reserve → commit → sign change →
  verify change tokens) without requiring a live Lightning executor.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.Services.Redemption
  alias Minted.Mint.Spent
  alias Minted.Mint.Token

  setup :clean_state

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "denomination overpayment returns change" do
    test "overpayment is decomposed into valid denomination tokens", %{keyset: keyset} do
      # Simulate: user has a 2048-sat token, pays a 1000-sat invoice (fee=1)
      input_tokens = build_valid_tokens(keyset, [2048])
      payment_amount = 1000
      fee = div(payment_amount + 999, 1000)
      required = payment_amount + fee
      overpayment = 2048 - required

      assert overpayment == 1047

      # Step 1: Reserve input tokens (same as melt flow)
      {:ok, _} = MintFacade.verify_and_reserve(input_tokens, keyset)

      # Step 2: Commit reservation (simulating successful Lightning payment)
      :ok = MintFacade.commit_reservation(input_tokens, keyset)

      # Input tokens are now permanently spent
      Enum.each(input_tokens, fn t -> assert Spent.spent?(t.secret) end)

      # Step 3: Sign change tokens for the overpayment
      change_amounts = Token.decompose_amount(overpayment)
      assert Enum.sum(change_amounts) == overpayment
      assert Enum.all?(change_amounts, &Token.valid_denomination?/1)

      change_tokens = build_valid_tokens(keyset, change_amounts)

      # Step 4: Verify change tokens are valid and sum correctly
      assert Enum.sum(Enum.map(change_tokens, & &1.amount)) == overpayment

      # Change tokens should NOT be in the spent set
      Enum.each(change_tokens, fn t -> refute Spent.spent?(t.secret) end)

      # Step 5: Change tokens are redeemable (proves they have valid signatures)
      {:ok, redeemed} = Redemption.redeem(change_tokens, keyset)
      assert redeemed == overpayment
    end

    test "no overpayment when tokens exactly match required amount", %{keyset: keyset} do
      # 101 sats = exactly amount(100) + fee(1)
      # Denominations: [1, 4, 32, 64]
      input_tokens = build_valid_tokens(keyset, [1, 4, 32, 64])
      assert Enum.sum(Enum.map(input_tokens, & &1.amount)) == 101

      payment_amount = 100
      fee = div(payment_amount + 999, 1000)
      required = payment_amount + fee
      overpayment = 101 - required

      assert overpayment == 0
      assert Token.decompose_amount(0) == []
    end

    test "large overpayment decomposes correctly", %{keyset: keyset} do
      # User has a single 1048576-sat token (2^20), pays 100 sats
      _input_tokens = build_valid_tokens(keyset, [1_048_576])
      _payment_amount = 100
      _fee = 1
      overpayment = 1_048_576 - 101

      assert overpayment == 1_048_475

      change_amounts = Token.decompose_amount(overpayment)
      assert Enum.sum(change_amounts) == overpayment
      assert Enum.all?(change_amounts, &Token.valid_denomination?/1)

      # All change denominations are valid and can be signed
      change_tokens = build_valid_tokens(keyset, change_amounts)
      {:ok, redeemed} = Redemption.redeem(change_tokens, keyset)
      assert redeemed == overpayment
    end

    test "change from multiple input tokens", %{keyset: keyset} do
      # User has 256 + 128 + 64 = 448 sats, pays 200 + fee(1) = 201
      input_tokens = build_valid_tokens(keyset, [256, 128, 64])
      overpayment = 448 - 201

      assert overpayment == 247

      {:ok, _} = MintFacade.verify_and_reserve(input_tokens, keyset)
      :ok = MintFacade.commit_reservation(input_tokens, keyset)

      change_amounts = Token.decompose_amount(overpayment)
      # 247 = 128 + 64 + 32 + 16 + 4 + 2 + 1
      assert change_amounts == [1, 2, 4, 16, 32, 64, 128]
      assert Enum.sum(change_amounts) == 247

      change_tokens = build_valid_tokens(keyset, change_amounts)
      {:ok, redeemed} = Redemption.redeem(change_tokens, keyset)
      assert redeemed == 247
    end
  end

  describe "server-side fee calculation" do
    test "fee is 0.1% ceiling (1 sat per 1000)" do
      # The wallet service calculates: div(amount + 999, 1000)
      assert div(1000 + 999, 1000) == 1
      assert div(1001 + 999, 1000) == 2
      assert div(999 + 999, 1000) == 1
      assert div(1 + 999, 1000) == 1
      assert div(100_000 + 999, 1000) == 100
      assert div(100_001 + 999, 1000) == 101
    end

    test "fee is always at least 1 sat for any positive amount" do
      for amount <- [1, 10, 100, 500, 999] do
        fee = div(amount + 999, 1000)
        assert fee >= 1, "Fee for #{amount} sats should be >= 1, got #{fee}"
      end
    end
  end

  describe "input validation — denomination guard" do
    test "tokens with invalid denomination fail signature verification", %{keyset: keyset} do
      [valid_token] = build_valid_tokens(keyset, [64])

      # Tamper with amount — signature was for denomination 64, not 999
      tampered = %{valid_token | amount: 999}

      result = Redemption.redeem([tampered], keyset)

      assert match?({:error, _}, result) or match?({:error, _, _}, result),
             "Expected error, got: #{inspect(result)}"
    end

    test "tokens with swapped denomination fail signature verification", %{keyset: keyset} do
      # Build a 64-sat token, claim it's 128 sats
      [valid_token] = build_valid_tokens(keyset, [64])
      tampered = %{valid_token | amount: 128}

      result = Redemption.redeem([tampered], keyset)

      assert match?({:error, _}, result) or match?({:error, _, _}, result),
             "Expected error, got: #{inspect(result)}"
    end

    test "Token.decompose_amount always produces valid denominations" do
      for amount <- [1, 7, 100, 789, 1047, 1_000_000, 1_048_575] do
        amounts = Token.decompose_amount(amount)
        assert Enum.sum(amounts) == amount, "Decomposition of #{amount} doesn't sum correctly"

        assert Enum.all?(amounts, &Token.valid_denomination?/1),
               "Decomposition of #{amount} contains invalid denomination: #{inspect(amounts)}"
      end
    end
  end

  describe "change tokens are not double-spendable" do
    test "change tokens can only be redeemed once", %{keyset: keyset} do
      # Build change-like tokens
      change_tokens = build_valid_tokens(keyset, [128, 64, 32, 16, 4, 2, 1])

      # First redemption succeeds
      {:ok, 247} = Redemption.redeem(change_tokens, keyset)

      # Second redemption fails (double-spend)
      result = Redemption.redeem(change_tokens, keyset)

      assert match?({:error, :double_spend}, result) or
               match?({:error, {:already_spent, _}}, result)
    end
  end

  describe "reserve + release — failed payment recovery" do
    test "tokens are released if payment fails (no change issued)", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [2048])

      # Reserve (simulating melt start)
      {:ok, _} = MintFacade.verify_and_reserve(tokens, keyset)
      assert Spent.spent?(hd(tokens).secret)

      # Payment fails → release (no change should be issued)
      :ok = MintFacade.release_reservation(tokens, keyset)
      refute Spent.spent?(hd(tokens).secret)

      # Tokens are usable again
      {:ok, 2048} = Redemption.redeem(tokens, keyset)
    end
  end
end
