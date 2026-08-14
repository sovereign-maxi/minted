defmodule Minted.Mint.Keysets.Loader do
  @moduledoc """
  Loads a keyset from a JSON file and installs it into the keyset store.

  The JSON format supports both single-node (private_key + public_key)
  and legacy federation (secret_share + group_pubkey) formats.
  """

  alias Minted.Mint.Keyset
  alias Minted.Mint.Keysets.Builder
  alias Minted.Storage.Facade, as: StorageFacade

  require Logger

  @doc """
  Loads a keyset from a JSON file and stores it.

  Returns `{:ok, keyset_id}` or `{:error, reason}`.
  """
  @spec load_and_install(String.t()) :: {:ok, String.t()} | {:error, term()}
  def load_and_install(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         {:ok, keyset} <- build_keyset(data),
         :ok <- verify_id(keyset, data) do
      StorageFacade.put_keyset(Keyset.to_store_map(keyset))
      install_nostr_key(data)
      {:ok, keyset.id}
    end
  end

  defp build_keyset(%{"denomination_keys" => denom_keys}) do
    denom_keys
    |> Enum.reduce_while({:ok, %{}}, fn {denom_str, key_map}, {:ok, acc} ->
      denom = String.to_integer(denom_str)
      privkey = decode_privkey(key_map)
      pubkey = decode_pubkey(key_map)

      case verify_key_binding(denom, privkey, pubkey) do
        :ok -> {:cont, {:ok, Map.put(acc, denom, {privkey, pubkey})}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Builder.assemble_from_keys(keys)}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end

  # A pubkey that doesn't derive from its privkey yields a keyset whose
  # signatures are worthless (wallet-side verification fails) — or,
  # worse, one whose private key is known to whoever planted the file,
  # and the mint's own melt verification would honor their forged
  # proofs. Bind the pair before install.
  defp verify_key_binding(denom, privkey, pubkey) do
    case Cashew.pubkey_from_privkey(privkey) do
      {:ok, ^pubkey} -> :ok
      {:ok, _derived} -> {:error, {:pubkey_mismatch, denom}}
      {:error, reason} -> {:error, {:pubkey_derivation_failed, denom, reason}}
    end
  end

  defp decode_privkey(%{"private_key" => hex}), do: Base.decode16!(hex, case: :mixed)
  defp decode_privkey(%{"secret_share" => hex}), do: Base.decode16!(hex, case: :mixed)

  defp decode_pubkey(%{"public_key" => hex}), do: Base.decode16!(hex, case: :mixed)
  defp decode_pubkey(%{"group_pubkey" => hex}), do: Base.decode16!(hex, case: :mixed)

  defp verify_id(keyset, data) do
    case Map.get(data, "keyset_id") do
      nil -> :ok
      expected when expected == keyset.id -> :ok
      expected -> {:error, {:keyset_id_mismatch, expected: expected, got: keyset.id}}
    end
  end

  defp install_nostr_key(%{"nostr_key" => %{"private" => priv_hex, "public" => pub_hex}}) do
    privkey = Base.decode16!(priv_hex, case: :mixed)
    <<_prefix::8, xonly::binary-32>> = Base.decode16!(pub_hex, case: :mixed)
    data = privkey <> xonly

    path = Minted.Storage.Paths.key_file("nostr_signing_key")
    File.mkdir_p!(Path.dirname(path))

    {:ok, encrypted} = Minted.Storage.Facade.encrypt(data)
    File.write!(path, encrypted)
    File.chmod(path, 0o600)
    Logger.info("Loader: installed nostr signing key")
  rescue
    e -> Logger.warning("Loader: nostr key install failed: #{inspect(e)}")
  end

  defp install_nostr_key(_), do: :ok
end
