defmodule Minted.Mint.Signatures.MessageTest do
  @moduledoc "Unit tests for Minted.Mint.Signatures.Message."

  use ExUnit.Case, async: true

  alias Minted.Mint.Signatures.{Message, Response}

  # Build a valid compressed SEC1 point (0x02 or 0x03 prefix + 32 bytes)
  defp valid_point, do: <<0x02, :crypto.strong_rand_bytes(32)::binary>>

  describe "Message.valid?/1" do
    test "valid with power-of-2 amount and 33-byte point" do
      msg = %Message{amount: 8, b_prime: valid_point()}
      assert Message.valid?(msg)
    end

    test "invalid with non-power-of-2 amount" do
      msg = %Message{amount: 3, b_prime: valid_point()}
      refute Message.valid?(msg)
    end

    test "invalid with wrong-size point" do
      msg = %Message{amount: 8, b_prime: :crypto.strong_rand_bytes(32)}
      refute Message.valid?(msg)
    end

    test "invalid with bad point prefix" do
      msg = %Message{amount: 8, b_prime: <<0x04, :crypto.strong_rand_bytes(32)::binary>>}
      refute Message.valid?(msg)
    end
  end

  describe "Response.valid?/1" do
    test "valid with all correct fields" do
      sig = %Response{
        amount: 16,
        c_prime: valid_point(),
        keyset_id: "abcdef01"
      }

      assert Response.valid?(sig)
    end

    test "invalid with empty keyset_id" do
      sig = %Response{
        amount: 16,
        c_prime: valid_point(),
        keyset_id: ""
      }

      refute Response.valid?(sig)
    end

    test "invalid with bad point prefix" do
      sig = %Response{
        amount: 16,
        c_prime: <<0x05, :crypto.strong_rand_bytes(32)::binary>>,
        keyset_id: "abcdef01"
      }

      refute Response.valid?(sig)
    end
  end
end
