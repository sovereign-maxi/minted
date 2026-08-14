defmodule MintedWeb.JSON.BlindedMessage do
  @moduledoc """
  Cashu NUT-compatible JSON encoding/decoding for blinded messages.

  Format: `{"amount": int, "id": hex, "B_": hex_point}`
  """

  @b_prime_byte_length 33

  @doc """
  Encodes a blinded message to Cashu JSON format.
  """
  def encode(%{amount: amount, keyset_id: id, b_prime: b_prime}) do
    %{
      "amount" => amount,
      "id" => id,
      "B_" => Base.encode16(b_prime, case: :lower)
    }
  end

  @doc """
  Decodes a Cashu blinded message JSON map.
  Returns `{:ok, map}` or `{:error, :invalid_blinded_message}`.
  """
  def decode(%{"amount" => amount, "id" => id, "B_" => b_prime_hex})
      when is_integer(amount) and amount > 0 and is_binary(id) and is_binary(b_prime_hex) do
    if Minted.Mint.Token.valid_denomination?(amount) do
      case Base.decode16(b_prime_hex, case: :mixed) do
        {:ok, b_prime} when byte_size(b_prime) == @b_prime_byte_length ->
          {:ok, %{amount: amount, keyset_id: id, b_prime: b_prime}}

        {:ok, _} ->
          {:error, :invalid_blinded_message}

        :error ->
          {:error, :invalid_blinded_message}
      end
    else
      {:error, :invalid_blinded_message}
    end
  end

  def decode(_), do: {:error, :invalid_blinded_message}
end
