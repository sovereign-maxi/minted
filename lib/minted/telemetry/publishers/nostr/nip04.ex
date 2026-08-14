defmodule Minted.Telemetry.Publishers.Nostr.Nip04 do
  @moduledoc """
  NIP-04 encrypted direct messages (legacy).

  Uses ECDH shared secret + AES-256-CBC. Less private than NIP-17
  gift wraps but supported by all Nostr clients.

  The shared secret is `SHA256(ECDH(sender_privkey, recipient_pubkey))`.
  Content format: `Base64(ciphertext)?iv=Base64(iv)`
  """

  @doc """
  Encrypts plaintext for a recipient using NIP-04.

  - `sender_privkey` — 32-byte sender private key
  - `recipient_pubkey` — 32-byte recipient x-only public key
  - `plaintext` — the message to encrypt

  Returns `{:ok, "base64_ciphertext?iv=base64_iv"}` or `{:error, reason}`.
  """
  @spec encrypt(binary(), binary(), binary()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(plaintext, sender_privkey, recipient_pubkey)
      when is_binary(plaintext) and byte_size(sender_privkey) == 32 and
             byte_size(recipient_pubkey) == 32 do
    # Derive shared secret via ECDH
    # NIP-04: shared_secret = SHA256(ECDH_point_x)
    with {:ok, shared_point_x} <- ecdh(sender_privkey, recipient_pubkey) do
      shared_secret = :crypto.hash(:sha256, shared_point_x)
      iv = :crypto.strong_rand_bytes(16)

      # PKCS7 padding is handled by crypto_one_time with encrypt=true
      ciphertext =
        :crypto.crypto_one_time(:aes_256_cbc, shared_secret, iv, plaintext, [
          {:encrypt, true},
          {:padding, :pkcs_padding}
        ])

      encoded = Base.encode64(ciphertext) <> "?iv=" <> Base.encode64(iv)
      {:ok, encoded}
    end
  rescue
    e -> {:error, {:nip04_encrypt_failed, Exception.message(e)}}
  end

  # ECDH using secp256k1 — compute shared point from privkey and pubkey.
  # The recipient pubkey is x-only (32 bytes), so we prefix with 0x02
  # (even y) to make a compressed pubkey for the EC operation.
  defp ecdh(privkey, xonly_pubkey) do
    compressed_pubkey = <<0x02>> <> xonly_pubkey

    try do
      # Erlang returns the 32-byte x-coordinate for secp256k1 ECDH
      shared = :crypto.compute_key(:ecdh, compressed_pubkey, privkey, :secp256k1)
      {:ok, shared}
    rescue
      e -> {:error, {:ecdh_failed, Exception.message(e)}}
    end
  end
end
