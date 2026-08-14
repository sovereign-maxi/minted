defmodule MintedWeb.InfoController do
  @moduledoc """
  Read-only endpoints for mint info and keyset discovery.

  Cashu NUT-01 (keysets), NUT-02 (keyset IDs), NUT-06 (mint info).
  """

  use MintedWeb, :controller

  alias Minted.Mint.Keyset
  alias Minted.Reserves.Facade, as: ReservesFacade
  alias Minted.Storage.Facade, as: StorageFacade

  action_fallback MintedWeb.FallbackController

  @version "Minted/0.1.0"

  @doc """
  GET /v1/info
  Returns mint metadata per NUT-06.
  """
  def info(conn, _params) do
    keysets = StorageFacade.get_active_keyset()
    pubkey = extract_mint_pubkey(keysets)

    nostr = %{
      publisher_pubkey: hex_or_nil(ReservesFacade.nostr_pubkey()),
      publisher_curve: "secp256k1-bip340",
      guardian_pubkey: hex_or_nil(ReservesFacade.guardian_pubkey()),
      guardian_curve: "ed25519",
      kind: 30_078,
      threshold_signature_input: "Vault.Proof.canonical_bytes/1"
    }

    conn
    |> put_status(200)
    |> json(%{
      name: "Minted",
      pubkey: pubkey,
      version: @version,
      nuts: supported_nuts(),
      nostr: nostr,
      contact: []
    })
  end

  defp hex_or_nil({:ok, hex}), do: hex
  defp hex_or_nil({:error, _}), do: nil

  @doc """
  GET /v1/keysets
  Lists all keysets with status.
  """
  def keysets(conn, _params) do
    all_keysets = StorageFacade.list_keysets()

    keyset_list =
      Enum.map(all_keysets, fn ks ->
        %{
          id: extract_id(ks),
          unit: extract_unit(ks),
          active: extract_active(ks)
        }
      end)

    conn
    |> put_status(200)
    |> json(%{keysets: keyset_list})
  end

  @doc """
  GET /v1/keysets/:id
  Returns the full public key set for a specific keyset.
  """
  def keyset(conn, %{"id" => id}) do
    case StorageFacade.get_keyset(id) do
      {:ok, ks} ->
        keys = format_keyset_keys(ks)

        conn
        |> put_status(200)
        |> json(%{keysets: [%{id: id, unit: extract_unit(ks), keys: keys}]})

      :not_found ->
        {:error, :keyset_not_found}
    end
  end

  # --- Private Helpers ---

  defp supported_nuts do
    %{
      "4" => %{methods: [%{method: "bolt11", unit: "sat"}], disabled: false},
      "5" => %{methods: [%{method: "bolt11", unit: "sat"}], disabled: false},
      "7" => %{supported: true},
      "8" => %{supported: true},
      "12" => %{supported: true}
    }
  end

  defp extract_mint_pubkey([%Keyset{keys: keys} | _]) do
    # Use the 1-sat denomination public key as the mint pubkey.
    case Map.get(keys, 1) do
      {_priv, pub} -> Base.encode16(pub, case: :lower)
      _ -> ""
    end
  end

  defp extract_mint_pubkey([%{keys: keys} | _]) when is_map(keys) do
    case Map.get(keys, 1) do
      {_priv, pub} when is_binary(pub) -> Base.encode16(pub, case: :lower)
      _ -> ""
    end
  end

  defp extract_mint_pubkey(_), do: ""

  defp extract_id(%Keyset{id: id}), do: id
  defp extract_id(%{id: id}), do: id
  defp extract_id(_), do: ""

  defp extract_unit(%Keyset{unit: unit}), do: unit
  defp extract_unit(%{unit: unit}), do: unit
  defp extract_unit(_), do: "sat"

  defp extract_active(%Keyset{status: :active}), do: true
  defp extract_active(%{active: active}), do: active
  defp extract_active(%{status: :active}), do: true
  defp extract_active(_), do: false

  defp format_keyset_keys(%Keyset{keys: keys}) do
    Map.new(keys, fn {denom, {_priv, pub}} when byte_size(pub) == 33 ->
      {Integer.to_string(denom), Base.encode16(pub, case: :lower)}
    end)
  end

  defp format_keyset_keys(%{keys: keys}) when is_map(keys) do
    Map.new(keys, fn
      {denom, {_priv, pub}} when is_binary(pub) and byte_size(pub) == 33 ->
        {Integer.to_string(denom), Base.encode16(pub, case: :lower)}

      {denom, pub} when is_binary(pub) and byte_size(pub) == 33 ->
        {Integer.to_string(denom), Base.encode16(pub, case: :lower)}
    end)
  end

  defp format_keyset_keys(_), do: %{}
end
