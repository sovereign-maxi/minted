defmodule Minted.Storage.EncryptionTest do
  @moduledoc "Unit tests for Minted.Storage.Encryption."

  use ExUnit.Case, async: true

  alias Minted.Events.EventBus
  alias Minted.Events.Storage.LegacyKeyDecryptFallback
  alias Minted.Storage.Encryption

  describe "encrypt/1 and decrypt/1" do
    test "round-trips binary data" do
      plaintext = "hello world, this is private key material"
      {:ok, encrypted} = Encryption.encrypt(plaintext)

      assert encrypted != plaintext
      assert byte_size(encrypted) > byte_size(plaintext)

      {:ok, decrypted} = Encryption.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "different encryptions of same plaintext produce different ciphertext" do
      plaintext = "same data"
      {:ok, enc1} = Encryption.encrypt(plaintext)
      {:ok, enc2} = Encryption.encrypt(plaintext)

      # Due to random IV, ciphertexts should differ.
      assert enc1 != enc2
    end

    test "decrypting corrupted data returns error" do
      {:ok, encrypted} = Encryption.encrypt("test")
      # Corrupt the ciphertext by flipping bits.
      corrupted = :binary.copy(encrypted, 1)
      <<a, rest::binary>> = corrupted
      corrupted = <<Bitwise.bxor(a, 0xFF), rest::binary>>

      assert {:error, _} = Encryption.decrypt(corrupted)
    end

    test "decrypting invalid data returns error" do
      assert {:error, :invalid_encrypted_data} = Encryption.decrypt("too_short")
    end
  end

  describe "encrypt_term/1 and decrypt_term/1" do
    test "round-trips Elixir terms" do
      term = %{
        denomination: 1,
        private_key: :crypto.strong_rand_bytes(32),
        public_key: :crypto.strong_rand_bytes(33)
      }

      {:ok, encrypted} = Encryption.encrypt_term(term)
      {:ok, decrypted} = Encryption.decrypt_term(encrypted)

      assert decrypted == term
    end

    test "round-trips complex nested terms" do
      term = %{
        keys: %{
          1 => :crypto.strong_rand_bytes(32),
          2 => :crypto.strong_rand_bytes(32),
          4 => :crypto.strong_rand_bytes(32)
        },
        metadata: [created_at: 12_345, version: 1]
      }

      {:ok, encrypted} = Encryption.encrypt_term(term)
      {:ok, decrypted} = Encryption.decrypt_term(encrypted)

      assert decrypted == term
    end
  end

  # Blobs written under the pre-HKDF raw-passthrough derivation must
  # keep decrypting after the HKDF cutover — otherwise every on-disk
  # secret (Nostr signing key, keyset private keys, Vault guardian
  # key) becomes unreadable and the node refuses to boot.
  describe "legacy-passthrough decrypt fallback" do
    setup do
      original = Application.get_env(:minted, :encryption_key)
      # 32-byte key — the shape the old passthrough path required.
      raw_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:minted, :encryption_key, raw_key)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:minted, :encryption_key)
        else
          Application.put_env(:minted, :encryption_key, original)
        end
      end)

      {:ok, raw_key: raw_key}
    end

    test "decrypts a blob encrypted with the raw-passthrough scheme", %{raw_key: raw_key} do
      plaintext = "nostr-signing-key-material"
      encrypted = encrypt_with_raw_key(plaintext, raw_key, "minted-keyset-v2")

      assert {:ok, ^plaintext} = Encryption.decrypt(encrypted)
    end

    test "decrypts a blob written under the legacy AAD too", %{raw_key: raw_key} do
      plaintext = "older-blob"
      encrypted = encrypt_with_raw_key(plaintext, raw_key, "minted-keyset-v1")

      assert {:ok, ^plaintext} = Encryption.decrypt(encrypted)
    end

    test "publishes LegacyKeyDecryptFallback event when fallback wins", %{raw_key: raw_key} do
      :ok = EventBus.subscribe(LegacyKeyDecryptFallback)
      encrypted = encrypt_with_raw_key("payload", raw_key, "minted-keyset-v2")

      {:ok, _} = Encryption.decrypt(encrypted)

      assert_receive %LegacyKeyDecryptFallback{aad: "minted-keyset-v2"}, 500
    end

    test "current HKDF path does NOT publish the fallback event" do
      :ok = EventBus.subscribe(LegacyKeyDecryptFallback)
      {:ok, encrypted} = Encryption.encrypt("modern-blob")

      {:ok, _} = Encryption.decrypt(encrypted)

      refute_receive %LegacyKeyDecryptFallback{}, 100
    end
  end

  # Simulates the pre-HKDF encrypt path: raw 32-byte env value used
  # verbatim as the AES key. Matches the ciphertext layout the
  # current decrypt/2 expects (iv || tag || ciphertext).
  defp encrypt_with_raw_key(plaintext, raw_key, aad) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, raw_key, iv, plaintext, aad, true)

    iv <> tag <> ciphertext
  end
end
