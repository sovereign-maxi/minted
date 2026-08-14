defmodule Minted.TestHelpers.WalletHelpers do
  @moduledoc """
  Test helpers for token construction via the BDHKE round-trip.

  Despite the name, these are mint-side helpers used by scenario and
  integration tests to build cryptographically valid tokens against a
  known keyset, plus keyset seeding helpers.
  """

  alias Minted.Mint.{Keyset, Token}
  alias Minted.Mint.Signatures.Blind
  alias Minted.Storage.Keysets.Store

  @doc """
  Builds a cryptographically valid token using the full BDHKE round-trip.
  """
  @spec build_valid_token(Keyset.t(), pos_integer()) :: Token.t()
  def build_valid_token(%Keyset{} = keyset, amount) do
    {:ok, {privkey, pubkey}} = Keyset.get_key(keyset, amount)
    keypair = %Blind.KeyPair{private_key: privkey, public_key: pubkey}
    secret = :crypto.strong_rand_bytes(32)
    {:ok, proof} = Blind.blind_sign_unblind(secret, keypair)

    %Token{
      amount: amount,
      secret: proof.secret,
      c: proof.c,
      keyset_id: keyset.id
    }
  end

  @doc "Builds N valid tokens for the given amounts."
  @spec build_valid_tokens(Keyset.t(), [pos_integer()]) :: [Token.t()]
  def build_valid_tokens(%Keyset{} = keyset, amounts) when is_list(amounts) do
    Enum.map(amounts, &build_valid_token(keyset, &1))
  end

  @doc """
  Gets or creates a test keyset compatible with `Keyset.from_store_map/1`.

  The app's `ensure_initial_keyset` stores keysets using `Map.from_struct`
  (which has a `keys` field), but consumers of `from_store_map/1` expect
  separate `public_keys`/`private_keys`. This helper guarantees a keyset
  in the consumer-friendly shape exists.
  """
  @spec get_or_create_test_keyset() :: Keyset.t()
  def get_or_create_test_keyset do
    case find_compatible_keyset() do
      {:ok, keyset} ->
        expire_all_active_keysets_except(keyset.id)
        keyset

      :not_found ->
        keyset = Keyset.generate()
        store_keyset_compatible(keyset)
        keyset
    end
  end

  defp find_compatible_keyset do
    Store.get_active()
    |> Enum.reduce_while(:not_found, fn store_map, _acc ->
      case Keyset.from_store_map(store_map) do
        {:ok, %Keyset{keys: keys} = keyset} when map_size(keys) > 0 ->
          {:halt, {:ok, keyset}}

        _ ->
          {:cont, :not_found}
      end
    end)
  end

  @doc "Stores a keyset in the format compatible with `Keyset.from_store_map/1`."
  @spec store_keyset(Keyset.t()) :: :ok
  def store_keyset(%Keyset{} = keyset) do
    Store.put(%{
      id: keyset.id,
      public_keys: Keyset.public_keys(keyset),
      private_keys: Map.new(keyset.keys, fn {denom, {priv, _pub}} -> {denom, priv} end),
      active: true
    })
  end

  defp store_keyset_compatible(%Keyset{} = keyset) do
    expire_all_active_keysets()
    store_keyset(keyset)
  end

  defp expire_all_active_keysets do
    expire_all_active_keysets_except(nil)
  end

  defp expire_all_active_keysets_except(keep_id) do
    Store.get_active()
    |> Enum.each(fn store_map ->
      id = Map.get(store_map, :id)
      if id != keep_id, do: Store.expire(id)
    end)
  rescue
    _ -> :ok
  end
end
