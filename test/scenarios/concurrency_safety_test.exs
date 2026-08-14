defmodule Minted.Scenarios.ConcurrencySafetyTest do
  @moduledoc """
  Cross-domain scenario tests for concurrency safety guarantees:
  serialized double-spend detection, single-claim enforcement,
  and concurrent mark_spent atomicity.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.ProcessHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Mint.Quote
  alias Minted.Mint.Services.{Quotes, Redemption}
  alias Minted.Mint.Spent

  setup :clean_state

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "concurrent double-spend attempts" do
    test "10 concurrent redemptions of same token — exactly 1 succeeds", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [16])

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Redemption.redeem(tokens, keyset)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1, "Expected exactly 1 success, got #{successes}"
      assert failures == 9, "Expected exactly 9 failures, got #{failures}"

      # Verify the token is actually spent
      Enum.each(tokens, fn token ->
        assert Spent.spent?(token.secret)
      end)
    end

    test "10 concurrent redemptions of same batch — exactly 1 succeeds", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [1, 2, 4, 8])

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Redemption.redeem(tokens, keyset)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      assert successes == 1, "Expected exactly 1 success, got #{successes}"

      # All tokens spent
      Enum.each(tokens, fn token ->
        assert Spent.spent?(token.secret)
      end)
    end
  end

  describe "concurrent quote claims" do
    test "10 concurrent claims on same quote — exactly 1 succeeds" do
      # Create and advance a quote to :paid status
      {:ok, quote} = Quotes.create_quote(100)

      {:ok, _invoiced} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.attach_invoice(q, "lnbc100u1p_concurrent_#{:erlang.unique_integer([:positive])}")
        end)

      payment_hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      {:ok, _paid} =
        Quotes.update_quote(quote.id, fn q ->
          Quote.mark_paid(q, payment_hash)
        end)

      # 10 concurrent claim attempts via update_quote
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Quotes.update_quote(quote.id, fn q ->
              Quote.claim(q)
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &match?({:ok, %Quote{status: :claimed}}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1, "Expected exactly 1 successful claim, got #{successes}"
      assert failures == 9, "Expected 9 claim failures, got #{failures}"

      # Verify quote is in claimed state
      {:ok, final_quote} = Quotes.get_quote(quote.id)
      assert final_quote.status == :claimed
    end
  end

  describe "concurrent mark_spent — no data loss" do
    test "concurrent single mark_spent on distinct secrets preserves all", %{keyset: keyset} do
      # Generate 20 distinct tokens
      tokens = build_valid_tokens(keyset, List.duplicate(1, 20))

      # Mark all spent concurrently
      tasks =
        Enum.map(tokens, fn token ->
          Task.async(fn ->
            Spent.mark_spent(token.secret, keyset.id)
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # All should succeed (distinct secrets)
      assert Enum.all?(results, &(&1 == :ok)),
             "Expected all mark_spent to succeed, got: #{inspect(results)}"

      # Verify all are in the spent set
      Enum.each(tokens, fn token ->
        assert Spent.spent?(token.secret),
               "Token secret should be in spent set after mark_spent"
      end)

      # Verify count matches
      await_condition(fn -> Spent.count() >= 20 end)
    end

    test "concurrent batch mark_spent on overlapping sets — exactly 1 batch succeeds", %{keyset: keyset} do
      # Build shared tokens that both batches will try to spend
      shared_tokens = build_valid_tokens(keyset, [2, 4])

      entries = Enum.map(shared_tokens, fn t -> {t.secret, keyset.id} end)

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Spent.mark_spent_batch(entries)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      successes = Enum.count(results, &(&1 == :ok))
      double_spends = Enum.count(results, &(&1 == {:error, :double_spend}))

      assert successes == 1, "Expected exactly 1 batch success, got #{successes}"
      assert double_spends == 9, "Expected 9 double_spend rejections, got #{double_spends}"
    end
  end
end
