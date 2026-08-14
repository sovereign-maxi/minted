defmodule Minted.Telemetry.Publishers.Nostr.Nip44 do
  require Logger

  @moduledoc """
  NIP-44 v2 encryption — Nostr encrypted payloads.

  Implements the v2 payload format specified at
  https://github.com/nostr-protocol/nips/blob/master/44.md.

  Only encryption is implemented; the alert publisher is a one-way sender.

  ## Pipeline

      1. ECDH(sender_priv, recipient_pub) -> 32-byte shared secret (X coord)
      2. HKDF-Extract(salt="nip44-v2", ikm=shared) -> conversation_key
      3. random nonce (32 bytes)
      4. HKDF-Expand(conversation_key, info=nonce) -> 76 bytes
         split into chacha_key(32) || chacha_nonce(12) || hmac_key(32)
      5. Pad plaintext per NIP-44 padding scheme
      6. ChaCha20 encrypt padded plaintext
      7. HMAC-SHA256(hmac_key, aad=nonce, ciphertext) -> mac(32)
      8. Payload = base64(version(1) || nonce(32) || ciphertext || mac(32))

  ## Padding

  NIP-44 uses a length-prefixed bucket padding scheme to mask plaintext
  length. See `calc_padded_len/1` for the algorithm.
  """

  import Bitwise

  @version 2
  @salt "nip44-v2"
  @min_plaintext 1
  @max_plaintext 65_535

  # secp256k1 field prime — y² = x³ + 7 (mod p)
  @secp256k1_p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

  @type encrypt_error ::
          :plaintext_too_short
          | :plaintext_too_long
          | :invalid_privkey
          | :invalid_recipient
          | {:ecdh_failed, term()}

  # --- Public API ---

  @doc """
  Encrypts `plaintext` for `recipient_xonly` using `sender_priv`.

  Returns `{:ok, base64_payload}` or `{:error, reason}`.
  """
  @spec encrypt(String.t(), binary(), binary()) ::
          {:ok, String.t()} | {:error, encrypt_error()}
  def encrypt(plaintext, sender_priv, recipient_xonly)
      when is_binary(plaintext) and is_binary(sender_priv) and is_binary(recipient_xonly) do
    with :ok <- validate_plaintext(plaintext),
         :ok <- validate_keys(sender_priv, recipient_xonly),
         {:ok, shared_x} <- ecdh_shared_x(sender_priv, recipient_xonly) do
      conversation_key = hkdf_extract(@salt, shared_x)
      nonce = :crypto.strong_rand_bytes(32)
      {chacha_key, chacha_nonce, hmac_key} = derive_message_keys(conversation_key, nonce)
      padded = pad(plaintext)
      ciphertext = chacha20(chacha_key, chacha_nonce, padded)
      mac = hmac_sha256(hmac_key, nonce <> ciphertext)

      payload = <<@version::8>> <> nonce <> ciphertext <> mac
      {:ok, Base.encode64(payload)}
    end
  end

  # --- Validation ---

  defp validate_plaintext(plaintext) do
    size = byte_size(plaintext)

    cond do
      size < @min_plaintext -> {:error, :plaintext_too_short}
      size > @max_plaintext -> {:error, :plaintext_too_long}
      true -> :ok
    end
  end

  defp validate_keys(priv, recipient) do
    cond do
      byte_size(priv) != 32 -> {:error, :invalid_privkey}
      byte_size(recipient) != 32 -> {:error, :invalid_recipient}
      true -> :ok
    end
  end

  # --- ECDH ---

  @doc false
  def ecdh_shared_x(sender_priv, recipient_xonly) do
    x = :binary.decode_unsigned(recipient_xonly)

    case recover_even_y(x) do
      {:ok, y} ->
        uncompressed = <<0x04>> <> pad32(x) <> pad32(y)

        try do
          {:ok, :crypto.compute_key(:ecdh, uncompressed, sender_priv, :secp256k1)}
        rescue
          e ->
            Logger.error("Nip44: ECDH crashed", crash_reason: {e, __STACKTRACE__})
            {:error, :ecdh_failed}
        end

      :error ->
        {:error, :invalid_recipient}
    end
  end

  # Solve y² = x³ + 7 (mod p). Since p ≡ 3 (mod 4), sqrt = y²^((p+1)/4) mod p.
  # We always return the even Y to match BIP-340 x-only convention.
  defp recover_even_y(x) do
    p = @secp256k1_p
    y_sq = rem(mod_pow(x, 3, p) + 7, p)
    y = mod_pow(y_sq, div(p + 1, 4), p)

    if mod_pow(y, 2, p) == y_sq do
      even_y = if rem(y, 2) == 0, do: y, else: p - y
      {:ok, even_y}
    else
      :error
    end
  end

  defp mod_pow(base, exp, mod) do
    :crypto.mod_pow(base, exp, mod) |> :binary.decode_unsigned()
  end

  defp pad32(int) when is_integer(int) do
    bin = :binary.encode_unsigned(int)
    :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
  end

  # --- HKDF ---

  @doc false
  def hkdf_extract(salt, ikm), do: hmac_sha256(salt, ikm)

  @doc false
  # HKDF-Expand (RFC 5869) producing 76 bytes: 3 iterations of HMAC-SHA256.
  def hkdf_expand_76(prk, info) do
    t1 = hmac_sha256(prk, info <> <<1>>)
    t2 = hmac_sha256(prk, t1 <> info <> <<2>>)
    t3 = hmac_sha256(prk, t2 <> info <> <<3>>)
    binary_part(t1 <> t2 <> t3, 0, 76)
  end

  @doc false
  def derive_message_keys(conversation_key, nonce) do
    <<chacha_key::binary-32, chacha_nonce::binary-12, hmac_key::binary-32>> =
      hkdf_expand_76(conversation_key, nonce)

    {chacha_key, chacha_nonce, hmac_key}
  end

  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  # --- ChaCha20 ---

  # Erlang's :crypto.crypto_one_time(:chacha20, ...) expects a 16-byte IV
  # whose first 4 bytes are the 32-bit counter (little-endian) and whose
  # remaining 12 bytes are the nonce. NIP-44 starts from counter = 0.
  defp chacha20(key, nonce_12, data) do
    iv = <<0::little-32>> <> nonce_12
    :crypto.crypto_one_time(:chacha20, key, iv, data, true)
  end

  # --- Padding ---

  @doc false
  # NIP-44 padded plaintext format:
  #   [2 bytes big-endian: unpadded_len] [plaintext] [zero bytes to padded_len]
  # Total length = 2 + calc_padded_len(unpadded_len).
  def pad(plaintext) do
    unpadded = byte_size(plaintext)
    padded_len = calc_padded_len(unpadded)
    zeros = :binary.copy(<<0>>, padded_len - unpadded)
    <<unpadded::unsigned-big-16>> <> plaintext <> zeros
  end

  @doc false
  # NIP-44 padding scheme (bucket padding). See spec for derivation.
  @spec calc_padded_len(pos_integer()) :: pos_integer()
  def calc_padded_len(n) when n <= 32, do: 32

  def calc_padded_len(n) when is_integer(n) and n > 32 do
    next_power = 1 <<< (log2_floor(n - 1) + 1)
    chunk = if next_power <= 256, do: 32, else: div(next_power, 8)
    chunk * (div(n - 1, chunk) + 1)
  end

  # Integer floor-log2 using bit_size on the minimal binary representation.
  defp log2_floor(n) when is_integer(n) and n > 0 do
    bit_size(:binary.encode_unsigned(n)) - leading_zero_bits(n) - 1
  end

  defp leading_zero_bits(n) do
    bin = :binary.encode_unsigned(n)
    <<first, _::binary>> = bin
    7 - log2_byte(first)
  end

  defp log2_byte(b) when b >= 128, do: 7
  defp log2_byte(b) when b >= 64, do: 6
  defp log2_byte(b) when b >= 32, do: 5
  defp log2_byte(b) when b >= 16, do: 4
  defp log2_byte(b) when b >= 8, do: 3
  defp log2_byte(b) when b >= 4, do: 2
  defp log2_byte(b) when b >= 2, do: 1
  defp log2_byte(_), do: 0
end
