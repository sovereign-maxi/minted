defmodule MintedWeb.JSON.SerializationTest do
  @moduledoc "Unit tests for MintedWeb.JSON serialization modules."

  use ExUnit.Case, async: true

  alias MintedWeb.JSON.{BlindedMessage, BlindSignature, Proof}

  describe "Proof encoding/decoding" do
    test "round-trips a proof with binary secret" do
      secret = :crypto.strong_rand_bytes(32)
      c = :crypto.strong_rand_bytes(33)

      proof = %{amount: 8, secret: secret, c: c, keyset_id: "abcdef01"}
      encoded = Proof.encode(proof)

      assert encoded["amount"] == 8
      assert encoded["id"] == "abcdef01"
      assert is_binary(encoded["C"])
      assert is_binary(encoded["secret"])

      assert {:ok, decoded} = Proof.decode(encoded)
      assert decoded.amount == 8
      assert decoded.keyset_id == "abcdef01"
      assert decoded.secret == secret
      assert decoded.c == c
    end

    test "round-trips a proof with 32-byte secret" do
      secret = :crypto.strong_rand_bytes(32)
      c = :crypto.strong_rand_bytes(33)

      proof = %{amount: 4, secret: secret, c: c, keyset_id: "abcdef01"}
      encoded = Proof.encode(proof)

      assert {:ok, decoded} = Proof.decode(encoded)
      assert decoded.secret == secret
      assert decoded.c == c
    end

    test "rejects invalid proof" do
      assert {:error, :invalid_proof} = Proof.decode(%{})
      assert {:error, :invalid_proof} = Proof.decode(%{"amount" => "not_int"})
    end

    test "rejects non-hex secret" do
      c = :crypto.strong_rand_bytes(33) |> Base.encode16(case: :lower)

      proof = %{
        "amount" => 4,
        "id" => "abcdef01",
        "secret" => "not-valid-hex!",
        "C" => c
      }

      assert {:error, :invalid_hex} = Proof.decode(proof)
    end
  end

  describe "BlindedMessage encoding/decoding" do
    test "round-trips a blinded message" do
      b_prime = :crypto.strong_rand_bytes(33)
      msg = %{amount: 16, keyset_id: "abcdef01", b_prime: b_prime}

      encoded = BlindedMessage.encode(msg)
      assert encoded["amount"] == 16
      assert encoded["id"] == "abcdef01"
      assert is_binary(encoded["B_"])

      assert {:ok, decoded} = BlindedMessage.decode(encoded)
      assert decoded.amount == 16
      assert decoded.keyset_id == "abcdef01"
      assert decoded.b_prime == b_prime
    end

    test "rejects invalid blinded message" do
      assert {:error, :invalid_blinded_message} = BlindedMessage.decode(%{})
    end
  end

  describe "BlindSignature encoding" do
    test "encodes a blind signature response" do
      c_prime = :crypto.strong_rand_bytes(33)

      sig = %Minted.Mint.Signatures.Response{
        amount: 32,
        keyset_id: "abcdef01",
        c_prime: c_prime
      }

      encoded = BlindSignature.encode(sig)
      assert encoded["amount"] == 32
      assert encoded["id"] == "abcdef01"
      assert encoded["C_"] == Base.encode16(c_prime, case: :lower)
    end

    test "encodes a map-based signature" do
      c_prime = :crypto.strong_rand_bytes(33)

      encoded =
        BlindSignature.encode(%{amount: 64, keyset_id: "abcdef01", c_prime: c_prime})

      assert encoded["amount"] == 64
      assert encoded["id"] == "abcdef01"
    end
  end
end
