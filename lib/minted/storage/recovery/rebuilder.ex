defmodule Minted.Storage.Recovery.Rebuilder do
  @moduledoc """
  Rebuilds ETS tables from cold tier (DETS) data during crash recovery.

  This module is used when the WAL is insufficient to fully restore state,
  falling back to DETS as the Level 2 recovery source.
  """

  require Logger

  alias Locker.WAL.Entry
  alias Minted.Storage.Encryption

  @doc """
  Rebuilds the keyset ETS table from WAL entries.

  Replays keyset-related WAL entries in order to reconstruct the current
  keyset state in ETS.
  """
  @spec rebuild_keysets_from_wal([Entry.t()], atom()) :: {:ok, non_neg_integer()}
  def rebuild_keysets_from_wal(entries, ets_table \\ Minted.Storage.Keysets.Store) do
    ensure_ets_table(ets_table)

    count =
      entries
      |> Enum.filter(fn e ->
        e.type in [:keyset_created, :keyset_rotated, :keyset_expired]
      end)
      |> Enum.reduce(0, fn entry, acc ->
        apply_entry(entry, ets_table)
        acc + 1
      end)

    Logger.info("Rebuilder: rebuilt keyset entries from WAL, count=#{count}")
    {:ok, count}
  end

  @doc """
  Rebuilds keyset state from a DETS table (Level 2 fallback).
  """
  @spec rebuild_keysets_from_dets(atom(), atom()) :: {:ok, non_neg_integer()}
  def rebuild_keysets_from_dets(dets_table, ets_table \\ Minted.Storage.Keysets.Store) do
    ensure_ets_table(ets_table)

    records = :dets.match_object(dets_table, :_)

    {valid, invalid} =
      Enum.split_with(records, fn
        {key, value} when is_binary(key) and is_map(value) -> true
        _ -> false
      end)

    if invalid != [] do
      Logger.error(
        "Rebuilder: discarding #{length(invalid)} malformed DETS records " <>
          "(expected {binary_key, map} tuples)"
      )
    end

    Enum.each(valid, fn {key, value} ->
      :ets.insert(ets_table, {key, value})
    end)

    count = length(valid)
    Logger.info("Rebuilder: rebuilt #{count} keyset entries from DETS into ETS")
    {:ok, count}
  rescue
    e ->
      Logger.error("Rebuilder: failed to rebuild from DETS: #{inspect(e)}")
      {:ok, 0}
  end

  # --- Private Helpers ---

  defp ensure_ets_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

      _ref ->
        table
    end
  end

  defp apply_entry(%Entry{type: :keyset_created, payload: keyset}, table) do
    keyset = decrypt_private_keys(keyset)
    :ets.insert(table, {keyset.id, keyset})
  end

  defp apply_entry(%Entry{type: :keyset_rotated, payload: payload}, table) do
    %{old_keyset_id: old_id, new_keyset: new_keyset} = payload

    case :ets.lookup(table, old_id) do
      [{^old_id, old}] ->
        :ets.insert(table, {old_id, Map.put(old, :active, false)})

      [] ->
        :ok
    end

    new_keyset = decrypt_private_keys(new_keyset)
    :ets.insert(table, {new_keyset.id, new_keyset})
  end

  defp apply_entry(%Entry{type: :keyset_expired, payload: %{keyset_id: id}}, table) do
    case :ets.lookup(table, id) do
      [{^id, keyset}] ->
        :ets.insert(table, {id, %{keyset | active: false, expired: true}})

      [] ->
        :ok
    end
  end

  defp apply_entry(_entry, _table), do: :ok

  defp decrypt_private_keys(keyset) do
    case Map.get(keyset, :private_keys) do
      {:encrypted, data} ->
        case Encryption.decrypt_term(data) do
          {:ok, keys} ->
            Map.put(keyset, :private_keys, keys)

          {:error, reason} ->
            # M8 fix: Log error and strip encrypted blob to prevent corrupted state.
            # The keyset will be loaded without private keys — signing will fail
            # explicitly rather than silently using encrypted binary as key material.
            keyset_id = Map.get(keyset, :id, "unknown")

            Logger.error(
              "Rebuilder: failed to decrypt private keys for keyset #{keyset_id}: #{inspect(reason)}. " <>
                "Keyset loaded WITHOUT private keys — signing operations will fail."
            )

            Map.put(keyset, :private_keys, :decryption_failed)
        end

      _ ->
        keyset
    end
  end
end
