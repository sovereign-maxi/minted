defmodule Minted.Storage.Compaction do
  @moduledoc """
  Compaction module that prunes spent set entries belonging to expired keysets.

  Compaction removes matching entries from both the ETS hot tier and the
  backend cold tier via `Spent.compact_keyset/1`, reclaiming storage space
  and reducing lookup overhead. Only operates on keysets that are confirmed expired.

  Compaction is idempotent — running it on an already-compacted keyset is a no-op.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Storage.Keysets.Store
  alias Minted.Storage.Paths

  @doc """
  Compacts (removes) all spent set entries for an expired keyset.

  Only operates on keysets that are confirmed expired. Refuses to compact
  active keysets.

  Delegates the actual data removal to `Spent.compact_keyset/1`, which
  removes from the backend (durable tier) first, then ETS (cache tier).
  This ordering is crash-safe: if the process crashes between the two
  deletes, ETS is rebuilt from the backend on restart, and the entry stays
  deleted.

  Returns `{:ok, entries_removed}` or `{:error, reason}`.
  """
  @spec compact(binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def compact(keyset_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    with :ok <- verify_expired(keyset_id) do
      # Remove from backend + ETS via Mint facade.
      {:ok, %{backend: backend_removed, ets: ets_removed}} =
        MintFacade.compact_keyset(keyset_id)

      total_removed = ets_removed + backend_removed

      elapsed = System.monotonic_time(:millisecond) - start_time

      Logger.info(
        "Compaction: completed for keyset #{inspect(keyset_id)}: " <>
          "#{total_removed} entries removed in #{elapsed}ms " <>
          "(backend: #{backend_removed}, ets: #{ets_removed})"
      )

      publish_event(%Minted.Events.Storage.CompactionCompleted{
        keyset_id: keyset_id,
        entries_removed: total_removed,
        elapsed_ms: elapsed,
        timestamp: DateTime.utc_now()
      })

      prune_wal(opts)

      {:ok, total_removed}
    end
  end

  @doc """
  Prunes old WAL segments, keeping the `keep` most recent.

  Uses the configured `:wal_dir` or a directory passed via options.
  Returns `{:ok, pruned_count}` or `{:ok, 0}` if pruning fails.
  """
  @spec prune_wal(keyword()) :: {:ok, non_neg_integer()}
  def prune_wal(opts \\ []) do
    wal_dir =
      Keyword.get_lazy(opts, :wal_dir, fn ->
        Paths.storage_wal()
      end)

    keep = Keyword.get(opts, :wal_keep_segments, 5)

    {:ok, pruned} = Locker.WAL.prune(wal_dir, keep)

    if pruned > 0 do
      Logger.info("Compaction: pruned old WAL segments, count=#{pruned}")
    end

    {:ok, pruned}
  rescue
    e ->
      Logger.warning("Compaction: WAL prune raised: #{inspect(e)}")
      {:ok, 0}
  end

  # --- Private Helpers ---

  defp verify_expired(keyset_id) do
    case Store.get(keyset_id) do
      {:ok, keyset} ->
        if Map.get(keyset, :expired, false) do
          :ok
        else
          {:error, :keyset_not_expired}
        end

      :not_found ->
        # Unknown keyset — keep its entries rather than deleting (H7)
        Logger.warning("Compaction: keyset #{inspect(keyset_id)} not found, keeping entries")
        {:error, :keyset_not_found}
    end
  rescue
    e ->
      Logger.warning("Compaction: verify_expired failed for keyset #{inspect(keyset_id)}: #{inspect(e)}")

      {:error, :verify_failed}
  end

  defp publish_event(%{__struct__: _} = event) do
    EventBus.publish(event)
  rescue
    e ->
      Logger.warning("Compaction: publish_event failed: #{inspect(e)}")
      :ok
  end
end
