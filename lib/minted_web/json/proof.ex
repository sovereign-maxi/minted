defmodule MintedWeb.JSON.Proof do
  @moduledoc """
  Cashu NUT-compatible JSON encoding/decoding for token proofs.

  Format: `{"amount": int, "id": hex, "secret": string, "C": hex_point}`
  """

  @secret_byte_length 32
  @c_byte_length 33

  @doc """
  Encodes a proof map or Token struct to Cashu JSON format.
  """
  def encode(%{amount: amount, secret: secret, c: c, keyset_id: id}) do
    %{
      "amount" => amount,
      "id" => id,
      "secret" => encode_binary(secret),
      "C" => encode_binary(c)
    }
  end

  @doc """
  Decodes a Cashu proof JSON map into a domain-friendly map.
  Returns `{:ok, map}` or `{:error, :invalid_proof}`.
  """
  def decode(%{"amount" => amount, "id" => id, "secret" => secret, "C" => c})
      when is_integer(amount) and amount > 0 and is_binary(id) and is_binary(secret) and is_binary(c) do
    with true <- Minted.Mint.Token.valid_denomination?(amount),
         {:ok, secret_bin} <- decode_and_validate(secret, @secret_byte_length),
         {:ok, c_bin} <- decode_and_validate(c, @c_byte_length) do
      {:ok,
       %{
         amount: amount,
         keyset_id: id,
         secret: secret_bin,
         c: c_bin
       }}
    else
      false -> {:error, :invalid_denomination}
      error -> error
    end
  end

  def decode(_), do: {:error, :invalid_proof}

  defp encode_binary(bin) when is_binary(bin) do
    Base.encode16(bin, case: :lower)
  end

  defp decode_and_validate(hex, expected_len) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == expected_len -> {:ok, bin}
      {:ok, _} -> {:error, :invalid_byte_length}
      :error -> {:error, :invalid_hex}
    end
  end
end
