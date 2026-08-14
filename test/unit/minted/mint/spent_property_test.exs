defmodule Minted.Mint.SpentPropertyTest do
  @moduledoc "Property tests for Minted.Mint.Spent."

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Minted.Mint.Spent

  @moduletag :property
  @moduletag timeout: 120_000

  setup do
    on_exit(fn ->
      if :ets.whereis(Minted.Mint.Spent) != :undefined do
        Spent.clear()
      end
    end)

    :ok
  end

  describe "idempotency" do
    property "marking same token spent twice always fails on second attempt" do
      check all(
              secret <- binary(min_length: 1, max_length: 256),
              max_runs: 10_000
            ) do
        assert :ok = Spent.mark_spent(secret, "keyset01")
        assert {:error, :already_spent} = Spent.mark_spent(secret, "keyset01")

        Spent.clear()
      end
    end

    property "spent? reflects mark_spent state transitions" do
      check all(
              secret <- binary(min_length: 1, max_length: 256),
              max_runs: 10_000
            ) do
        refute Spent.spent?(secret)
        :ok = Spent.mark_spent(secret, "keyset01")
        assert Spent.spent?(secret)

        Spent.clear()
      end
    end

    property "distinct secrets never collide in the spent set" do
      check all(
              a <- binary(length: 32),
              b <- binary(length: 32),
              a != b,
              max_runs: 5_000
            ) do
        :ok = Spent.mark_spent(a, "keyset01")
        refute Spent.spent?(b)
        :ok = Spent.mark_spent(b, "keyset01")
        assert Spent.spent?(a)
        assert Spent.spent?(b)

        Spent.clear()
      end
    end
  end

  describe "batch atomicity" do
    property "batch with one already-spent entry rejects entire batch" do
      check all(
              pre_spent <- binary(length: 32),
              fresh_count <- integer(1..10),
              max_runs: 1_000
            ) do
        :ok = Spent.mark_spent(pre_spent, "keyset01")

        fresh = for _ <- 1..fresh_count, do: {:crypto.strong_rand_bytes(32), "keyset01"}
        batch = [{pre_spent, "keyset01"} | fresh]

        assert {:error, :double_spend} = Spent.mark_spent_batch(batch)

        for {secret, _kid} <- fresh do
          refute Spent.spent?(secret)
        end

        Spent.clear()
      end
    end

    property "successful batch marks all entries as spent" do
      check all(
              count <- integer(1..20),
              max_runs: 1_000
            ) do
        entries =
          for _ <- 1..count do
            {:crypto.strong_rand_bytes(32), "keyset01"}
          end

        assert :ok = Spent.mark_spent_batch(entries)

        for {secret, _kid} <- entries do
          assert Spent.spent?(secret)
        end

        assert Spent.count() >= count

        Spent.clear()
      end
    end
  end

  describe "count tracking" do
    property "count increases by exactly the number of new entries" do
      check all(
              count <- integer(1..50),
              max_runs: 500
            ) do
        Spent.clear()
        before = Spent.count()

        for _ <- 1..count do
          :ok = Spent.mark_spent(:crypto.strong_rand_bytes(32), "keyset01")
        end

        assert Spent.count() == before + count

        Spent.clear()
      end
    end
  end
end
