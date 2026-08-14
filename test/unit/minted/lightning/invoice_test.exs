defmodule Minted.Lightning.InvoiceTest do
  @moduledoc "Unit tests for Minted.Lightning.Invoice."

  use ExUnit.Case, async: true

  alias Minted.Lightning.Invoice

  # Generates a hex-encoded 32-byte preimage and its payment_hash.
  # Mirrors real Lightning: preimage is 32 bytes, payment_hash = SHA256(preimage) as hex.
  defp make_preimage_pair(seed) when is_binary(seed) do
    # Derive a deterministic 32-byte preimage from the seed
    raw_bytes = :crypto.hash(:sha256, seed)
    hex_preimage = Base.encode16(raw_bytes, case: :lower)
    payment_hash = Base.encode16(:crypto.hash(:sha256, raw_bytes), case: :lower)
    {hex_preimage, payment_hash}
  end

  describe "new/1" do
    test "creates a pending invoice with required fields" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert invoice.payment_hash == "abc123"
      assert invoice.bolt11 == "lnbc10u1p..."
      assert invoice.amount_sats == 1000
      assert invoice.status == :pending
      assert invoice.preimage == nil
      assert invoice.paid_at == nil
      assert invoice.quote_id == nil
      assert %DateTime{} = invoice.created_at
      assert %DateTime{} = invoice.expires_at
    end

    test "sets optional quote_id" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000,
          quote_id: "quote-456"
        )

      assert invoice.quote_id == "quote-456"
    end

    test "uses custom TTL when provided" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000,
          ttl_seconds: 60
        )

      diff = DateTime.diff(invoice.expires_at, invoice.created_at, :second)
      assert diff == 60
    end

    test "defaults to 1-hour TTL" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      diff = DateTime.diff(invoice.expires_at, invoice.created_at, :second)
      assert diff == 3600
    end
  end

  describe "mark_paid/2" do
    test "transitions pending to paid with preimage" do
      {hex_preimage, payment_hash} = make_preimage_pair("preimage_secret")

      invoice =
        Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert {:ok, paid} = Invoice.mark_paid(invoice, hex_preimage)
      assert paid.status == :paid
      assert paid.preimage == hex_preimage
      assert %DateTime{} = paid.paid_at
    end

    test "returns :already_paid for idempotent re-mark with same preimage" do
      {hex_preimage, payment_hash} = make_preimage_pair("preimage_secret")

      invoice =
        Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, paid} = Invoice.mark_paid(invoice, hex_preimage)
      assert {:already_paid, ^paid} = Invoice.mark_paid(paid, hex_preimage)
    end

    test "returns error for different preimage on paid invoice" do
      {hex_preimage, payment_hash} = make_preimage_pair("preimage_secret")

      invoice =
        Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, paid} = Invoice.mark_paid(invoice, hex_preimage)
      {other_hex, _} = make_preimage_pair("different_preimage")
      assert {:error, :preimage_mismatch} = Invoice.mark_paid(paid, other_hex)
    end

    test "returns error for expired invoice" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, expired} = Invoice.mark_expired(invoice)
      assert {:error, :invoice_expired} = Invoice.mark_paid(expired, "preimage")
    end

    test "returns error for preimage that does not match payment_hash" do
      {hex_preimage, _hash} = make_preimage_pair("some_preimage")

      invoice =
        Invoice.new(
          payment_hash: "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert {:error, :preimage_mismatch} = Invoice.mark_paid(invoice, hex_preimage)
    end

    test "returns error for non-hex preimage" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert {:error, :preimage_mismatch} = Invoice.mark_paid(invoice, "not_valid_hex!")
    end
  end

  describe "mark_expired/1" do
    test "transitions pending to expired" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert {:ok, expired} = Invoice.mark_expired(invoice)
      assert expired.status == :expired
    end

    test "returns error for paid invoice" do
      {hex_preimage, payment_hash} = make_preimage_pair("preimage")

      invoice =
        Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, paid} = Invoice.mark_paid(invoice, hex_preimage)
      assert {:error, :already_paid} = Invoice.mark_expired(paid)
    end

    test "is idempotent for already expired invoice" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, expired} = Invoice.mark_expired(invoice)
      assert {:ok, ^expired} = Invoice.mark_expired(expired)
    end
  end

  describe "expired?/1" do
    test "returns false for invoice with future expiry" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000,
          ttl_seconds: 3600
        )

      refute Invoice.expired?(invoice)
    end

    test "returns true for invoice with past expiry" do
      invoice =
        Invoice.new(
          payment_hash: "abc123",
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      # Manually set expires_at to the past.
      expired_invoice = %{invoice | expires_at: DateTime.add(DateTime.utc_now(), -10, :second)}
      assert Invoice.expired?(expired_invoice)
    end
  end

  describe "Inspect protocol" do
    test "redacts preimage in inspection" do
      {hex_preimage, payment_hash} = make_preimage_pair("super_secret_preimage")

      invoice =
        Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      {:ok, paid} = Invoice.mark_paid(invoice, hex_preimage)
      inspected = inspect(paid)
      refute String.contains?(inspected, hex_preimage)
      assert String.contains?(inspected, "REDACTED")
    end
  end
end
