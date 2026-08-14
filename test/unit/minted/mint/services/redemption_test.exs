defmodule Minted.Mint.Services.RedemptionTest do
  @moduledoc "Unit tests for Redemption.verify_batch/2 edge cases."

  use ExUnit.Case, async: true

  alias Minted.Mint.{Keyset, Token}
  alias Minted.Mint.Services.Redemption

  describe "verify_batch/2" do
    test "returns keyset mismatch for token with wrong keyset_id" do
      keyset = Keyset.generate()
      expected_id = keyset.id

      token = %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: "wrong_keyset_id"
      }

      assert {:error, {:keyset_mismatch, [index: 0, expected: ^expected_id]}} =
               Redemption.verify_batch([token], keyset)
    end

    test "returns keyset mismatch with correct index for second mismatched token" do
      keyset = Keyset.generate()
      expected_id = keyset.id

      good_token = %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: keyset.id
      }

      bad_token = %Token{
        amount: 2,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: "other_keyset"
      }

      assert {:error, {:keyset_mismatch, [index: 1, expected: ^expected_id]}} =
               Redemption.verify_batch([good_token, bad_token], keyset)
    end

    test "returns error for invalid denomination" do
      keyset = Keyset.generate()

      token = %Token{
        amount: 3,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: keyset.id
      }

      assert {:error, {:denomination_not_found, index: 0}} =
               Redemption.verify_batch([token], keyset)
    end

    test "returns error for invalid signature" do
      keyset = Keyset.generate()

      token = %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: keyset.id
      }

      assert {:error, {:invalid_signature, index: 0}} =
               Redemption.verify_batch([token], keyset)
    end
  end
end
