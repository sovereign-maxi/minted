defmodule Minted.Mint.Keyset do
  @moduledoc """
  Aggregate managing a set of 21 denomination keys (2^0 through 2^20 sats).

  Keyset ID is derived per Cashu NUT-02: SHA256 of sorted concatenated
  compressed pubkeys, first 8 bytes, hex-encoded.
  """

  @enforce_keys [:id, :unit, :keys, :status, :created_at]
  defstruct [:id, :unit, :keys, :status, :created_at, :rotated_at]

  @type status :: :active | :retired | :expired
  @type key_pair :: {privkey :: binary(), pubkey :: binary()}

  @type t :: %__MODULE__{
          id: String.t(),
          unit: String.t(),
          keys: %{pos_integer() => key_pair()},
          status: status(),
          created_at: DateTime.t(),
          rotated_at: DateTime.t() | nil
        }

  @denominations for exp <- 0..20, do: Integer.pow(2, exp)

  @spec denominations() :: [pos_integer()]
  def denominations, do: @denominations

  @spec generate(keyword()) :: t()
  def generate(opts \\ []) do
    unit = Keyword.get(opts, :unit, "sat")

    keys =
      Map.new(@denominations, fn denom ->
        {:ok, {privkey, pubkey}} = Cashew.generate_keypair()
        {denom, {privkey, pubkey}}
      end)

    id = derive_id(keys)

    %__MODULE__{
      id: id,
      unit: unit,
      keys: keys,
      status: :active,
      created_at: DateTime.utc_now()
    }
  end

  # NUT-02: keyset_id = "00" || hex(SHA256(sorted_pubkeys)[0..14]),
  # 16 lowercase hex characters with leading version byte.
  @spec derive_id(%{pos_integer() => key_pair()}) :: String.t()
  def derive_id(keys) when is_map(keys) do
    body =
      keys
      |> Enum.sort_by(fn {denom, _} -> denom end)
      |> Enum.map(fn {_denom, {_priv, pub}} -> pub end)
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 7)
      |> Base.encode16(case: :lower)

    "00" <> body
  end

  @spec get_key(t(), pos_integer()) :: {:ok, key_pair()} | {:error, :denomination_not_found}
  def get_key(%__MODULE__{keys: keys}, denomination) do
    case Map.fetch(keys, denomination) do
      {:ok, key_pair} -> {:ok, key_pair}
      :error -> {:error, :denomination_not_found}
    end
  end

  @spec public_keys(t()) :: %{pos_integer() => binary()}
  def public_keys(%__MODULE__{keys: keys}) do
    Map.new(keys, fn {denom, {_priv, pub}} -> {denom, pub} end)
  end

  @doc """
  Inverse of `from_store_map/1`. Splits the merged `:keys` map back into
  the `:public_keys` / `:private_keys` shape that
  `Minted.Storage.Facade.put_keyset/1` and `rotate_keyset/2` expect.
  """
  @spec to_store_map(t()) :: map()
  def to_store_map(%__MODULE__{} = keyset) do
    public_keys = Map.new(keyset.keys, fn {denom, {_share, pub}} -> {denom, pub} end)
    private_keys = Map.new(keyset.keys, fn {denom, {share, _pub}} -> {denom, share} end)

    %{
      id: keyset.id,
      unit: keyset.unit,
      public_keys: public_keys,
      private_keys: private_keys,
      active: true,
      expired: false,
      created_at: keyset.created_at
    }
  end

  @doc """
  Converts a Keysets.Store map (with separate :public_keys/:private_keys)
  into a Keyset struct (with merged :keys map of {privkey, pubkey} tuples).
  """
  @spec from_store_map(map()) :: {:ok, t()} | {:error, term()}
  def from_store_map(%{id: id} = map) do
    case keys_from_map(map) do
      {:ok, keys} ->
        status =
          cond do
            Map.get(map, :expired, false) -> :expired
            # Default :active to false on missing field — a keyset with unknown
            # status must not be treated as an active signing keyset.
            Map.get(map, :active, false) -> :active
            true -> :retired
          end

        {:ok,
         %__MODULE__{
           id: id,
           unit: Map.get(map, :unit, "sat"),
           keys: keys,
           status: status,
           created_at: Map.get(map, :created_at) || DateTime.utc_now(),
           rotated_at: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  # Already in merged {denom => {priv, pub}} format (from Map.from_struct)
  defp keys_from_map(%{keys: keys}) when is_map(keys) and map_size(keys) > 0, do: {:ok, keys}

  # Split public_keys / private_keys format (from Keysets.Store.put/1 callers)
  defp keys_from_map(map) do
    build_merged_keys(Map.get(map, :public_keys, %{}), Map.get(map, :private_keys, %{}))
  end

  defp build_merged_keys(pub_keys, priv_keys) do
    Enum.reduce_while(pub_keys, {:ok, %{}}, fn {denom, pub}, {:ok, acc} ->
      case Map.get(priv_keys, denom) do
        nil -> {:halt, {:error, {:missing_key, denom}}}
        priv -> {:cont, {:ok, Map.put(acc, denom, {priv, pub})}}
      end
    end)
  end

  @spec retire(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def retire(%__MODULE__{status: :active} = keyset) do
    {:ok, %{keyset | status: :retired, rotated_at: DateTime.utc_now()}}
  end

  def retire(_), do: {:error, :invalid_transition}

  @spec expire(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def expire(%__MODULE__{status: :retired} = keyset) do
    {:ok, %{keyset | status: :expired, keys: scrub_private_keys(keyset.keys)}}
  end

  def expire(_), do: {:error, :invalid_transition}

  @doc """
  Replaces private key material with random bytes of equal length.

  This is a best-effort mitigation for S2 (private keys on BEAM heap).
  Erlang binaries are immutable and GC-managed, so the original bytes
  may persist until garbage collected. This reduces the exposure window
  by overwriting the struct references and forcing an immediate GC.

  NOTE: NIF-based zeroize (writing zeros to BEAM binary memory via Rust
  `unsafe`) was considered but deferred — it requires casting Rustler's
  read-only `Binary` pointer to mutable, which is UB in Rust and risks
  corrupting shared refc binaries.
  """
  # Best-effort scrubbing: Erlang binaries are immutable and GC-managed.
  # The original private key bytes may linger on the heap until garbage
  # collection reclaims them. The forced GC call reduces this window.
  @spec scrub_private_keys(%{pos_integer() => key_pair()}) :: %{pos_integer() => key_pair()}
  def scrub_private_keys(keys) when is_map(keys) do
    scrubbed =
      Map.new(keys, fn {denom, {priv, pub}} ->
        {denom, {:crypto.strong_rand_bytes(byte_size(priv)), pub}}
      end)

    # Force GC to reclaim the original key binaries sooner.
    :erlang.garbage_collect(self())
    scrubbed
  end
end
