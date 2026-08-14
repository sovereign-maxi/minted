defmodule Minted.Mint.QuoteTest do
  @moduledoc "Unit tests for Minted.Mint.Quote."

  use ExUnit.Case, async: true

  alias Minted.Mint.Quote

  describe "new/2" do
    test "creates a quote in pending status" do
      quote = Quote.new(1000)
      assert quote.status == :pending
      assert quote.amount == 1000
      assert quote.fee == 0
      assert is_binary(quote.id)
      assert %DateTime{} = quote.created_at
      assert %DateTime{} = quote.expires_at
      assert quote.denomination_breakdown == [8, 32, 64, 128, 256, 512]
    end

    test "includes fee in the quote" do
      quote = Quote.new(1000, 10)
      assert quote.fee == 10
    end

    test "generates unique IDs" do
      ids = for _ <- 1..100, do: Quote.new(100).id
      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "new_melt/3" do
    test "creates a melt quote in invoiced status" do
      quote = Quote.new_melt(5000, 50, "lnbc5000n1dummy")
      assert quote.status == :invoiced
      assert quote.type == :melt
      assert quote.amount == 5000
      assert quote.fee == 50
      assert quote.bolt11 == "lnbc5000n1dummy"
      assert is_binary(quote.id)
      assert %DateTime{} = quote.created_at
      assert %DateTime{} = quote.expires_at
    end

    test "raises on zero amount" do
      assert_raise FunctionClauseError, fn ->
        Quote.new_melt(0, 0, "lnbc1000n1dummy")
      end
    end

    test "raises on non-binary bolt11" do
      assert_raise FunctionClauseError, fn ->
        Quote.new_melt(1000, 10, nil)
      end
    end

    test "generates unique IDs" do
      ids = for _ <- 1..100, do: Quote.new_melt(100, 1, "lnbc100n1dummy").id
      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "method field" do
    test "new/2 defaults to bolt11" do
      quote = Quote.new(1000)
      assert quote.method == :bolt11
    end

    test "new_melt/3 defaults to bolt11" do
      quote = Quote.new_melt(1000, 10, "lnbc1000n1dummy")
      assert quote.method == :bolt11
    end
  end

  describe "owner_session field" do
    test "new/4 stores nil owner_session by default (API path)" do
      quote = Quote.new(1000)
      assert quote.owner_session == nil
    end

    test "new/4 stores the supplied owner_session (wallet path)" do
      quote = Quote.new(1000, 0, "keyset-a", "session-token-abc")
      assert quote.owner_session == "session-token-abc"
    end

    test "new_melt/4 stores nil owner_session by default (API path)" do
      quote = Quote.new_melt(1000, 10, "lnbc1000n1dummy")
      assert quote.owner_session == nil
    end

    test "new_melt/4 stores the supplied owner_session (wallet path)" do
      quote = Quote.new_melt(1000, 10, "lnbc1000n1dummy", "session-token-xyz")
      assert quote.owner_session == "session-token-xyz"
    end
  end

  describe "state machine transitions" do
    setup do
      %{quote: Quote.new(1000)}
    end

    test "pending -> invoiced", %{quote: quote} do
      assert {:ok, q} = Quote.attach_invoice(quote, "lnbc1000...")
      assert q.status == :invoiced
      assert q.invoice == "lnbc1000..."
    end

    test "invoiced -> paid (melt flow, no payment_hash)" do
      melt = Quote.new_melt(1000, 0, "lnbc1000n1dummy")
      assert {:ok, q} = Quote.mark_paid(melt)
      assert q.status == :paid
      assert %DateTime{} = q.paid_at
      assert q.payment_hash == nil
    end

    test "mark_paid/1 rejects mint quotes", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      assert {:error, :invalid_transition} = Quote.mark_paid(invoiced)
    end

    test "invoiced -> paid (mint flow, with payment_hash)", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      assert {:ok, q} = Quote.mark_paid(invoiced, "abc123hash")
      assert q.status == :paid
      assert %DateTime{} = q.paid_at
      assert q.payment_hash == "abc123hash"
    end

    test "mark_paid/2 rejects non-invoiced quote", %{quote: quote} do
      assert {:error, :invalid_transition} = Quote.mark_paid(quote, "somehash")
    end

    test "paid -> claimed", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      {:ok, paid} = Quote.mark_paid(invoiced, "abc123hash")
      assert {:ok, q} = Quote.claim(paid)
      assert q.status == :claimed
      assert %DateTime{} = q.claimed_at
    end

    test "pending -> expired", %{quote: quote} do
      assert {:ok, q} = Quote.expire(quote)
      assert q.status == :expired
    end

    test "invoiced -> expired", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      assert {:ok, q} = Quote.expire(invoiced)
      assert q.status == :expired
    end

    test "invalid: pending -> claimed", %{quote: quote} do
      assert {:error, :invalid_transition} = Quote.claim(quote)
    end

    test "invalid: pending -> paid", %{quote: quote} do
      assert {:error, :invalid_transition} = Quote.mark_paid(quote)
    end

    test "paid quotes cannot be expired (prevents fund loss)", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      {:ok, paid} = Quote.mark_paid(invoiced, "abc123hash")
      assert {:error, :invalid_transition} = Quote.expire(paid)
    end

    test "invalid: claimed -> anything", %{quote: quote} do
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      {:ok, paid} = Quote.mark_paid(invoiced, "abc123hash")
      {:ok, claimed} = Quote.claim(paid)
      assert {:error, :invalid_transition} = Quote.expire(claimed)
      assert {:error, :invalid_transition} = Quote.mark_paid(claimed)
    end

    test "paid quote can be claimed AFTER its expiry — payment is terminal", %{quote: quote} do
      # Regression: the previous claim/1 gate returned :quote_expired
      # for paid-but-expired quotes, permanently locking users out of
      # their own already-paid tokens if the wallet redeemed late.
      # Payment is a terminal positive; TTL only gates the
      # pre-payment window.
      {:ok, invoiced} = Quote.attach_invoice(quote, "lnbc1000...")
      {:ok, paid} = Quote.mark_paid(invoiced, "abc123hash")
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired_but_paid = %{paid | expires_at: past}

      assert Quote.expired?(expired_but_paid)
      assert {:ok, claimed} = Quote.claim(expired_but_paid)
      assert claimed.status == :claimed
    end
  end
end
