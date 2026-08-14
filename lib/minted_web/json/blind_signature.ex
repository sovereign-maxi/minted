defmodule MintedWeb.JSON.BlindSignature do
  @moduledoc """
  Cashu NUT-compatible JSON encoding/decoding for blind signatures.

  Format: `{"amount": int, "id": hex, "C_": hex_point}`
  """

  @doc """
  Encodes a blind signature response to Cashu JSON format.
  """
  def encode(%{amount: amount, keyset_id: keyset_id, c_prime: c_prime} = sig) do
    base = %{
      "amount" => amount,
      "id" => keyset_id,
      "C_" => Base.encode16(c_prime, case: :lower)
    }

    add_dleq(base, Map.get(sig, :dleq))
  end

  def encode(%Minted.Mint.Signatures.Response{} = sig) do
    base = %{
      "amount" => sig.amount,
      "id" => sig.keyset_id,
      "C_" => Base.encode16(sig.c_prime, case: :lower)
    }

    add_dleq(base, sig.dleq)
  end

  defp add_dleq(base, %{e: e, s: s}) when is_binary(e) and is_binary(s) do
    Map.put(base, "dleq", %{
      "e" => Base.encode16(e, case: :lower),
      "s" => Base.encode16(s, case: :lower)
    })
  end

  defp add_dleq(base, _), do: base
end
