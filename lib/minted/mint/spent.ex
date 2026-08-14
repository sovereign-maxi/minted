defmodule Minted.Mint.Spent do
  @moduledoc """
  GenServer managing the `:spent_set` ETS table for O(1)
  double-spend detection. Every redeemed token secret is
  SHA256-hashed and stored in this set.

  ## Backend Persistence

  All spent entries are written through to a configurable backend
  (CubDB by default, DETS available) for crash recovery. On startup,
  backend entries are loaded into ETS so the spent set survives
  process restarts.

  ## Y-Index Invariant

  Y-index entries (for NUT-07 `spent_by_y?`) are inserted ONLY after the
  primary hash is durably persisted and promoted to main ETS. This
  ensures the Y-index is never ahead of the spent set. Batch operations
  fail entirely if any `hash_to_curve` computation fails.

  ## Pruning

  The ETS table grows unboundedly as tokens are spent. Pruning of entries
  belonging to expired keysets is handled via `compact_keyset/1`, which
  removes entries matching a given keyset_id from both the backend and
  the ETS tables. This is safe because tokens from expired keysets
  can never be redeemed again.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Storage.Facade, as: StorageFacade

  @table Minted.Mint.Spent
  @y_table Minted.Mint.Spent.Y
  @pending_table Minted.Mint.Spent.Pending
  @stats_interval_ms 60_000
  @max_queue_depth 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec spent?(binary()) :: boolean()
  def spent?(secret) when is_binary(secret) do
    hash = hash_secret(secret)
    :ets.member(@table, hash) or :ets.member(@pending_table, hash)
  rescue
    # Fail-closed: if ETS tables are unavailable, treat all tokens as spent
    # to prevent double-spend. Users can retry once the system recovers.
    ArgumentError -> true
  end

  @doc "NUT-07 check: returns true if Y = hash_to_curve(secret) is in the spent Y-index."
  @spec spent_by_y?(binary()) :: boolean()
  def spent_by_y?(y) when is_binary(y) do
    :ets.member(@y_table, y)
  rescue
    ArgumentError -> true
  end

  # GenServer.call serialization guarantees atomicity — no concurrent
  # mark_spent can interleave between duplicate check and backend write.
  @spec mark_spent(binary(), String.t()) :: :ok | {:error, :already_spent | :overloaded}
  def mark_spent(secret, keyset_id) when is_binary(secret) do
    with :ok <- check_overloaded() do
      GenServer.call(__MODULE__, {:mark_spent, secret, keyset_id})
    end
  end

  @spec mark_spent_batch([{binary(), String.t()}]) ::
          :ok | {:error, :double_spend | :overloaded}
  def mark_spent_batch(entries) when is_list(entries) do
    with :ok <- check_overloaded() do
      GenServer.call(__MODULE__, {:mark_spent_batch, entries})
    end
  end

  @spec verify_and_mark_spent(
          [{binary(), String.t()}],
          (binary(), String.t() -> :ok | {:error, term()} | {:error, term(), term()})
        ) :: :ok | {:error, term()} | {:error, term(), term()}
  def verify_and_mark_spent(entries, verify_fn)
      when is_list(entries) and is_function(verify_fn, 2) do
    with :ok <- check_overloaded() do
      GenServer.call(__MODULE__, {:verify_and_mark_spent, entries, verify_fn})
    end
  end

  @doc """
  Verifies tokens and reserves them in the pending table without durably marking
  them as spent. Reserved entries block double-spend checks (`spent?/1` returns true)
  but are not persisted to the backend. Use `commit_reserved/1` to finalize or
  `release_reserved/1` to cancel.
  """
  @spec verify_and_reserve(
          [{binary(), String.t()}],
          (binary(), String.t() -> :ok | {:error, term()} | {:error, term(), term()})
        ) :: :ok | {:error, term()} | {:error, term(), term()}
  def verify_and_reserve(entries, verify_fn)
      when is_list(entries) and is_function(verify_fn, 2) do
    with :ok <- check_overloaded() do
      GenServer.call(__MODULE__, {:verify_and_reserve, entries, verify_fn})
    end
  end

  @doc """
  Promotes reserved entries from the pending table to the main spent set with
  backend persistence. Call after a successful Lightning payment.
  """
  @spec commit_reserved([{binary(), String.t()}]) :: :ok | {:error, term()}
  def commit_reserved(entries) when is_list(entries) do
    with :ok <- check_overloaded() do
      GenServer.call(__MODULE__, {:commit_reserved, entries})
    end
  end

  @doc """
  Removes reserved entries from the pending table, making the tokens available
  again. Call when a Lightning payment fails.
  """
  @spec release_reserved([{binary(), String.t()}]) :: :ok
  def release_reserved(entries) when is_list(entries) do
    GenServer.call(__MODULE__, {:release_reserved, entries})
  end

  @doc """
  Removes all spent set entries (backend + ETS) for the given keyset_id.

  Called by `Minted.Storage.Compaction` to prune entries belonging to
  expired keysets. Returns the number of entries removed from each tier.
  """
  @spec compact_keyset(binary()) :: {:ok, %{backend: non_neg_integer(), ets: non_neg_integer()}}
  def compact_keyset(keyset_id) when is_binary(keyset_id) do
    GenServer.call(__MODULE__, {:compact_keyset, keyset_id})
  end

  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Clears all entries from the spent set. For use in tests only."
  @spec clear() :: :ok
  def clear do
    if Application.get_env(:minted, :env, :dev) == :prod do
      raise "Spent.clear/0 must not be called in production — " <>
              "clearing the spent set allows all previously-spent tokens to be double-spent"
    end

    GenServer.call(__MODULE__, :clear)
  end

  # Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # ETS tables are owned by Minted.Mint.Holder (started before us in the
    # supervision tree). This ensures tables survive Spent crashes — reads
    # continue working during the restart window.

    {backend_mod, backend_ref} = open_spent_set_backend_or_fallback()
    load_backend_into_ets(backend_mod, backend_ref)

    state = %{table: @table, backend: backend_mod, backend_ref: backend_ref}

    # FAIL-SAFE: Promote pending entries to main table instead of deleting.
    # Pending entries represent in-flight melt payments that may have settled
    # on Lightning. Deleting them would allow double-spend (token resurrection).
    promote_pending_to_main(state)

    # Load any incomplete melt hashes flagged by the Recovery module.
    # These are secret_hashes from :melt_started WAL entries without a
    # matching :melt_settled — the payment may have settled before the crash.
    load_recovery_blocked_hashes(state)

    Process.send_after(self(), :emit_stats, @stats_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:emit_stats, state) do
    spent_count = :ets.info(@table, :size)
    y_count = :ets.info(@y_table, :size)

    queue_len =
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, len} -> len
        _ -> 0
      end

    word_size = :erlang.system_info(:wordsize)
    spent_mem = :ets.info(@table, :memory) * word_size
    y_mem = :ets.info(@y_table, :memory) * word_size
    pending_mem = :ets.info(@pending_table, :memory) * word_size

    :telemetry.execute(
      [:minted, :spent_set, :size],
      %{
        spent: spent_count,
        y_index: y_count,
        queue_depth: queue_len,
        memory_bytes: spent_mem + y_mem + pending_mem,
        pending_count: :ets.info(@pending_table, :size)
      },
      %{}
    )

    Process.send_after(self(), :emit_stats, @stats_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:mark_spent, secret, keyset_id}, _from, state) do
    hash = hash_secret(secret)
    # Pre-compute Y BEFORE any mutation
    y_result = compute_y_entry(secret, keyset_id)
    now = System.monotonic_time()

    result =
      if :ets.member(@table, hash) or :ets.member(@pending_table, hash) do
        # Publish double-spend detection event (H11)
        publish_double_spend(hash, keyset_id)
        {:error, :already_spent}
      else
        # Backend write FIRST for durability — no pending-table window.
        y_backend_entry = y_result_to_backend_entry(y_result)

        case backend_write_sync(
               state.backend_ref,
               state.backend,
               hash,
               {keyset_id, now},
               y_backend_entry
             ) do
          :ok ->
            # Insert directly into main ETS (skip @pending_table entirely)
            :ets.insert(@table, {hash, keyset_id, now})
            # INVARIANT: Y-index inserted ONLY after the primary hash is
            # durably persisted and in main ETS. A Y-index failure is
            # logged + metered but never fails the mark_spent — the spend
            # is already durable, and an error reply would invite a retry
            # that reports already_spent for a token we did record.
            insert_y_or_warn(y_result, keyset_id)

          {:error, :backend_write_failed} ->
            {:error, :storage_failure}
        end
      end

    {:reply, result, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@y_table)
    :ets.delete_all_objects(@pending_table)
    {:reply, :ok, state}
  end

  def handle_call({:verify_and_mark_spent, entries, verify_fn}, _from, state) do
    verify_result =
      Enum.reduce_while(entries, :ok, fn {secret, keyset_id}, :ok ->
        case verify_fn.(secret, keyset_id) do
          :ok -> {:cont, :ok}
          {:error, _, _} = err -> {:halt, err}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case verify_result do
      :ok -> {:reply, batch_insert_or_rollback(entries, state), state}
      err -> {:reply, err, state}
    end
  end

  def handle_call({:mark_spent_batch, entries}, _from, state) do
    {:reply, batch_insert_or_rollback(entries, state), state}
  end

  # --- Reservation handlers ---

  def handle_call({:verify_and_reserve, entries, verify_fn}, _from, state) do
    verify_result =
      Enum.reduce_while(entries, :ok, fn {secret, keyset_id}, :ok ->
        case verify_fn.(secret, keyset_id) do
          :ok -> {:cont, :ok}
          {:error, _, _} = err -> {:halt, err}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case verify_result do
      :ok -> {:reply, reserve_batch(entries), state}
      err -> {:reply, err, state}
    end
  end

  def handle_call({:commit_reserved, entries}, _from, state) do
    {:reply, commit_reserved_batch(entries, state), state}
  end

  def handle_call({:release_reserved, entries}, _from, state) do
    Enum.each(entries, fn {secret, _keyset_id} ->
      hash = hash_secret(secret)
      :ets.delete(@pending_table, hash)
    end)

    {:reply, :ok, state}
  end

  # --- Compaction handler ---

  def handle_call({:compact_keyset, keyset_id}, _from, state) do
    # Defense-in-depth: the sole current caller checks the keyset is
    # expired before invoking compaction, but compacting an ACTIVE
    # keyset destroys the double-spend guard for every unspent token
    # under it. Re-check here so a future caller (operator console,
    # migration script) can't accidentally bypass the guard.
    case keyset_status(keyset_id) do
      :expired ->
        backend_result =
          if state.backend_ref do
            state.backend.delete_match(state.backend_ref, keyset_id)
          else
            0
          end

        case backend_result do
          {:error, reason} ->
            # Backend delete failed — keep the ETS entries too, so the
            # reply never reports a compaction that didn't persist.
            Logger.error("Spent: backend compaction failed, keyset_id=#{keyset_id}, reason=#{inspect(reason)}")

            {:reply, {:error, :backend_compaction_failed}, state}

          backend_removed ->
            ets_removed = remove_keyset_from_ets(keyset_id)
            {:reply, {:ok, %{backend: backend_removed, ets: ets_removed}}, state}
        end

      other ->
        Logger.error("Spent: refusing to compact non-expired keyset, keyset_id=#{keyset_id}, status=#{inspect(other)}")

        {:reply, {:error, {:keyset_not_expired, other}}, state}
    end
  end

  # Reads the keyset's status through the Storage facade. Store
  # returns a plain map with `:active` and `:expired` flags (not
  # `:status`), so we derive status the same way
  # `Keyset.from_store_map/1` does. Missing keysets are treated as
  # unsafe to compact — better a spurious refusal than accidentally
  # wiping the guard.
  defp keyset_status(keyset_id) do
    case Minted.Storage.Facade.get_keyset(keyset_id) do
      {:ok, map} ->
        cond do
          Map.get(map, :expired, false) -> :expired
          Map.get(map, :active, false) -> :active
          true -> :retired
        end

      :not_found ->
        :not_found
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @impl true
  def terminate(_reason, state) do
    if state[:backend_ref] && state[:backend] do
      state.backend.close(state.backend_ref)
    end

    :ok
  end

  # --- Reservation helpers ---

  defp reserve_batch(entries) do
    now = System.monotonic_time()

    hashed =
      Enum.map(entries, fn {secret, keyset_id} ->
        {hash_secret(secret), keyset_id}
      end)

    # Reject batches with intra-batch duplicate secrets.
    unique_hashes = hashed |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    cond do
      MapSet.size(unique_hashes) != length(hashed) ->
        publish_batch_double_spend(hashed)
        {:error, :double_spend}

      not all_hashes_new?(hashed) ->
        publish_batch_double_spend_for_existing(hashed)
        {:error, :double_spend}

      true ->
        # Insert into pending table ONLY (no backend, no main table)
        Enum.each(hashed, fn {hash, keyset_id} ->
          :ets.insert(@pending_table, {hash, keyset_id, now})
        end)

        :ok
    end
  end

  defp all_hashes_new?(hashed) do
    Enum.all?(hashed, fn {hash, _keyset_id} ->
      not :ets.member(@table, hash) and not :ets.member(@pending_table, hash)
    end)
  end

  defp commit_reserved_batch(entries, state) do
    now = System.monotonic_time()

    hashed =
      Enum.map(entries, fn {secret, keyset_id} ->
        {hash_secret(secret), keyset_id, secret}
      end)

    # Pre-compute Y entries for all secrets BEFORE any mutation
    case compute_y_entries_strict(hashed) do
      {:ok, y_entries} ->
        do_commit_reserved(hashed, now, y_entries, state)

      {:error, _} = err ->
        err
    end
  end

  defp do_commit_reserved(hashed, now, y_entries, state) do
    # Backend batch write+sync for durability (C3: includes Y-index entries)
    main_backend_entries =
      Enum.map(hashed, fn {hash, keyset_id, _secret} ->
        {hash, {keyset_id, now}}
      end)

    y_backend_entries =
      Enum.map(y_entries, fn {y, keyset_id, ts} ->
        {{:y, y}, {keyset_id, ts}}
      end)

    backend_entries = main_backend_entries ++ y_backend_entries

    case backend_batch_write_sync(state.backend_ref, state.backend, backend_entries) do
      :ok ->
        # Promote to main ETS, then remove from pending.
        Enum.each(hashed, fn {hash, keyset_id, _secret} ->
          :ets.insert(@table, {hash, keyset_id, now})
          :ets.delete(@pending_table, hash)
        end)

        # INVARIANT: Y-index inserted ONLY after primary hash is
        # durably persisted and promoted to main ETS.
        Enum.each(y_entries, &insert_y/1)
        :ok

      {:error, :backend_write_failed} ->
        # FAIL-SAFE: keep entries in pending table to prevent re-spending.
        # In the melt flow, this runs AFTER Lightning payment has settled.
        # Deleting pending entries would allow tokens to be spent again
        # while the mint has already paid out — direct fund loss.
        Logger.error(
          "Spent: backend write failed during commit — " <>
            "entries remain in pending table for safety"
        )

        :telemetry.execute(
          [:minted, :spent_set, :commit_failure],
          %{count: length(hashed)},
          %{}
        )

        :telemetry.execute(
          [:minted, :spent, :backend_commit_failure],
          %{count: length(hashed)},
          %{}
        )

        {:error, :storage_failure}
    end
  end

  defp batch_insert_or_rollback(entries, state) do
    now = System.monotonic_time()

    hashed =
      Enum.map(entries, fn {secret, keyset_id} ->
        {hash_secret(secret), keyset_id, secret}
      end)

    # Reject batches with intra-batch duplicate secrets.
    unique_hashes = hashed |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    if MapSet.size(unique_hashes) != length(hashed) do
      publish_batch_double_spend(Enum.map(hashed, fn {h, k, _s} -> {h, k} end))
      {:error, :double_spend}
    else
      do_batch_insert(hashed, now, state)
    end
  end

  defp do_batch_insert(hashed, now, state) do
    # Pre-compute Y entries for all secrets BEFORE any mutation
    case compute_y_entries_strict(hashed) do
      {:ok, y_entries} ->
        do_batch_insert_with_y(hashed, now, y_entries, state)

      {:error, _} = err ->
        err
    end
  end

  defp do_batch_insert_with_y(hashed, now, y_entries, state) do
    # Check all hashes for double-spend via ETS + pending (Issue #4)
    all_new? =
      Enum.all?(hashed, fn {hash, _keyset_id, _secret} ->
        not :ets.member(@table, hash) and not :ets.member(@pending_table, hash)
      end)

    if all_new? do
      persist_and_index_batch(hashed, now, y_entries, state)
    else
      publish_batch_double_spend_for_existing(Enum.map(hashed, fn {h, k, _s} -> {h, k} end))
      {:error, :double_spend}
    end
  end

  defp persist_and_index_batch(hashed, now, y_entries, state) do
    # Backend batch write FIRST for durability — no pending-table window.
    main_backend_entries =
      Enum.map(hashed, fn {hash, keyset_id, _secret} ->
        {hash, {keyset_id, now}}
      end)

    y_backend_entries =
      Enum.map(y_entries, fn {y, keyset_id, ts} ->
        {{:y, y}, {keyset_id, ts}}
      end)

    backend_entries = main_backend_entries ++ y_backend_entries

    case backend_batch_write_sync(state.backend_ref, state.backend, backend_entries) do
      :ok ->
        # Insert directly into main ETS (skip @pending_table entirely)
        Enum.each(hashed, fn {hash, keyset_id, _secret} ->
          :ets.insert(@table, {hash, keyset_id, now})
        end)

        # INVARIANT: Y-index inserted ONLY after primary hash is
        # durably persisted and in main ETS.
        Enum.each(y_entries, &insert_y/1)
        :ok

      {:error, :backend_write_failed} ->
        {:error, :storage_failure}
    end
  end

  # --- Startup safety helpers ---

  defp promote_pending_to_main(state) do
    pending_entries = :ets.tab2list(@pending_table)

    if pending_entries != [] do
      # Deduplicate against main table to prevent double-counting
      new_entries =
        Enum.reject(pending_entries, fn {hash, _keyset_id, _ts} ->
          :ets.member(@table, hash)
        end)

      if new_entries != [] do
        Logger.warning(
          "Spent: promoting #{length(new_entries)} pending entries to main table " <>
            "(#{length(pending_entries) - length(new_entries)} already in main) " <>
            "— these represent in-flight payments that may have settled"
        )

        backend_entries =
          Enum.map(new_entries, fn {hash, keyset_id, ts} ->
            :ets.insert(@table, {hash, keyset_id, ts})
            {hash, {keyset_id, ts}}
          end)

        # Persistence is mandatory for promoted entries. Previous
        # behaviour was log-only, which meant the promoted entries
        # lived in ETS but not in the backend — a restart would drop
        # them and the tokens they represent could be respent. We
        # now halt: refusing to boot beats booting into a state where
        # the double-spend guard is silently degraded.
        case persist_batch(state, backend_entries) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Spent: failed to persist promoted entries, halting to prevent double-spend on next boot, " <>
                "count=#{length(backend_entries)}, reason=#{inspect(reason)}"
            )

            _ = safe_set_halted("spent_promotion_persistence_failed")
            raise "Spent: pending-promotion persistence failed (#{inspect(reason)})"
        end
      end

      :telemetry.execute(
        [:minted, :spent_set, :pending_promoted],
        %{count: length(pending_entries)},
        %{}
      )
    end

    :ets.delete_all_objects(@pending_table)
  end

  defp load_recovery_blocked_hashes(state) do
    path = StorageFacade.recovery_blocked_hashes_path()

    hashes =
      case File.read(path) do
        {:ok, data} ->
          try do
            case :erlang.binary_to_term(data, [:safe]) do
              list when is_list(list) -> list
              _ -> nil
            end
          rescue
            _ -> nil
          end

        {:error, :enoent} ->
          nil

        {:error, reason} ->
          Logger.warning("Spent: failed to read recovery blocked hashes file: #{inspect(reason)}")
          nil
      end

    # Fall back to Application env (set by Recovery if file write failed)
    hashes = hashes || Application.get_env(:minted, :recovery_blocked_hashes)

    case hashes do
      nil ->
        :ok

      hashes when is_list(hashes) ->
        now = System.monotonic_time()

        backend_entries =
          Enum.map(hashes, fn {hash, keyset_id} ->
            :ets.insert_new(@table, {hash, keyset_id, now})
            {hash, {keyset_id, now}}
          end)

        persist_batch_best_effort(state, backend_entries, "recovery hashes")

        Logger.warning("Spent: blocked #{length(hashes)} token hashes from incomplete melt recovery")

        :telemetry.execute(
          [:minted, :spent_set, :recovery_blocked],
          %{count: length(hashes)},
          %{}
        )

        # Clean up both sources
        File.rm(path)
        Application.delete_env(:minted, :recovery_blocked_hashes)
    end
  end

  # Strict persistence — returns :ok or {:error, reason}. Used for
  # promoted pending entries where failure means double-spend risk.
  defp persist_batch(%{backend_ref: nil}, _entries), do: :ok
  defp persist_batch(_state, []), do: :ok

  defp persist_batch(state, entries) do
    state.backend.put_batch_sync(state.backend_ref, entries)
  end

  defp persist_batch_best_effort(%{backend_ref: nil}, _entries, _label), do: :ok
  defp persist_batch_best_effort(_state, [], _label), do: :ok

  defp persist_batch_best_effort(state, entries, label) do
    case state.backend.put_batch_sync(state.backend_ref, entries) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:minted, :spent_set, :persist_failure],
          %{count: length(entries)},
          %{label: label, reason: reason}
        )

        Logger.error(
          "Spent: failed to persist #{label}: #{inspect(reason)} — " <>
            "entries are in ETS but not durable"
        )
    end
  end

  # --- Backend helpers ---

  # Wraps StorageFacade.open_spent_set_backend/0 with the Mint-specific
  # fallback policy: in :prod we refuse to start without persistence
  # because that would silently open a double-spend window, but in dev
  # and test we keep running with an in-memory-only backend and a
  # warning so the suite doesn't need a real disk.
  defp open_spent_set_backend_or_fallback do
    case StorageFacade.open_spent_set_backend() do
      {:ok, {backend_mod, ref}} ->
        {backend_mod, ref}

      {:error, {backend_mod, reason}} ->
        env = Application.get_env(:minted, :env, :dev)

        if env == :prod do
          raise "Spent: backend init failed in production: #{inspect(reason)}. " <>
                  "Cannot start without persistent spent set — double-spend risk."
        else
          Logger.warning("Spent: backend init failed: #{inspect(reason)}, running without persistence (#{env} mode)")

          {backend_mod, nil}
        end
    end
  end

  defp load_backend_into_ets(_mod, nil), do: :ok

  defp load_backend_into_ets(mod, ref) do
    entries = mod.load_all(ref)

    # Rebuild BOTH the main table AND the Y-index from backend.
    # Y-index entries are stored with {:y, y_binary} keys.
    {y_entries, main_entries} =
      Enum.split_with(entries, fn
        {{:y, _y}, _value} -> true
        _ -> false
      end)

    Enum.each(main_entries, fn {hash, {keyset_id, ts}} ->
      :ets.insert_new(@table, {hash, keyset_id, ts})
    end)

    Enum.each(y_entries, fn {{:y, y}, {keyset_id, ts}} ->
      :ets.insert_new(@y_table, {y, keyset_id, ts})
    end)

    main_count = length(main_entries)
    y_count = length(y_entries)

    if main_count > 0 do
      Logger.info("Spent: loaded from backend, entries=#{main_count}, y_index=#{y_count}")
    end
  end

  defp backend_write_sync(nil, _mod, _hash, _value, _y_entry), do: :ok

  defp backend_write_sync(ref, mod, hash, value, y_backend_entry) do
    # Write main entry + Y-index entry in a single batch+sync.
    entries = [{hash, value} | y_backend_entries_list(y_backend_entry)]

    case mod.put_batch_sync(ref, entries) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Spent: backend write+sync failed: #{inspect(reason)}")
        {:error, :backend_write_failed}
    end
  end

  defp backend_batch_write_sync(nil, _mod, _entries), do: :ok

  defp backend_batch_write_sync(ref, mod, entries) do
    case mod.put_batch_sync(ref, entries) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Spent: backend batch write+sync failed: #{inspect(reason)}")
        {:error, :backend_write_failed}
    end
  end

  # --- ETS compaction helpers ---

  defp remove_keyset_from_ets(keyset_id) do
    # Match Spent entry format: {secret_hash, keyset_id, timestamp}
    before = :ets.info(@table, :size) || 0
    :ets.match_delete(@table, {:_, keyset_id, :_})
    after_count = :ets.info(@table, :size) || 0
    removed = max(before - after_count, 0)

    # Also prune the Y-index table.
    :ets.match_delete(@y_table, {:_, keyset_id, :_})

    removed
  end

  # --- Y-index backend helpers ---

  defp y_result_to_backend_entry({:ok, {y, keyset_id, ts}}), do: {{:y, y}, {keyset_id, ts}}
  defp y_result_to_backend_entry({:error, _}), do: nil

  defp y_backend_entries_list(nil), do: []
  defp y_backend_entries_list(entry), do: [entry]

  # --- Crypto helpers ---

  defp compute_y_entry(secret, keyset_id) do
    case Cashew.hash_to_curve(secret) do
      {:ok, y} -> {:ok, {y, keyset_id, System.monotonic_time()}}
      {:error, reason} -> {:error, {:hash_to_curve_failed, reason}}
    end
  end

  defp insert_y({y, keyset_id, ts}), do: :ets.insert(@y_table, {y, keyset_id, ts})

  # Single-entry path: a Y-index failure never fails the mark_spent —
  # the spend is already durable by the time this runs. Strict failure
  # applies only to the batch path, which computes Y BEFORE any mutation.
  defp insert_y_or_warn({:ok, entry}, _keyset_id) do
    insert_y(entry)
    :ok
  end

  defp insert_y_or_warn({:error, reason}, keyset_id) do
    Logger.error("Spent: Y-index computation failed for keyset #{keyset_id}: #{inspect(reason)}")

    :telemetry.execute(
      [:minted, :spent_set, :y_computation_failed],
      %{count: 1},
      %{keyset_id: keyset_id}
    )

    :ok
  end

  # Batch path: compute all Y entries, fail if any computation fails
  defp compute_y_entries_strict(hashed) do
    results =
      Enum.map(hashed, fn {_hash, keyset_id, secret} ->
        compute_y_entry(secret, keyset_id)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        {:ok, Enum.map(results, fn {:ok, entry} -> entry end)}

      {:error, reason} ->
        failed_count = Enum.count(results, &match?({:error, _}, &1))

        Logger.error("Spent: hash_to_curve failed for #{failed_count} entries: #{inspect(reason)}")

        :telemetry.execute(
          [:minted, :spent_set, :y_computation_failed],
          %{count: failed_count},
          %{}
        )

        {:error, :y_computation_failed}
    end
  end

  defp check_overloaded do
    case Process.info(Process.whereis(__MODULE__), :message_queue_len) do
      {:message_queue_len, len} when len > @max_queue_depth ->
        :telemetry.execute([:minted, :spent_set, :overloaded], %{queue_depth: len}, %{})
        {:error, :overloaded}

      _ ->
        :ok
    end
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
  end

  defp publish_double_spend(secret_hash, keyset_id) do
    EventBus.publish(%MintEvents.DoubleSpendDetected{
      secret_hash: secret_hash,
      keyset_id: keyset_id,
      timestamp: DateTime.utc_now()
    })
  rescue
    _ -> :ok
  end

  # Batch attacks (reserve_batch, batch_insert_or_rollback) never
  # emitted DoubleSpendDetected — single-hash mark_spent was the only
  # publisher. Batches are how real double-spend attempts arrive (a
  # spammer sends N tokens hoping for a race), so a silent batch was
  # a straight observability blind spot.
  defp publish_batch_double_spend(hashed) do
    Enum.each(hashed, fn {hash, keyset_id} ->
      publish_double_spend(hash, keyset_id)
    end)
  end

  defp publish_batch_double_spend_for_existing(hashed) do
    # Publish only for the hashes that ACTUALLY collide (rather than
    # every hash in the failed batch) — an event stream cluttered
    # with the batch's clean entries dilutes the signal.
    Enum.each(hashed, fn {hash, keyset_id} ->
      if :ets.member(@table, hash) or :ets.member(@pending_table, hash) do
        publish_double_spend(hash, keyset_id)
      end
    end)
  end

  # Set the system halt without exploding if the health GenServer
  # isn't running (test env with skip_lightning_children, early boot,
  # etc). The raise that follows is the load-bearing failure signal;
  # the halt flag is best-effort operator visibility.
  defp safe_set_halted(reason) when is_binary(reason) do
    Minted.Telemetry.Facade.set_halted(reason)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
