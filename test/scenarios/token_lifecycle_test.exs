defmodule Minted.Scenarios.TokenLifecycleTest do
  @moduledoc """
  Cross-domain scenario tests for the full token lifecycle:
  quote creation, payment, claim, swap, double-spend rejection,
  and expired keyset rejection.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Mint.{Keyset, Quote, Token}
  alias Minted.Mint.Services.{Quotes, Redemption, Signing}
  alias Minted.Mint.Signatures.Message
  alias Minted.Mint.Spent

  setup :clean_state

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "quote -> paid -> claim -> valid tokens" do
    test "full mint lifecycle produces spendable tokens", %{keyset: keyset} do
      amount = 64

      # 1. Create quote
      {:ok, quote} = Quotes.create_quote(amount)
      assert quote.status == :pending
      assert quote.amount == amount

      # 2. Attach invoice (pending -> invoiced)
      {:ok, invoiced} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, "lnbc#{amount}u1p_test_#{:erlang.unique_integer([:positive])}")
        end)

      assert invoiced.status == :invoiced

      # 3. Mark paid (invoiced -> paid)
      payment_hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, paid} =
        Quotes.update_quote(invoiced.id, fn q ->
          Quote.mark_paid(q, payment_hash)
        end)

      assert paid.status == :paid

      # 4. Claim (paid -> claimed)
      {:ok, claimed} =
        Quotes.update_quote(paid.id, fn q ->
          Quote.claim(q)
        end)

      assert claimed.status == :claimed

      # 5. Build valid tokens via full BDHKE round-trip for the denomination breakdown
      denominations = Token.decompose_amount(amount)
      tokens = build_valid_tokens(keyset, denominations)
      assert Enum.sum(Enum.map(tokens, & &1.amount)) == amount

      # Tokens should not be spent yet
      Enum.each(tokens, fn token ->
        refute Spent.spent?(token.secret)
      end)

      # 6. Redeem tokens successfully
      {:ok, total} = Redemption.redeem(tokens, keyset)
      assert total == amount

      # All tokens now spent
      Enum.each(tokens, fn token ->
        assert Spent.spent?(token.secret)
      end)
    end
  end

  describe "swap tokens" do
    test "burn old tokens via verify_and_reserve + commit, new tokens are valid", %{keyset: keyset} do
      # Build 2 valid tokens: 4 + 8 = 12 sats
      old_tokens = build_valid_tokens(keyset, [4, 8])
      total = 12

      # 1. Verify and reserve old tokens (reversible hold)
      {:ok, reserved_total} = Redemption.verify_and_reserve(old_tokens, keyset)
      assert reserved_total == total

      # Old tokens are now blocked (pending)
      Enum.each(old_tokens, fn token ->
        assert Spent.spent?(token.secret), "Reserved token should appear as spent"
      end)

      # 2. Commit reservation (permanently burn old tokens)
      :ok = Redemption.commit_reservation(old_tokens, keyset)

      # Old tokens are permanently spent
      Enum.each(old_tokens, fn token ->
        assert Spent.spent?(token.secret)
      end)

      # 3. Build fresh tokens representing the new denominations (1+2+4+4+1=12)
      new_tokens = build_valid_tokens(keyset, [1, 2, 4, 4, 1])
      assert Enum.sum(Enum.map(new_tokens, & &1.amount)) == total

      # New tokens should NOT be spent
      Enum.each(new_tokens, fn token ->
        refute Spent.spent?(token.secret)
      end)
    end

    test "release reservation makes tokens available again", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [8])

      # Reserve
      {:ok, 8} = Redemption.verify_and_reserve(tokens, keyset)
      assert Spent.spent?(hd(tokens).secret)

      # Release (simulating signing failure)
      :ok = Redemption.release_reservation(tokens, keyset)

      # Token is available again
      refute Spent.spent?(hd(tokens).secret)

      # Can be redeemed successfully
      {:ok, 8} = Redemption.redeem(tokens, keyset)
    end
  end

  describe "double-spend rejection" do
    test "second redemption of same tokens is rejected", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [16, 32])

      # First redemption succeeds
      {:ok, 48} = Redemption.redeem(tokens, keyset)

      # Second redemption fails with double-spend
      result = Redemption.redeem(tokens, keyset)

      assert match?({:error, :double_spend}, result) or
               match?({:error, {:already_spent, _}}, result),
             "Expected double-spend rejection, got: #{inspect(result)}"
    end

    test "reserve with already-spent input tokens is rejected", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [8])

      # Spend the token first
      {:ok, 8} = Redemption.redeem(tokens, keyset)

      # Attempt to reserve spent tokens (as would happen in a swap)
      result = Redemption.verify_and_reserve(tokens, keyset)
      assert {:error, :double_spend} = result
    end
  end

  describe "expired keyset rejection" do
    test "redeem with expired keyset is rejected" do
      # Generate a fresh keyset, then retire and expire it
      expired_keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(expired_keyset)
      {:ok, expired} = Keyset.expire(retired)

      # Build tokens against the original keyset (before expiry scrubbed keys)
      tokens = build_valid_tokens(expired_keyset, [4, 8])

      # Attempt redeem with the expired keyset -- the expired keyset has scrubbed
      # private keys so signature verification fails with :invalid_signature
      result = Redemption.redeem(tokens, expired)
      assert {:error, :invalid_signature, _index} = result
    end

    test "signing with expired keyset is rejected" do
      expired_keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(expired_keyset)
      {:ok, expired} = Keyset.expire(retired)

      secret = :crypto.strong_rand_bytes(32)
      {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
      messages = [%Message{amount: 1, b_prime: b_prime}]

      assert {:error, :keyset_expired} = Signing.sign(messages, expired)
    end

    test "signing with retired keyset is accepted (live keys)" do
      keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(keyset)

      secret = :crypto.strong_rand_bytes(32)
      {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
      messages = [%Message{amount: 1, b_prime: b_prime}]

      assert {:ok, [sig]} = Signing.sign(messages, retired)
      assert sig.keyset_id == retired.id
    end
  end
end
