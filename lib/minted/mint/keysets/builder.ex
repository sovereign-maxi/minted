defmodule Minted.Mint.Keysets.Builder do
  @moduledoc """
  Assembles Cashu keysets from pre-generated key material.

  Keys are auto-generated at first boot via `Keyset.generate/0` or
  loaded from a JSON file. This module provides the assembly and
  keyset-ID derivation logic.
  """

  alias Minted.Mint.Keyset

  @doc """
  Assembles a keyset from a pre-built keys map.

  Accepts `%{denom => {share, pubkey}}` where `share` is a 32-byte
  secret scalar and `pubkey` is a 33-byte compressed EC point.
  """
  @spec assemble_from_keys(map()) :: Keyset.t()
  def assemble_from_keys(keys) when is_map(keys) do
    id = derive_id(keys)

    %Keyset{
      id: id,
      unit: "sat",
      keys: keys,
      status: :active,
      created_at: DateTime.utc_now()
    }
  end

  # NUT-02: keyset_id = "00" || hex(SHA256(sorted_pubkeys)[0..14]),
  # 16 lowercase hex characters with leading version byte.
  defp derive_id(keys) do
    body =
      keys
      |> Enum.sort_by(fn {denom, _} -> denom end)
      |> Enum.map(fn {_denom, {_share, pubkey}} -> pubkey end)
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 7)
      |> Base.encode16(case: :lower)

    "00" <> body
  end
end
