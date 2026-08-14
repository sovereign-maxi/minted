defmodule Minted.Mint.Token do
  @moduledoc """
  Core eCash token value object with Cashu-standard serialization.

  Each token encodes an amount (power-of-2 sats), a secret, a signature
  point (C), and a keyset ID. Supports cashuA serialization format.

  Internally, `secret` and `c` are stored as raw binaries (byte strings).
  In JSON/serialization they are hex-encoded (lowercase) via
  `Base.encode16/2`. `cashuA` format uses `Base.url_encode64/2` wrapping
  JSON with hex-encoded fields.
  """

  import Bitwise

  @enforce_keys [:amount, :secret, :c, :keyset_id]
  defstruct [:amount, :secret, :c, :keyset_id]

  @type t :: %__MODULE__{
          amount: pos_integer(),
          secret: binary(),
          c: binary(),
          keyset_id: String.t()
        }

  @valid_denominations for exp <- 0..20, do: Integer.pow(2, exp)

  @spec valid_denomination?(integer()) :: boolean()
  def valid_denomination?(amount) when amount in @valid_denominations, do: true
  def valid_denomination?(_amount), do: false

  @spec decompose_amount(non_neg_integer()) :: [pos_integer()]
  def decompose_amount(amount) when is_integer(amount) and amount <= 0, do: []

  def decompose_amount(amount) when is_integer(amount) and amount > 0 do
    amount
    |> decompose_bits(1, [])
    |> Enum.sort()
  end

  defp decompose_bits(0, _bit, acc), do: acc

  defp decompose_bits(amount, bit, acc) do
    if (amount &&& 1) == 1 do
      decompose_bits(amount >>> 1, bit * 2, [bit | acc])
    else
      decompose_bits(amount >>> 1, bit * 2, acc)
    end
  end

  @spec serialize([t()]) :: {:ok, String.t()} | {:error, term()}
  def serialize(tokens) when is_list(tokens) do
    proofs =
      Enum.map(tokens, fn %__MODULE__{} = token ->
        %{
          "amount" => token.amount,
          "secret" => Base.encode16(token.secret, case: :lower),
          "C" => Base.encode16(token.c, case: :lower),
          "id" => token.keyset_id
        }
      end)

    payload = %{"token" => [%{"proofs" => proofs}]}

    case Jason.encode(payload) do
      {:ok, json} -> {:ok, "cashuA" <> Base.url_encode64(json, padding: false)}
      {:error, _} = err -> err
    end
  end

  # 10 MB base64 ≈ ~7.5 MB decoded JSON ≈ ~50k tokens at worst
  @max_encoded_bytes 10_000_000
  @max_tokens_per_backup 10_000

  @spec deserialize(String.t()) :: {:ok, [t()]} | {:error, term()}
  def deserialize("cashuA" <> encoded) when byte_size(encoded) <= @max_encoded_bytes do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"token" => entries}} when is_list(entries) <- Jason.decode(json) do
      extract_proofs(entries)
    else
      :error -> {:error, :invalid_encoding}
      {:ok, _} -> {:error, :invalid_format}
      {:error, _} = err -> err
    end
  end

  def deserialize("cashuA" <> _), do: {:error, :backup_too_large}
  def deserialize(_), do: {:error, :invalid_format}

  defp extract_proofs(entries) do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn
        %{"proofs" => proofs}, {:ok, acc} when is_list(proofs) ->
          case decode_proofs(proofs, acc) do
            {:ok, tokens} when length(tokens) > @max_tokens_per_backup ->
              {:halt, {:error, :too_many_tokens}}

            {:ok, _} = ok ->
              {:cont, ok}

            {:error, _} = err ->
              {:halt, err}
          end

        _, _acc ->
          {:halt, {:error, :invalid_proof_encoding}}
      end)

    case result do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      {:error, _} = err -> err
    end
  end

  @secret_byte_length 32
  @c_byte_length 33

  defp decode_proofs(proofs, acc) do
    Enum.reduce_while(proofs, {:ok, acc}, fn proof, {:ok, tokens} ->
      if length(tokens) >= @max_tokens_per_backup do
        {:halt, {:error, :too_many_tokens}}
      else
        with {:ok, amount} <- validate_amount(proof["amount"]),
             {:ok, secret} <- decode_and_validate_hex(proof["secret"], @secret_byte_length),
             {:ok, c} <- decode_and_validate_hex(proof["C"], @c_byte_length),
             {:ok, keyset_id} <- validate_keyset_id(proof["id"]) do
          token = %__MODULE__{
            amount: amount,
            secret: secret,
            c: c,
            keyset_id: keyset_id
          }

          {:cont, {:ok, [token | tokens]}}
        else
          _ -> {:halt, {:error, :invalid_proof_encoding}}
        end
      end
    end)
  end

  # M2: Validate amount is a positive integer and valid power-of-2 denomination.
  defp validate_amount(amount)
       when is_integer(amount) and amount > 0 and amount in @valid_denominations,
       do: {:ok, amount}

  defp validate_amount(_), do: {:error, :invalid_amount}

  # M3: Decode hex and validate byte length.
  defp decode_and_validate_hex(hex, expected_len) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == expected_len -> {:ok, bytes}
      {:ok, _} -> {:error, :invalid_byte_length}
      :error -> {:error, :invalid_hex}
    end
  end

  defp decode_and_validate_hex(_, _), do: {:error, :invalid_hex}

  # Cashu keyset IDs are hex-encoded (NUT-02): 1–16 lowercase hex characters.
  @max_keyset_id_bytes 16
  defp validate_keyset_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_keyset_id_bytes do
    if String.match?(id, ~r/\A[0-9a-fA-F]+\z/) and id == String.downcase(id) do
      {:ok, id}
    else
      {:error, :invalid_keyset_id}
    end
  end

  defp validate_keyset_id(_), do: {:error, :invalid_keyset_id}
end
