defmodule Minted.Mint.Signatures.ResponseTest do
  @moduledoc "Unit tests for Minted.Mint.Signatures.Response."

  use ExUnit.Case, async: false

  alias Minted.Mint.Signatures.Response

  # A valid compressed SEC1 point (33 bytes, starts with 0x02 or 0x03)
  defp valid_c_prime(prefix \\ 0x02) do
    <<prefix, :crypto.strong_rand_bytes(32)::binary>>
  end

  defp valid_response(overrides \\ %{}) do
    defaults = %{
      amount: 1,
      c_prime: valid_c_prime(),
      keyset_id: "abc123def456"
    }

    struct!(Response, Map.merge(defaults, overrides))
  end

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Response, %{})
      end
    end

    test "can be created with all required fields" do
      resp = valid_response()
      assert resp.amount == 1
      assert is_binary(resp.c_prime)
      assert is_binary(resp.keyset_id)
      assert resp.dleq == nil
    end

    test "accepts optional dleq field" do
      dleq = %{e: :crypto.strong_rand_bytes(32), s: :crypto.strong_rand_bytes(32)}
      resp = valid_response(%{dleq: dleq})
      assert resp.dleq == dleq
    end
  end

  describe "valid?/1" do
    test "returns true for valid response with 0x02 prefix" do
      resp = valid_response(%{c_prime: valid_c_prime(0x02)})
      assert Response.valid?(resp)
    end

    test "returns true for valid response with 0x03 prefix" do
      resp = valid_response(%{c_prime: valid_c_prime(0x03)})
      assert Response.valid?(resp)
    end

    test "returns true for all valid denominations" do
      for exp <- 0..20 do
        denom = Integer.pow(2, exp)
        resp = valid_response(%{amount: denom})
        assert Response.valid?(resp), "expected valid for denomination #{denom}"
      end
    end

    test "returns false for non-power-of-2 amount" do
      resp = valid_response(%{amount: 3})
      refute Response.valid?(resp)
    end

    test "returns false for zero amount" do
      resp = valid_response(%{amount: 0})
      refute Response.valid?(resp)
    end

    test "returns false for negative amount" do
      resp = valid_response(%{amount: -1})
      refute Response.valid?(resp)
    end

    test "returns false for c_prime with wrong size (too short)" do
      resp = valid_response(%{c_prime: <<0x02, :crypto.strong_rand_bytes(16)::binary>>})
      refute Response.valid?(resp)
    end

    test "returns false for c_prime with wrong size (too long)" do
      resp = valid_response(%{c_prime: <<0x02, :crypto.strong_rand_bytes(64)::binary>>})
      refute Response.valid?(resp)
    end

    test "returns false for c_prime with invalid prefix 0x04" do
      resp = valid_response(%{c_prime: <<0x04, :crypto.strong_rand_bytes(32)::binary>>})
      refute Response.valid?(resp)
    end

    test "returns false for c_prime with invalid prefix 0x00" do
      resp = valid_response(%{c_prime: <<0x00, :crypto.strong_rand_bytes(32)::binary>>})
      refute Response.valid?(resp)
    end

    test "returns false for empty keyset_id" do
      resp = valid_response(%{keyset_id: ""})
      refute Response.valid?(resp)
    end

    test "returns false for nil keyset_id" do
      resp = %Response{amount: 1, c_prime: valid_c_prime(), keyset_id: nil}
      refute Response.valid?(resp)
    end

    test "returns false for non-struct input" do
      refute Response.valid?(%{amount: 1, c_prime: valid_c_prime(), keyset_id: "abc"})
    end

    test "returns false for nil input" do
      refute Response.valid?(nil)
    end

    test "returns false for string input" do
      refute Response.valid?("not a struct")
    end

    test "returns false for non-binary c_prime" do
      resp = %Response{amount: 1, c_prime: 12_345, keyset_id: "abc123"}
      refute Response.valid?(resp)
    end
  end
end
