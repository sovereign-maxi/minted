defmodule Minted.Mint.Signatures.BlindTest do
  @moduledoc "Unit tests for Minted.Mint.Signatures.Blind."

  use ExUnit.Case, async: true

  alias Minted.Mint.Signatures.Blind
  alias Minted.Mint.Signatures.Blind.BlindedMessage
  # Nested structs inside Blind module
  alias Minted.Mint.Signatures.Blind.KeyPair
  alias Minted.Mint.Signatures.Blind.Proof

  describe "generate_keypair/0" do
    test "returns a KeyPair struct" do
      {:ok, %KeyPair{} = keypair} = Blind.generate_keypair()
      assert byte_size(keypair.private_key) == 32
      assert byte_size(keypair.public_key) == 33
    end
  end

  describe "pubkey_from_privkey/1" do
    test "derives correct public key" do
      {:ok, %KeyPair{} = keypair} = Blind.generate_keypair()
      {:ok, pubkey} = Blind.pubkey_from_privkey(keypair.private_key)
      assert pubkey == keypair.public_key
    end

    test "rejects invalid key" do
      assert {:error, _} = Blind.pubkey_from_privkey(<<0::8*32>>)
    end
  end

  describe "hash_to_curve/1" do
    test "returns a 33-byte compressed point" do
      {:ok, point} = Blind.hash_to_curve("test secret")
      assert byte_size(point) == 33
    end

    test "is deterministic" do
      {:ok, p1} = Blind.hash_to_curve("same")
      {:ok, p2} = Blind.hash_to_curve("same")
      assert p1 == p2
    end
  end

  describe "blind/2" do
    test "returns a BlindedMessage struct" do
      {:ok, %BlindedMessage{} = msg} = Blind.blind("my secret")
      assert byte_size(msg.b_prime) == 33
      assert byte_size(msg.blinding_factor) == 32
      assert msg.secret == "my secret"
    end

    test "accepts optional blinding factor" do
      {:ok, %KeyPair{private_key: r}} = Blind.generate_keypair()
      {:ok, %BlindedMessage{} = msg} = Blind.blind("my secret", r)
      assert msg.blinding_factor == r
    end
  end

  describe "sign/2" do
    test "signs a blinded message with a KeyPair" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, blinded} = Blind.blind("secret")

      {:ok, %Blind.BlindSignature{} = sig} =
        Blind.sign(blinded, keypair)

      assert byte_size(sig.c_prime) == 33
    end

    test "signs a blinded message with a raw private key" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, blinded} = Blind.blind("secret")

      {:ok, %Blind.BlindSignature{} = sig} =
        Blind.sign(blinded, keypair.private_key)

      assert byte_size(sig.c_prime) == 33
    end
  end

  describe "unblind/3" do
    test "unblinds signature to produce a Proof" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, blinded} = Blind.blind("secret")
      {:ok, blind_sig} = Blind.sign(blinded, keypair)

      {:ok, %Proof{} = proof} =
        Blind.unblind(blind_sig, blinded, keypair.public_key)

      assert proof.secret == "secret"
      assert byte_size(proof.c) == 33
    end
  end

  describe "verify/2" do
    test "valid roundtrip verifies with KeyPair" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, proof} = Blind.blind_sign_unblind("secret", keypair)
      assert :ok = Blind.verify(proof, keypair)
    end

    test "valid roundtrip verifies with raw private key" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, proof} = Blind.blind_sign_unblind("secret", keypair)
      assert :ok = Blind.verify(proof, keypair.private_key)
    end

    test "wrong key fails verification" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, other_keypair} = Blind.generate_keypair()
      {:ok, proof} = Blind.blind_sign_unblind("secret", keypair)
      assert {:error, :invalid_signature} = Blind.verify(proof, other_keypair)
    end

    test "tampered signature fails verification" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, %Proof{} = proof} = Blind.blind_sign_unblind("secret", keypair)
      tampered = %Proof{proof | secret: "different_secret"}
      assert {:error, :invalid_signature} = Blind.verify(tampered, keypair)
    end
  end

  describe "blind_sign_unblind/2" do
    test "complete roundtrip succeeds" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, %Proof{} = proof} = Blind.blind_sign_unblind("hello world", keypair)
      assert proof.secret == "hello world"
      assert byte_size(proof.c) == 33
      assert :ok = Blind.verify(proof, keypair)
    end

    test "works with binary secrets" do
      {:ok, keypair} = Blind.generate_keypair()
      binary_secret = :crypto.strong_rand_bytes(32)
      {:ok, proof} = Blind.blind_sign_unblind(binary_secret, keypair)
      assert :ok = Blind.verify(proof, keypair)
    end

    test "works with empty secret" do
      {:ok, keypair} = Blind.generate_keypair()
      {:ok, proof} = Blind.blind_sign_unblind("", keypair)
      assert :ok = Blind.verify(proof, keypair)
    end
  end
end
