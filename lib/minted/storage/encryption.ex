defmodule Minted.Storage.Encryption do
  @moduledoc """
  AES-256-GCM helpers for at-rest encryption of every secret the
  application persists: keyset private keys, the Reserves Nostr
  signing key, the Vault.Generator guardian key, and any future
  at-rest material routed through `Storage.Facade.encrypt/decrypt`.

  The master key derives from `MINTED_ENCRYPTION_KEY` via
  HMAC-SHA256. Operators provide the env var via the Ansible-rendered
  environment file; the runtime refuses to boot in production
  without it.

  ## Configuration

      config :minted, :encryption_key, "base64-encoded-32-byte-key"
  """

  alias Minted.Events.EventBus
  alias Minted.Events.Storage.LegacyKeyDecryptFallback

  @legacy_aad "minted-keyset-v1"
  @aad_v2 "minted-keyset-v2"

  @doc """
  Encrypts private key material for storage.

  `aad` is the additional-authenticated-data label. Pass a string
  describing the record's purpose (e.g. `"keyset:abc123"`) so an
  attacker who swaps two ciphertexts on disk gets a tag mismatch on
  decrypt. Defaults to a global v2 constant for callers that haven't
  been threaded with per-record context yet.
  """
  @spec encrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, aad \\ @aad_v2) when is_binary(plaintext) and is_binary(aad) do
    key = get_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        aad,
        true
      )

    {:ok, iv <> tag <> ciphertext}
  end

  @doc """
  Decrypts private key material. Tries the current HKDF-derived key
  first (with `aad` then the legacy AAD), then falls back to the
  pre-HKDF raw-passthrough derivation for blobs written under the
  older scheme. When the passthrough path wins, publishes a
  `Storage.LegacyKeyDecryptFallback` event so operators see the
  fallback in the event stream and know to re-encrypt.
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(encrypted, aad \\ @aad_v2)

  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, aad) when is_binary(aad) do
    hkdf = get_key()

    with {:error, :decryption_failed} <- try_decrypt(hkdf, iv, tag, ciphertext, aad),
         {:error, :decryption_failed} <- try_decrypt(hkdf, iv, tag, ciphertext, @legacy_aad),
         legacy when is_binary(legacy) <- get_legacy_key(),
         {:error, :decryption_failed} <- try_legacy(legacy, iv, tag, ciphertext, aad),
         {:error, :decryption_failed} = err <- try_legacy(legacy, iv, tag, ciphertext, @legacy_aad) do
      err
    else
      {:ok, _} = ok -> ok
      nil -> {:error, :decryption_failed}
    end
  end

  def decrypt(_, _), do: {:error, :invalid_encrypted_data}

  defp try_decrypt(key, iv, tag, ciphertext, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  # Legacy path — the pre-HKDF raw-passthrough derivation. Wins only
  # when the on-disk blob was written under the older scheme.
  # Announces via an event so the stream carries the signal.
  defp try_legacy(key, iv, tag, ciphertext, aad) do
    case try_decrypt(key, iv, tag, ciphertext, aad) do
      {:ok, _} = ok ->
        _ =
          EventBus.publish(%LegacyKeyDecryptFallback{
            aad: aad,
            timestamp: DateTime.utc_now()
          })

        ok

      other ->
        other
    end
  end

  @doc "Encrypts an Erlang term."
  @spec encrypt_term(term(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt_term(term, aad \\ @aad_v2), do: encrypt(:erlang.term_to_binary(term), aad)

  @doc "Decrypts and deserialises an Erlang term."
  @spec decrypt_term(binary(), binary()) :: {:ok, term()} | {:error, term()}
  def decrypt_term(encrypted, aad \\ @aad_v2) do
    case decrypt(encrypted, aad) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin, [:safe])}
      error -> error
    end
  end

  # Fixed salt is intentional — backup restore across hosts must
  # derive the same key from the same root. Per-message uniqueness
  # comes from the random IV in encrypt/2.
  @hkdf_salt "minted-encryption-salt-v1"
  @hkdf_info "minted-encryption-key-v1"

  @doc false
  def get_key do
    case Application.get_env(:minted, :encryption_key) do
      nil ->
        if Application.get_env(:minted, :env) == :prod do
          raise "MINTED_ENCRYPTION_KEY must be set in production"
        end

        # Default key for dev/test only — never use in production.
        # HKDF here keeps the derivation path consistent with prod.
        hkdf_derive("minted-dev-key-do-not-use-in-production")

      key when is_binary(key) ->
        # Always HKDF-derive, regardless of input length. The
        # previous 32-byte-passthrough path treated a 32-char ASCII
        # env value (~150 bits of entropy) as if it were 256 bits
        # of random AES key material — an operator who set
        # MINTED_ENCRYPTION_KEY to a 32-char password (docs said
        # base64 but nothing rejected raw ASCII) got dramatically
        # weaker encryption than intended. HKDF normalises: raw or
        # base64 or hex, the resulting key derives through the
        # same extract-and-expand pipeline.
        hkdf_derive(key)
    end
  end

  # M10: HKDF-SHA256 key derivation replacing raw SHA-256 hash.
  # HKDF provides proper extract-and-expand with domain separation via
  # salt and info parameters, preventing related-key attacks.
  defp hkdf_derive(ikm) do
    # Extract: PRK = HMAC-SHA256(salt, ikm)
    prk = :crypto.mac(:hmac, :sha256, @hkdf_salt, ikm)
    # Expand: OKM = HMAC-SHA256(PRK, info || 0x01) — single block is enough for 32 bytes
    :crypto.mac(:hmac, :sha256, prk, @hkdf_info <> <<1>>)
  end

  # Pre-HKDF derivation: raw 32-byte env value used as AES key
  # verbatim. Returns nil for env values that never matched that
  # path (dev default, non-32-byte input), so the fallback chain
  # skips to a clean :decryption_failed instead of a bogus attempt.
  defp get_legacy_key do
    case Application.get_env(:minted, :encryption_key) do
      key when is_binary(key) and byte_size(key) == 32 -> key
      _ -> nil
    end
  end
end
