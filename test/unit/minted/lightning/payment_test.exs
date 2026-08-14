defmodule Minted.Lightning.PaymentTest do
  @moduledoc "Unit tests for Minted.Lightning.Payment."

  use ExUnit.Case, async: true

  alias Minted.Lightning.Payment

  describe "new/1" do
    test "creates a pending payment with required fields" do
      payment =
        Payment.new(
          bolt11: "lnbc10u1p...",
          amount_sats: 1000
        )

      assert payment.bolt11 == "lnbc10u1p..."
      assert payment.amount_sats == 1000
      assert payment.status == :pending
      assert payment.attempts == []
      assert payment.max_attempts == 3
      assert payment.fee_limit_sats == 1000
      assert is_binary(payment.id)
      assert byte_size(payment.id) > 0
      assert %DateTime{} = payment.created_at
    end

    test "sets optional fields" do
      payment =
        Payment.new(
          bolt11: "lnbc10u1p...",
          amount_sats: 5000,
          withdrawal_id: "wd-123",
          fee_limit_sats: 500,
          max_attempts: 5
        )

      assert payment.withdrawal_id == "wd-123"
      assert payment.fee_limit_sats == 500
      assert payment.max_attempts == 5
    end
  end

  describe "to_firebird/1" do
    test "forwards fee_limit_sats to the FireBird payment" do
      payment =
        Payment.new(
          bolt11: "lnbc10u1p...",
          amount_sats: 1000,
          fee_limit_sats: 42
        )

      fb_payment = Payment.to_firebird(payment)
      assert fb_payment.fee_limit_sats == 42
    end

    test "uses the default 1000-sat cap when caller passes none" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      fb_payment = Payment.to_firebird(payment)
      assert fb_payment.fee_limit_sats == 1000
    end

    test "extracts ln_payment_hash from the bolt11 for preimage validation" do
      # BOLT11 spec test vector — decodes to a known 32-byte payment
      # hash. Without this on the FireBird payment, mark_succeeded
      # accepts every preimage unvalidated and the proof-of-payment
      # check is dead code.
      spec_invoice =
        "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp"

      spec_hash =
        Base.decode16!("0001020304050607080900010203040506070809000102030405060708090102", case: :lower)

      payment = Payment.new(bolt11: spec_invoice, amount_sats: 250_000)
      fb_payment = Payment.to_firebird(payment)

      assert fb_payment.ln_payment_hash == spec_hash
      assert byte_size(fb_payment.ln_payment_hash) == 32
    end

    test "ln_payment_hash is nil when the bolt11 cannot be parsed" do
      # Preflight-invalid bolt11 that can't produce a hash. Executor
      # rejects such payments at preflight anyway, but to_firebird
      # must not raise — nil surfaces the case cleanly.
      payment = Payment.new(bolt11: "lnbc_totally_bogus", amount_sats: 1000)
      fb_payment = Payment.to_firebird(payment)

      assert fb_payment.ln_payment_hash == nil
    end
  end

  describe "mark_in_flight/1" do
    test "transitions from pending to in_flight" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)

      assert {:ok, in_flight} = Payment.mark_in_flight(payment)
      assert in_flight.status == :in_flight
      assert length(in_flight.attempts) == 1
      assert %{attempted_at: %DateTime{}, error: nil} = hd(in_flight.attempts)
    end

    test "transitions from retrying to in_flight" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      {:ok, retrying} = Payment.mark_failed(in_flight, :timeout)

      assert {:ok, in_flight2} = Payment.mark_in_flight(retrying)
      assert in_flight2.status == :in_flight
      assert length(in_flight2.attempts) == 2
    end

    test "returns error for invalid transitions" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      {:ok, succeeded} = Payment.mark_succeeded(in_flight, "preimage")

      assert {:error, :invalid_transition} = Payment.mark_in_flight(succeeded)
    end
  end

  describe "mark_succeeded/2" do
    test "transitions from in_flight to succeeded with preimage" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      {:ok, in_flight} = Payment.mark_in_flight(payment)

      assert {:ok, succeeded} = Payment.mark_succeeded(in_flight, "preimage123", 5)
      assert succeeded.status == :succeeded
      assert succeeded.preimage == "preimage123"
      assert succeeded.routing_fee_sat == 5
    end

    test "returns error for non-in_flight payment" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)

      assert {:error, :invalid_transition} = Payment.mark_succeeded(payment, "preimage", 0)
    end
  end

  describe "mark_failed/2" do
    test "transitions to retrying when attempts remain" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      {:ok, in_flight} = Payment.mark_in_flight(payment)

      assert {:ok, failed} = Payment.mark_failed(in_flight, :timeout)
      assert failed.status == :retrying
      assert length(failed.attempts) == 1
      assert hd(failed.attempts).error == :timeout
    end

    test "transitions to exhausted when all attempts used" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000, max_attempts: 1)
      {:ok, in_flight} = Payment.mark_in_flight(payment)

      assert {:ok, exhausted} = Payment.mark_failed(in_flight, :route_not_found)
      assert exhausted.status == :exhausted
    end

    test "reaches exhausted after max_attempts failures" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000, max_attempts: 2)

      {:ok, in_flight1} = Payment.mark_in_flight(payment)
      {:ok, retrying} = Payment.mark_failed(in_flight1, :timeout)
      {:ok, in_flight2} = Payment.mark_in_flight(retrying)
      {:ok, exhausted} = Payment.mark_failed(in_flight2, :timeout)

      assert exhausted.status == :exhausted
      assert length(exhausted.attempts) == 2
    end

    test "returns error for non-in_flight payment" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)

      assert {:error, :invalid_transition} = Payment.mark_failed(payment, :error)
    end
  end

  describe "next_retry_delay/1" do
    test "returns exponential backoff delays" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)

      # 0 attempts -> 2^0 * 1000 = 1000ms
      assert Payment.next_retry_delay(payment) == 1000

      {:ok, in_flight} = Payment.mark_in_flight(payment)
      {:ok, retrying} = Payment.mark_failed(in_flight, :timeout)

      # 1 attempt -> 2^1 * 1000 = 2000ms
      assert Payment.next_retry_delay(retrying) == 2000

      {:ok, in_flight2} = Payment.mark_in_flight(retrying)
      {:ok, retrying2} = Payment.mark_failed(in_flight2, :timeout)

      # 2 attempts -> 2^2 * 1000 = 4000ms
      assert Payment.next_retry_delay(retrying2) == 4000
    end
  end

  describe "retriable?/1" do
    test "returns true for retrying payments" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      {:ok, retrying} = Payment.mark_failed(in_flight, :timeout)

      assert Payment.retriable?(retrying)
    end

    test "returns false for other statuses" do
      payment = Payment.new(bolt11: "lnbc10u1p...", amount_sats: 1000)
      refute Payment.retriable?(payment)

      {:ok, in_flight} = Payment.mark_in_flight(payment)
      refute Payment.retriable?(in_flight)

      {:ok, succeeded} = Payment.mark_succeeded(in_flight, "preimage")
      refute Payment.retriable?(succeeded)
    end
  end
end
