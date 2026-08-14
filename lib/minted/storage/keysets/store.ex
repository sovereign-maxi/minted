defmodule Minted.Storage.Keysets.Store do
  @moduledoc """
  GenServer managing persistent keyset storage.

  Keysets are loaded into an ETS table on startup for fast hot-path reads,
  while the WAL provides durability. On keyset creation, the new keyset is
  written to both ETS and the WAL. Private key material is encrypted at rest.

  ## Architecture

  - **Hot path (reads)**: Direct ETS lookups, no GenServer call needed.
  - **Write path**: GenServer serializes writes through WAL, then ETS.
  - **Startup**: Replays WAL entries to rebuild ETS state.
  """

  defmodule PlaintextKeysInWal do
    @moduledoc """
    Raised when WAL replay encounters unencrypted keyset private keys.
    Dedicated exception so the "WAL unavailable" rescue in replay_wal/2
    cannot swallow it — a forged or relic plaintext entry must halt boot.
    """
    defexception [:message]
  end

  use GenServer

  require Logger

  alias Locker.WAL.Entry
  alias Minted.Events.EventBus
  alias Minted.Storage.Encryption
  alias Minted.Storage.Holder

  @ets_table Minted.Storage.Keysets.Store

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Inserts a new keyset. Writes to WAL first, then ETS.

  The keyset map must include at minimum:
  - `:id` - keyset identifier (derived from public key hash)
  - `:public_keys` - map of denomination => public key
  - `:private_keys` - map of denomination => private key (will be encrypted at rest)
  - `:active` - boolean, whether this keyset is currently active
  """
  @spec put(map()) :: :ok | {:error, term()}
  def put(keyset), do: put(__MODULE__, keyset)

  @spec put(GenServer.server(), map()) :: :ok | {:error, term()}
  def put(server, keyset) do
    GenServer.call(server, {:put, keyset})
  end

  @doc """
  Retrieves a keyset by ID directly from ETS.

  This is the hot-path read, no GenServer call needed.
  """
  @spec get(binary()) :: {:ok, map()} | :not_found
  def get(keyset_id) do
    case :ets.lookup(@ets_table, keyset_id) do
      [{^keyset_id, keyset}] -> {:ok, keyset}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Returns all active (non-expired, non-rotated) keysets.
  """
  @spec get_active() :: [map()]
  def get_active do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, keyset} -> keyset end)
    |> Enum.filter(fn keyset ->
      Map.get(keyset, :active, false) and not Map.get(keyset, :expired, false)
    end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns all stored keysets.
  """
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, keyset} -> keyset end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Rotates a keyset: marks the old one as rotated and inserts a new one.
  """
  @spec rotate(binary(), map()) :: :ok | {:error, term()}
  def rotate(old_keyset_id, new_keyset), do: rotate(__MODULE__, old_keyset_id, new_keyset)

  @spec rotate(GenServer.server(), binary(), map()) :: :ok | {:error, term()}
  def rotate(server, old_keyset_id, new_keyset) do
    GenServer.call(server, {:rotate, old_keyset_id, new_keyset})
  end

  @doc """
  Marks a keyset as expired.
  """
  @spec expire(GenServer.server(), binary()) :: :ok | {:error, term()}
  def expire(server \\ __MODULE__, keyset_id) do
    GenServer.call(server, {:expire, keyset_id})
  end

  @doc """
  Returns the ETS table name for direct access.
  """
  @spec table_name() :: atom()
  def table_name, do: @ets_table

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    wal_server = Keyword.get(opts, :wal_server, Minted.Storage.WAL)
    table = Keyword.get(opts, :ets_table, @ets_table)

    # Verify the ETS table is present — owned by Minted.Storage.Holder.
    verify_ets_table(table)

    # Replay WAL entries to rebuild state and recover the seq counter
    # for keyset-owned types.
    %{max_seq: max_seq} = replay_wal(wal_server, table)

    state = %{
      wal_server: wal_server,
      ets_table: table,
      next_seq: max_seq + 1
    }

    # Keyset is loaded by the bootstrap task in Minted.Application
    # after the full supervision tree is up (either from JSON file or
    # generated fresh via Keyset.generate/0).

    {:ok, state}
  end

  @impl true
  def handle_call({:put, keyset}, _from, state) do
    keyset = Map.put_new(keyset, :created_at, System.system_time(:millisecond))
    keyset = Map.put_new(keyset, :active, true)
    keyset = Map.put_new(keyset, :expired, false)

    # Encrypt private keys for WAL storage.
    wal_keyset = encrypt_private_keys(keyset)

    case write(state, :keyset_created, wal_keyset) do
      {:ok, state} ->
        Holder.write(state.ets_table, {keyset.id, keyset})

        publish_event(%Minted.Events.Storage.KeysetCreated{
          keyset_id: keyset.id,
          timestamp: DateTime.utc_now()
        })

        {:reply, :ok, state}

      {{:error, _} = err, state} ->
        {:reply, err, state}
    end
  end

  def handle_call({:rotate, old_id, new_keyset}, _from, state) do
    case :ets.lookup(state.ets_table, old_id) do
      [{^old_id, old_keyset}] ->
        rotated_old = Map.put(old_keyset, :active, false)
        new_keyset = Map.put_new(new_keyset, :created_at, System.system_time(:millisecond))
        new_keyset = Map.put_new(new_keyset, :active, true)
        new_keyset = Map.put_new(new_keyset, :expired, false)

        wal_payload = %{
          old_keyset_id: old_id,
          new_keyset: encrypt_private_keys(new_keyset)
        }

        case write(state, :keyset_rotated, wal_payload) do
          {:ok, state} ->
            Holder.write(state.ets_table, {old_id, rotated_old})
            Holder.write(state.ets_table, {new_keyset.id, new_keyset})

            publish_event(%Minted.Events.Telemetry.KeysetRotated{
              old_keyset_id: old_id,
              new_keyset_id: new_keyset.id,
              timestamp: DateTime.utc_now()
            })

            {:reply, :ok, state}

          {{:error, _} = err, state} ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :keyset_not_found}, state}
    end
  end

  def handle_call({:expire, keyset_id}, _from, state) do
    case :ets.lookup(state.ets_table, keyset_id) do
      [{^keyset_id, keyset}] ->
        destroyed_keys = destroy_private_keys(Map.get(keyset, :private_keys))

        expired_keyset =
          Map.merge(keyset, %{active: false, expired: true, private_keys: destroyed_keys})

        case write(state, :keyset_expired, %{keyset_id: keyset_id}) do
          {:ok, state} ->
            Holder.write(state.ets_table, {keyset_id, expired_keyset})

            publish_event(%Minted.Events.Storage.KeysetExpired{
              keyset_id: keyset_id,
              timestamp: DateTime.utc_now()
            })

            {:reply, :ok, state}

          {{:error, _} = err, state} ->
            {:reply, err, state}
        end

      [] ->
        {:reply, {:error, :keyset_not_found}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # ETS table is owned by Minted.Storage.Holder — it persists across restarts.
    Logger.debug("Store: shutting down")
    state
  end

  # --- Private Helpers ---

  defp verify_ets_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        raise "ETS table #{table} not found — Minted.Storage.Holder must start before Store"

      _ref ->
        table
    end
  end

  # Stamps the next seq onto `payload`, appends to WAL, and on
  # success bumps state.next_seq. On WAL failure, state is untouched
  # so the next attempt reuses the same seq — no gaps from failed
  # writes.
  defp write(state, type, payload) do
    sealed = Map.put(payload, :seq, state.next_seq)
    entry = %Entry{type: type, payload: sealed}

    case Locker.WAL.append(state.wal_server, entry) do
      :ok -> {:ok, %{state | next_seq: state.next_seq + 1}}
      {:error, _} = err -> {err, state}
    end
  end

  defp replay_wal(wal_server, table) do
    case Locker.WAL.read_all(wal_server) do
      {:ok, entries} ->
        relevant = Enum.filter(entries, &owned?/1)

        max_seq =
          Enum.reduce(relevant, 0, fn entry, acc ->
            apply_wal_entry(entry, table)
            max(acc, entry_seq(entry))
          end)

        Logger.debug("Store: replayed #{length(relevant)} keyset WAL entries, max_seq=#{max_seq}")
        verify_replay_consistency(relevant, table)

        %{max_seq: max_seq}

      {:error, reason} ->
        Logger.warning("Store: WAL replay failed: #{inspect(reason)}")
        %{max_seq: 0}
    end
  rescue
    e in PlaintextKeysInWal ->
      reraise(e, __STACKTRACE__)

    e ->
      Logger.warning("Store: WAL replay skipped (WAL not available): #{inspect(e)}")
      %{max_seq: 0}
  end

  @keyset_types ~w(keyset_created keyset_rotated keyset_expired)a
  defp owned?(%Entry{type: type}) when type in @keyset_types, do: true
  defp owned?(_), do: false

  defp entry_seq(%Entry{payload: %{seq: seq}}) when is_integer(seq), do: seq
  defp entry_seq(_), do: 0

  defp verify_replay_consistency(entries, table) do
    wal_keyset_ids =
      entries
      |> Enum.flat_map(fn
        %Entry{type: :keyset_created, payload: %{id: id}} -> [id]
        %Entry{type: :keyset_rotated, payload: %{new_keyset: %{id: id}}} -> [id]
        _ -> []
      end)
      |> MapSet.new()

    ets_size = :ets.info(table, :size)
    wal_count = MapSet.size(wal_keyset_ids)

    if ets_size != wal_count do
      Logger.warning(
        "Store: replay consistency check: ETS has #{ets_size} keysets but WAL has #{wal_count} distinct keyset IDs"
      )
    end
  end

  defp apply_wal_entry(%Entry{type: :keyset_created, payload: keyset}, table) do
    keyset = decrypt_private_keys(keyset)
    Holder.write(table, {keyset.id, keyset})
  end

  defp apply_wal_entry(%Entry{type: :keyset_rotated, payload: payload}, table) do
    %{old_keyset_id: old_id, new_keyset: new_keyset} = payload

    case :ets.lookup(table, old_id) do
      [{^old_id, old_keyset}] ->
        Holder.write(table, {old_id, Map.put(old_keyset, :active, false)})

      [] ->
        :ok
    end

    new_keyset = decrypt_private_keys(new_keyset)
    Holder.write(table, {new_keyset.id, new_keyset})
  end

  defp apply_wal_entry(%Entry{type: :keyset_expired, payload: %{keyset_id: id}}, table) do
    case :ets.lookup(table, id) do
      [{^id, keyset}] ->
        destroyed_keys = destroy_private_keys(Map.get(keyset, :private_keys))

        Holder.write(
          table,
          {id, %{keyset | active: false, expired: true, private_keys: destroyed_keys}}
        )

      [] ->
        :ok
    end
  end

  defp apply_wal_entry(_entry, _table), do: :ok

  # Replace private key material with :destroyed sentinel on expiration.
  defp destroy_private_keys(keys) when is_map(keys) do
    Map.new(keys, fn {denom, _priv} -> {denom, :destroyed} end)
  end

  defp destroy_private_keys(other), do: other

  defp encrypt_private_keys(keyset) do
    case Map.get(keyset, :private_keys) do
      nil ->
        keyset

      private_keys ->
        {:ok, encrypted} = Encryption.encrypt_term(private_keys, keyset_aad(keyset))
        Map.put(keyset, :private_keys, {:encrypted, encrypted})
    end
  rescue
    e ->
      Logger.error("Store: encryption failed, reason=#{inspect(e)}")

      reraise "Encryption of private keys failed — refusing to store plaintext",
              __STACKTRACE__
  end

  defp decrypt_private_keys(keyset) do
    case Map.get(keyset, :private_keys) do
      {:encrypted, data} ->
        case Encryption.decrypt_term(data, keyset_aad(keyset)) do
          {:ok, private_keys} ->
            Map.put(keyset, :private_keys, private_keys)

          {:error, _reason} ->
            Logger.error("Store: failed to decrypt private keys, keyset_id=#{inspect(Map.get(keyset, :id))}")

            raise "Decryption of private keys failed for keyset #{inspect(Map.get(keyset, :id))}"
        end

      _other ->
        # Refuse plaintext private keys on replay. Every write path
        # encrypts before append, so an unencrypted entry on disk is
        # either a forged keyset injection (its signatures would pass
        # melt verification) or a pre-encryption relic that must be
        # re-encrypted first. Fail closed. Raises a dedicated exception
        # so replay_wal's "WAL unavailable" rescue can't swallow it.
        Logger.error("Store: refusing plaintext private keys in WAL replay, keyset_id=#{inspect(Map.get(keyset, :id))}")

        raise PlaintextKeysInWal,
              "Plaintext private keys in WAL for keyset #{inspect(Map.get(keyset, :id))} — " <>
                "refusing to replay. Re-encrypt or quarantine the segment."
    end
  end

  # Per-keyset AAD binds the AES-GCM tag to the keyset_id. An
  # attacker who swaps two encrypted `private_keys` blobs on disk
  # (across keyset_id boundaries) gets a tag mismatch and the
  # decrypt fails — the previous global AAD made every blob
  # interchangeable, so `keyset A` could be swapped to hold
  # `keyset B`'s keys with no detection at the storage layer.
  defp keyset_aad(keyset) do
    case Map.get(keyset, :id) do
      id when is_binary(id) -> "keyset:" <> id
      # No id — fall back to the encryption default. Should never
      # happen in practice (keyset writes without an id would fail
      # further validation), but avoids raising from an AAD helper.
      _ -> "minted-keyset-v2"
    end
  end

  defp publish_event(%{__struct__: _} = event) do
    EventBus.publish(event)
  rescue
    e ->
      Logger.warning("Store: publish_event failed: #{inspect(e)}")
      :ok
  end
end
