defmodule Minted.Mint.Services.QuotesIntegrationTest do
  @moduledoc "Integration tests for mint quote creation, lookup, and expiry."

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Mint.Quote
  alias Minted.Mint.Services.Quotes

  setup do
    # Ensure ETS tables exist for SpentSet (Holder creates them).
    for {name, opts} <- [
          {Minted.Mint.Spent, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Y, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Pending, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    # Quote creation now pins the active keyset id at creation time —
    # seed one before any test in this module calls `create_quote`.
    seed_test_keyset()

    # Start Quotes if not already running.
    case GenServer.whereis(Quotes) do
      nil ->
        {:ok, pid} = Quotes.start_link()
        on_exit(fn -> safe_stop(pid) end)
        :ok

      _pid ->
        Quotes.clear()
        :ok
    end
  end

  describe "create_quote/1" do
    test "creates a mint quote with correct fields" do
      assert {:ok, %Quote{} = quote} = Quotes.create_quote(1_000)
      assert quote.amount == 1_000
      assert quote.status == :pending
      assert quote.type == :mint
      assert is_binary(quote.id)
      assert is_list(quote.denomination_breakdown)
      assert DateTime.compare(quote.expires_at, quote.created_at) == :gt
    end

    test "rejects zero amount" do
      assert_raise FunctionClauseError, fn ->
        Quotes.create_quote(0)
      end
    end

    test "rejects negative amount" do
      assert_raise FunctionClauseError, fn ->
        Quotes.create_quote(-100)
      end
    end

    test "rejects amount exceeding max deposit" do
      max = Application.get_env(:minted, :max_deposit_sats, 33_000_000)
      assert {:error, :amount_too_large} = Quotes.create_quote(max + 1)
    end

    test "each quote gets a unique ID" do
      {:ok, q1} = Quotes.create_quote(500)
      {:ok, q2} = Quotes.create_quote(500)
      assert q1.id != q2.id
    end
  end

  describe "get_quote/1" do
    test "retrieves a previously created quote" do
      {:ok, created} = Quotes.create_quote(2_000)
      assert {:ok, fetched} = Quotes.get_quote(created.id)
      assert fetched.id == created.id
      assert fetched.amount == 2_000
    end

    test "returns error for nonexistent quote" do
      assert {:error, :not_found} = Quotes.get_quote("nonexistent_id_#{:erlang.unique_integer([:positive])}")
    end
  end

  describe "update_quote/2 — state transitions" do
    test "attach_invoice transitions pending to invoiced" do
      {:ok, quote} = Quotes.create_quote(3_000)
      assert quote.status == :pending

      invoice = "lnbc3000u1p_test_#{:erlang.unique_integer([:positive])}"

      {:ok, updated} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, invoice)
        end)

      assert updated.status == :invoiced
      assert updated.invoice == invoice
    end

    test "mark_paid transitions invoiced to paid" do
      {:ok, quote} = Quotes.create_quote(4_000)
      invoice = "lnbc4000u1p_test_#{:erlang.unique_integer([:positive])}"

      {:ok, invoiced} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, invoice)
        end)

      assert invoiced.status == :invoiced

      payment_hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, paid} =
        Quotes.update_quote(invoiced.id, fn q ->
          Quote.mark_paid(q, payment_hash)
        end)

      assert paid.status == :paid
      assert paid.payment_hash == payment_hash
      assert %DateTime{} = paid.paid_at
    end

    test "claim transitions paid to claimed" do
      {:ok, quote} = Quotes.create_quote(5_000)

      # pending -> invoiced -> paid -> claimed
      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, "lnbc5000u1p_test")
        end)

      payment_hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.mark_paid(q, payment_hash)
        end)

      {:ok, claimed} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.claim(q)
        end)

      assert claimed.status == :claimed
      assert %DateTime{} = claimed.claimed_at
    end

    test "invalid transitions are rejected" do
      {:ok, quote} = Quotes.create_quote(1_000)

      # Cannot claim a pending quote
      assert {:error, :invalid_transition} =
               Quotes.update_quote(quote.id, fn q -> Quote.claim(q) end)

      # Cannot mark_paid a pending quote
      assert {:error, :invalid_transition} =
               Quotes.update_quote(quote.id, fn q -> Quote.mark_paid(q, "hash") end)
    end

    test "update_quote on nonexistent ID returns not_found" do
      fake_id = "gone_#{:erlang.unique_integer([:positive])}"

      assert {:error, :not_found} =
               Quotes.update_quote(fake_id, fn q -> Quote.claim(q) end)
    end
  end

  describe "full lifecycle: create → invoice → pay → claim" do
    test "walks through the entire mint quote lifecycle" do
      {:ok, q} = Quotes.create_quote(10_000)
      assert q.status == :pending

      # Attach invoice
      {:ok, _} =
        Quotes.update_quote(q.id, fn quote ->
          Quote.attach_invoice(quote, "lnbc10000u1p_full_lifecycle")
        end)

      {:ok, q} = Quotes.get_quote(q.id)
      assert q.status == :invoiced

      # Mark paid
      hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, _} =
        Quotes.update_quote(q.id, fn quote ->
          Quote.mark_paid(quote, hash)
        end)

      {:ok, q} = Quotes.get_quote(q.id)
      assert q.status == :paid

      # Claim
      {:ok, _} =
        Quotes.update_quote(q.id, fn quote ->
          Quote.claim(quote)
        end)

      {:ok, q} = Quotes.get_quote(q.id)
      assert q.status == :claimed
    end
  end

  describe "expiry behavior" do
    test "expired quote cannot be marked paid" do
      {:ok, quote} = Quotes.create_quote(1_000)

      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, "lnbc_expire_test")
        end)

      # Manually force the quote to be expired by updating expires_at to the past.
      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          past = DateTime.add(DateTime.utc_now(), -3600, :second)
          {:ok, %{q | expires_at: past}}
        end)

      {:ok, expired_quote} = Quotes.get_quote(quote.id)
      assert Quote.expired?(expired_quote)

      # Attempting mark_paid should fail
      assert {:error, :quote_expired} =
               Quotes.update_quote(quote.id, fn q ->
                 Quote.mark_paid(q, "somehash")
               end)
    end

    test "Quote.expire/1 transitions pending/invoiced to expired" do
      {:ok, quote} = Quotes.create_quote(1_000)

      {:ok, expired} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.expire(q)
        end)

      assert expired.status == :expired
    end

    test "cannot expire a paid quote" do
      {:ok, quote} = Quotes.create_quote(1_000)

      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, "lnbc_test")
        end)

      hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, _} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.mark_paid(q, hash)
        end)

      assert {:error, :invalid_transition} =
               Quotes.update_quote(quote.id, fn q -> Quote.expire(q) end)
    end
  end

  describe "clear/0" do
    test "removes all quotes" do
      {:ok, q1} = Quotes.create_quote(1_000)
      {:ok, q2} = Quotes.create_quote(2_000)

      :ok = Quotes.clear()

      assert {:error, :not_found} = Quotes.get_quote(q1.id)
      assert {:error, :not_found} = Quotes.get_quote(q2.id)
    end
  end

  describe "melt quote lifecycle" do
    test "create_melt_quote starts in invoiced state with bolt11" do
      bolt11 = "lnbc1000u1p_melt_#{:erlang.unique_integer([:positive])}"
      {:ok, quote} = Quotes.create_melt_quote(1_000, bolt11)

      assert quote.type == :melt
      assert quote.status == :invoiced
      assert quote.bolt11 == bolt11
      assert quote.invoice == bolt11
    end

    test "create_melt_quote charges a routing-fee reserve, not zero" do
      # Regression: the API melt path used to build the reserve from
      # `withdrawal_fee_ppm` (operator margin, 0 in prod), which meant
      # every routed melt drained the mint's channel balance for any
      # non-cheapest route. Reserve MUST come from
      # `routing_fee_estimate_ppm`.
      bolt11 = "lnbc1000u1p_reserve_#{:erlang.unique_integer([:positive])}"
      {:ok, quote} = Quotes.create_melt_quote(100_000, bolt11)

      assert quote.fee > 0, "melt fee must reserve routing capacity, got 0"
      assert quote.fee == Minted.Lightning.Facade.routing_fee_estimate(100_000)
    end

    test "rejects a second melt quote for a bolt11 already in :invoiced" do
      bolt11 = "lnbc1000u1p_dupe_#{:erlang.unique_integer([:positive])}"
      {:ok, _q1} = Quotes.create_melt_quote(1_000, bolt11)
      assert {:error, :duplicate_bolt11} = Quotes.create_melt_quote(1_000, bolt11)
    end

    test "rejects a second melt quote for a bolt11 whose first is :paying" do
      bolt11 = "lnbc1000u1p_paying_#{:erlang.unique_integer([:positive])}"
      {:ok, q1} = Quotes.create_melt_quote(1_000, bolt11)
      {:ok, _} = Quotes.update_quote(q1.id, &Quote.start_payment/1)
      assert {:error, :duplicate_bolt11} = Quotes.create_melt_quote(1_000, bolt11)
    end

    test "rejects a second melt quote while the first sits :settlement_unknown" do
      bolt11 = "lnbc1000u1p_unknown_#{:erlang.unique_integer([:positive])}"
      {:ok, q1} = Quotes.create_melt_quote(1_000, bolt11)
      {:ok, q1_paying} = Quotes.update_quote(q1.id, &Quote.start_payment/1)
      assert q1_paying.status == :paying
      {:ok, _} = Quotes.update_quote(q1.id, &Quote.mark_settlement_unknown/1)

      assert {:error, :duplicate_bolt11} = Quotes.create_melt_quote(1_000, bolt11)
    end

    test "allows a fresh melt quote after the previous one aborts back to :invoiced" do
      # abort_payment returns settlement_unknown → invoiced, at which
      # point the ledger has released the reservation and a new quote
      # is safe. But :invoiced itself remains "active" per the
      # duplicate rule, so we drive it to :expired first.
      bolt11 = "lnbc1000u1p_expire_#{:erlang.unique_integer([:positive])}"
      {:ok, q1} = Quotes.create_melt_quote(1_000, bolt11)
      {:ok, _} = Quotes.update_quote(q1.id, &Quote.expire/1)

      assert {:ok, _q2} = Quotes.create_melt_quote(1_000, bolt11)
    end
  end

  describe "owner-scoped restore" do
    test "find_active_deposits_for_owner returns only the caller's quotes" do
      # Alice and Mallory each create a mint quote; the restore path for
      # Alice must not surface Mallory's quote (and vice-versa).
      {:ok, alice_q} = Quotes.create_quote(1_000, "alice-session")
      {:ok, mallory_q} = Quotes.create_quote(2_000, "mallory-session")

      # Simulate both quotes reaching :invoiced (the restore filter accepts
      # :invoiced and :paid; :pending is not "active").
      {:ok, _} = Quotes.update_quote(alice_q.id, &Quote.attach_invoice(&1, "lnbc1000alice"))
      {:ok, _} = Quotes.update_quote(mallory_q.id, &Quote.attach_invoice(&1, "lnbc2000mallory"))

      alice_seen = Quotes.find_active_deposits_for_owner("alice-session")
      mallory_seen = Quotes.find_active_deposits_for_owner("mallory-session")

      assert Enum.map(alice_seen, & &1.id) == [alice_q.id]
      assert Enum.map(mallory_seen, & &1.id) == [mallory_q.id]
    end

    test "nil owner returns empty list" do
      {:ok, _q} = Quotes.create_quote(1_000, "some-session")
      assert Quotes.find_active_deposits_for_owner(nil) == []
    end

    test "empty owner returns empty list" do
      {:ok, _q} = Quotes.create_quote(1_000, "some-session")
      assert Quotes.find_active_deposits_for_owner("") == []
    end

    test "API-created quotes (nil owner) are invisible to any owner-scoped restore" do
      # /v1/mint/quote creates a quote with no owner_session — those quotes
      # must not surface in any browser-wallet session's restore list.
      {:ok, api_quote} = Quotes.create_quote(1_000)
      {:ok, _} = Quotes.update_quote(api_quote.id, &Quote.attach_invoice(&1, "lnbc1000api"))

      assert Quotes.find_active_deposits_for_owner("any-session-token") == []
    end

    test "global find_active_deposits/0 still returns everything (reserves accounting)" do
      # The reserves source needs the full pending-liability view.
      {:ok, q_alice} = Quotes.create_quote(1_000, "alice")
      {:ok, q_api} = Quotes.create_quote(2_000)

      {:ok, _} = Quotes.update_quote(q_alice.id, &Quote.attach_invoice(&1, "lnbc1000alice"))
      {:ok, _} = Quotes.update_quote(q_api.id, &Quote.attach_invoice(&1, "lnbc2000api"))

      all_ids = Quotes.find_active_deposits() |> Enum.map(& &1.id) |> Enum.sort()
      assert all_ids == Enum.sort([q_alice.id, q_api.id])
    end
  end

  describe "active-quote capacity caps" do
    test "per-session cap rejects the 6th active quote for one owner" do
      for _ <- 1..5 do
        assert {:ok, _q} = Quotes.create_quote(1_000, "session-a")
      end

      assert {:error, :too_many_active_quotes} = Quotes.create_quote(1_000, "session-a")
    end

    test "a different owner session is unaffected" do
      for _ <- 1..5 do
        assert {:ok, _q} = Quotes.create_quote(1_000, "session-a")
      end

      assert {:ok, _q} = Quotes.create_quote(1_000, "session-b")
    end

    test "nil-owner (API) quotes skip the per-session cap" do
      for _ <- 1..7 do
        assert {:ok, _q} = Quotes.create_quote(1_000)
      end
    end

    test "expired quotes stop counting against the cap" do
      for _ <- 1..5 do
        assert {:ok, _q} = Quotes.create_quote(1_000, "session-a")
      end

      # Expire them all via the public transition.
      Quotes.list_by_status(:pending)
      |> Enum.each(fn q ->
        {:ok, _} = Quotes.update_quote(q.id, &Quote.expire/1)
      end)

      assert {:ok, _q} = Quotes.create_quote(1_000, "session-a")
    end
  end
end
