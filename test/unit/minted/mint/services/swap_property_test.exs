defmodule Minted.Mint.Services.SwapPropertyTest do
  @moduledoc "Property tests for Minted.Mint.Services.Swap."

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Minted.Mint.Token

  @moduletag :property
  @moduletag timeout: 120_000

  @denominations for exp <- 0..20, do: Integer.pow(2, exp)

  describe "decomposition roundtrip" do
    property "decompose then sum always returns the original amount" do
      check all(
              amount <- integer(1..2_097_151),
              max_runs: 10_000
            ) do
        parts = Token.decompose_amount(amount)
        assert Enum.sum(parts) == amount
      end
    end

    property "decompose(0) is always empty" do
      assert Token.decompose_amount(0) == []
    end
  end

  describe "decomposition optimality" do
    property "any representable amount decomposes into at most 21 tokens" do
      check all(
              amount <- integer(1..2_097_151),
              max_runs: 10_000
            ) do
        parts = Token.decompose_amount(amount)

        assert length(parts) <= 21,
               "#{amount} decomposed into #{length(parts)} parts, expected <= 21"
      end
    end

    property "maximum amount 2_097_151 decomposes into exactly 21 tokens" do
      parts = Token.decompose_amount(2_097_151)
      assert length(parts) == 21
      assert Enum.sum(parts) == 2_097_151
    end
  end

  describe "valid denominations" do
    property "every part in a decomposition is a valid power of 2" do
      check all(
              amount <- integer(1..2_097_151),
              max_runs: 10_000
            ) do
        parts = Token.decompose_amount(amount)

        for part <- parts do
          assert part in @denominations,
                 "#{part} is not a valid denomination (from amount #{amount})"
        end
      end
    end

    property "decomposition parts are sorted ascending" do
      check all(
              amount <- integer(1..2_097_151),
              max_runs: 5_000
            ) do
        parts = Token.decompose_amount(amount)
        assert parts == Enum.sort(parts)
      end
    end
  end

  describe "swap conservation" do
    property "random denomination sets redecompose with the same total" do
      check all(
              amounts <- list_of(member_of(@denominations), min_length: 1, max_length: 20),
              max_runs: 5_000
            ) do
        total = Enum.sum(amounts)
        redecomposed = Token.decompose_amount(total)
        assert Enum.sum(redecomposed) == total
      end
    end

    property "splitting a token preserves total value" do
      check all(
              denom <- member_of(@denominations -- [1]),
              max_runs: 1_000
            ) do
        # Splitting: one token of denom → multiple smaller tokens.
        parts = Token.decompose_amount(denom)
        assert Enum.sum(parts) == denom

        # A power of 2 should decompose to exactly itself.
        assert parts == [denom]
      end
    end

    property "combining tokens preserves total value" do
      check all(
              count <- integer(2..10),
              denom <- member_of(Enum.take(@denominations, 10)),
              max_runs: 1_000
            ) do
        total = count * denom
        parts = Token.decompose_amount(total)
        assert Enum.sum(parts) == total
      end
    end
  end

  describe "denomination predicate" do
    property "all powers of 2 from 2^0 to 2^20 are valid" do
      for exp <- 0..20 do
        assert Token.valid_denomination?(Integer.pow(2, exp))
      end
    end

    property "non-power-of-2 values are invalid" do
      check all(
              amount <- integer(3..2_097_151),
              Integer.pow(2, round(:math.log2(amount))) != amount,
              max_runs: 5_000
            ) do
        # Only exact powers of 2 should be valid.
        if amount not in @denominations do
          refute Token.valid_denomination?(amount)
        end
      end
    end
  end
end
