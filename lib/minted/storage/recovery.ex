defmodule Minted.Storage.Recovery do
  @moduledoc """
  Crash recovery module.

  Executes on startup to restore consistent state after a crash.
  Uses a multi-level recovery hierarchy:

  1. **Level 1 - WAL**: Replay uncommitted WAL entries
  2. **Level 2 - DETS**: Rebuild from cold tier DETS files
  3. **Halt**: Stop with instructions for manual backup restore

  Backups are managed externally via a cron-driven shell script that
  copies the storage directory. Restore is `cp -r` of the backup
  followed by a service restart.

  Recovery is idempotent — running it twice produces the same result.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Storage, as: StorageEvents
  alias Minted.Reserves.Facade, as: ReservesFacade
  alias Minted.Storage.Paths
  alias Minted.Storage.Recovery.Verifier
  alias Minted.Telemetry.Facade, as: TelemetryFacade

  # Types written through Storage.Facade.write_wal/2 by concurrent
  # callers (controllers, services, lightning adapter). The Facade
  # owns one global `:atomics` counter for all of these.
  @facade_owned_types ~w(
    melt_started melt_settled
    swap_started swap_settled swap_failed
    tokens_minted tokens_burned fees_collected
    proof_spent proof_stored
    payments_in_flight
    epoch_advanced
    house_withdrawal_requested house_withdrawal_completed house_withdrawal_rejected
  )a

  # Per-store types — each owning GenServer holds its own counter
  # in state and rebuilds from its own replay. Listed only so the
  # monotonic check can flag regressions per type.
  @per_store_types ~w(
    keyset_created keyset_rotated keyset_expired
    wallet_tokens_stored wallet_tokens_removed wallet_tokens_swapped
    wallet_activity_added
  )a

  @doc """
  Runs the 9-step recovery procedure.

  Returns `{:ok, report}` on successful recovery or `{:error, reason}` if
  recovery fails at all levels.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    wal_dir =
      Keyword.get_lazy(opts, :wal_dir, fn ->
        Paths.storage_wal()
      end)

    Logger.info("Recovery: starting crash recovery procedure...")

    # On a fresh install (no WAL, no DETS, no backups), there is nothing to
    # recover. Detect this early and return success with a clean slate instead
    # of cascading through all recovery levels and ultimately crashing.
    if fresh_install?(wal_dir) do
      Logger.info("Recovery: fresh install detected — no data to recover, starting with clean state")
      File.mkdir_p(wal_dir)

      report = %{
        level: 0,
        wal_dir: wal_dir,
        replayed_count: 0,
        fresh: true,
        elapsed_ms: System.monotonic_time(:millisecond) - start_time
      }

      {:ok, report}
    else
      result =
        with {:ok, report} <- check_wal_dir(wal_dir),
             {:ok, report} <- scan_segments(wal_dir, report),
             {:ok, report} <- detect_data_loss(report),
             {:ok, report} <- verify_entries(report),
             {:ok, report} <- find_uncommitted(report),
             {:ok, report} <- verify_spent_backend(report),
             {:ok, report} <- replay_uncommitted(report),
             {:ok, report} <- rebuild_ets(report),
             {:ok, report} <- verify_consistency(report),
             {:ok, report} <- log_summary(report, start_time) do
          publish_recovery_event(report)
        else
          {:error, reason} ->
            Logger.warning("Recovery: level 1 (WAL) recovery failed: #{inspect(reason)}")
            attempt_dets_recovery(wal_dir, start_time)
        end

      result
    end
  end

  # --- Fresh Install Detection ---

  defp fresh_install?(wal_dir) do
    data_dir = Paths.base_dir()
    backup_dir = Paths.backups()

    no_wal = not File.dir?(wal_dir) or dir_empty?(wal_dir)
    no_dets = not File.dir?(data_dir) or no_dets_files?(data_dir)
    no_backups = not File.dir?(backup_dir) or dir_empty?(backup_dir)

    no_wal and no_dets and no_backups
  end

  defp dir_empty?(path) do
    case File.ls(path) do
      {:ok, files} -> Enum.all?(files, &String.ends_with?(&1, ".corrupt"))
      _ -> false
    end
  end

  defp no_dets_files?(data_dir) do
    Path.wildcard(Path.join(data_dir, "**/*.dets")) == []
  end

  # --- Step Implementations ---

  defp check_wal_dir(wal_dir) do
    Logger.debug("Recovery: checking WAL directory, path=#{wal_dir}")

    if File.dir?(wal_dir) do
      {:ok, %{wal_dir: wal_dir, level: 1}}
    else
      case File.mkdir_p(wal_dir) do
        :ok -> {:ok, %{wal_dir: wal_dir, level: 1, fresh: true}}
        {:error, _} -> {:error, :wal_dir_not_found}
      end
    end
  end

  defp scan_segments(wal_dir, report) do
    Logger.debug("Recovery: step 2 — scanning WAL segments")

    case Verifier.verify(wal_dir) do
      {:ok, wal_report} ->
        if wal_report.total_entries == 0 and wal_report.segments == [] do
          {:ok, Map.merge(report, %{wal_report: wal_report, fresh: true})}
        else
          {:ok, Map.put(report, :wal_report, wal_report)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Detect data loss: WAL is empty/missing but backups exist on disk.
  # This means the WAL was destroyed (or never restored) but prior state
  # exists. Fall through to Level 3 (backup restore) instead of continuing
  # with an empty WAL that would cause a fresh keyset to be generated,
  # orphaning all existing tokens.
  defp detect_data_loss(report) do
    wal_report = Map.get(report, :wal_report, %{})
    wal_empty = Map.get(report, :fresh, false) or Map.get(wal_report, :total_entries, 1) == 0

    if wal_empty and backups_exist?() do
      Logger.warning(
        "Recovery: WAL has no entries but backups exist — data loss detected, " <>
          "falling through to backup restore"
      )

      {:error, :data_loss_detected}
    else
      {:ok, report}
    end
  end

  defp backups_exist? do
    backup_dir = Paths.backups()

    case File.ls(backup_dir) do
      {:ok, files} ->
        Enum.any?(files, &(String.starts_with?(&1, "backup-") and String.ends_with?(&1, ".bak")))

      _ ->
        false
    end
  end

  defp verify_entries(report) do
    Logger.debug("Recovery: step 3 — verifying WAL entry CRC32 checksums")

    wal_report = Map.get(report, :wal_report, %{corrupt_entries: 0, segments: []})

    if wal_report.corrupt_entries > 0 do
      handle_corrupt_entries(wal_report)
    else
      {:ok, report}
    end
  end

  # A corrupt WAL entry on disk means in-memory state will diverge
  # from the durable record on next replay. The doc invariant is
  # "halt on corruption rather than skipping silently"; default
  # behaviour now matches. The :wal halt_on_corrupt flag exists for
  # dev/test fixtures that intentionally exercise the skip path.
  defp handle_corrupt_entries(wal_report) do
    if halt_on_corrupt?() do
      paths = Enum.map(wal_report.segments, & &1.path)

      raise "Recovery: refusing to continue, corrupt_entries=#{wal_report.corrupt_entries}, " <>
              "segments=#{inspect(paths)}. Investigate before forcing skip via " <>
              ":minted, :wal, halt_on_corrupt: false."
    else
      Logger.warning("Recovery: skipping corrupt entries, count=#{wal_report.corrupt_entries}")

      wal_report.segments
      |> Enum.filter(&(&1.corrupt_entries > 0))
      |> Enum.each(&Verifier.quarantine(&1.path))

      {:ok, %{wal_report: wal_report}}
    end
  end

  defp halt_on_corrupt? do
    Application.get_env(:minted, :wal, [])
    |> Keyword.get(:halt_on_corrupt, true)
  end

  # WAL entry types that imply the spent set must be non-empty: any
  # past redemption, melt, or swap means proofs were burned, so the
  # double-spend guard must hold entries.
  @spent_implying_types [
    :tokens_burned,
    :melt_started,
    :melt_settled,
    :swap_started,
    :swap_settled,
    :proof_spent
  ]

  # A spent-set backend that opens missing while the WAL carries
  # redemption history means the restore was incomplete — the spent_set
  # directory didn't make it into the backup. Booting anyway would
  # resurrect every redeemed token: a full-history double-spend window
  # with no error and no telemetry. Fail into manual recovery so the
  # operator restores the missing directory first.
  defp verify_spent_backend(report) do
    entries = Map.get(report, :all_entries, [])

    case spent_guard_verdict(entries, spent_backend_missing?()) do
      :ok ->
        {:ok, report}

      {:error, _} = err ->
        Logger.error(
          "Recovery: WAL history implies a non-empty spent set, but the spent-set " <>
            "backend is missing — incomplete restore, refusing to boot without the " <>
            "double-spend guard"
        )

        err
    end
  end

  @doc false
  # Pure decision, split out for unit tests: the guard must hold
  # entries whenever WAL history shows past redemption activity.
  def spent_guard_verdict(entries, backend_missing?) do
    if backend_missing? and Enum.any?(entries, &(&1.type in @spent_implying_types)) do
      {:error, :spent_set_missing}
    else
      :ok
    end
  end

  # Filesystem-level probe (the backend itself opens later, under
  # Mint.Spent). Missing directory / missing data files = missing.
  # A present-but-empty store is NOT missing — a mint that never
  # redeemed anything has legitimately empty files.
  defp spent_backend_missing? do
    backend =
      Application.get_env(:minted, :spent_set_backend, Minted.Storage.Backends.CubDB)

    case backend do
      Minted.Storage.Backends.DETS ->
        path = Paths.mint_spent_set_dets()
        not File.exists?(path)

      _cubdb ->
        dir = Paths.mint_spent_set()
        not File.dir?(dir) or Path.wildcard(Path.join(dir, "*.cubdb")) == []
    end
  end

  defp find_uncommitted(report) do
    Logger.debug("Recovery: step 4 — identifying uncommitted entries")

    wal_report = Map.get(report, :wal_report, %{segments: []})

    all_entries =
      wal_report.segments
      |> Enum.flat_map(& &1.entries)

    sorted = sort_by_seq(all_entries)

    facade_max_seq = max_seq_for_types(sorted, @facade_owned_types)
    check_per_type_monotonic(sorted)

    # Restore the Facade-mediated seq counter so concurrent writers
    # (controllers, services, adapters) continue from one past the
    # highest facade-owned seq observed on disk. Per-domain Stores
    # rebuild their own counters during their own init/replay.
    if facade_max_seq > 0 do
      Minted.Storage.Facade.restore_seq_ref(facade_max_seq)
      Logger.debug("Recovery: facade seq_ref restored, next_seq=#{facade_max_seq + 1}")
    end

    uncommitted = Verifier.find_uncommitted(sorted)

    {:ok,
     report
     |> Map.put(:uncommitted_entries, uncommitted)
     |> Map.put(:all_entries, sorted)
     |> Map.put(:facade_max_seq, facade_max_seq)}
  end

  defp sort_by_seq(entries) do
    entries
    |> Enum.with_index()
    |> Enum.sort_by(fn {entry, idx} -> {entry_seq(entry), idx} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp max_seq_for_types(entries, types) do
    Enum.reduce(entries, 0, fn entry, acc ->
      if entry.type in types, do: max(acc, entry_seq(entry)), else: acc
    end)
  end

  defp entry_seq(%{payload: %{seq: seq}}) when is_integer(seq), do: seq
  defp entry_seq(_), do: 0

  # Each owning writer (Facade or per-Store GenServer) increments its
  # own counter strictly. A regression within a type means the WAL was
  # reordered or rotated mid-write. Log and continue — replay still
  # follows global seq+index order.
  defp check_per_type_monotonic(sorted_entries) do
    sorted_entries
    |> Enum.group_by(& &1.type)
    |> Enum.each(fn {type, entries} ->
      seqs = Enum.map(entries, &entry_seq/1)
      anomalies = count_seq_regressions(seqs)

      cond do
        anomalies == 0 ->
          :ok

        type in @per_store_types or type in @facade_owned_types ->
          Logger.warning("Recovery: per-type seq regression, type=#{type} count=#{anomalies}")

        true ->
          Logger.debug("Recovery: untracked type seq anomaly, type=#{type} count=#{anomalies}")
      end
    end)
  end

  defp count_seq_regressions([]), do: 0
  defp count_seq_regressions([_]), do: 0

  defp count_seq_regressions([first | rest]) do
    {count, _last} =
      Enum.reduce(rest, {0, first}, fn s, {count, prev} ->
        if s <= prev, do: {count + 1, s}, else: {count, s}
      end)

    count
  end

  defp replay_uncommitted(report) do
    Logger.debug("Recovery: step 5 — replaying uncommitted entries")

    # Reconcile liability and fee counters against the WAL on every
    # restart, not only when DETS is empty.
    #
    # `Locker.Counter.increment` is DETS-without-sync plus ETS; the
    # 5 s sync timer means a VM crash can lose the tail of increments
    # while the WAL (write+fsync per entry) does not. The old "only
    # rebuild if all counters are 0" gate meant real crashes stayed
    # invisible forever — direction of drift: liability UNDERSTATED,
    # so an insolvency window would go unflagged.
    #
    # Mirror the House.Store pattern: take max(WAL_sum, current DETS)
    # per counter. WAL > DETS → recover lost writes. DETS > WAL → WAL
    # rotation dropped old entries, keep the DETS value; the operator
    # is responsible for snapshotting counters before rotating WAL.
    all_entries = Map.get(report, :all_entries, [])
    reconcile_liability_counters(all_entries)

    uncommitted = Map.get(report, :uncommitted_entries, [])

    # Thread incomplete melt/swap accumulators plus the blocked-hash
    # list through the replay loop instead of using the Process
    # dictionary (not safe for concurrent recovery).
    initial_acc = {0, [], %{}, %{}, []}

    {replayed, failures, incomplete_melts, incomplete_swaps, replay_blocked} =
      Enum.reduce(uncommitted, initial_acc, fn entry, {count, fails, melts, swaps, blocked} ->
        case replay_entry(entry, melts, swaps, blocked) do
          {:ok, melts, swaps, blocked} ->
            {count + 1, fails, melts, swaps, blocked}

          {:error, reason} ->
            Logger.warning("Recovery: failed to replay entry #{inspect(entry.type)}: #{inspect(reason)}")
            {count, [{entry.type, reason} | fails], melts, swaps, blocked}
        end
      end)

    Logger.info("Recovery: replayed #{replayed} of #{length(uncommitted)} uncommitted WAL entries")

    report =
      report
      |> Map.put(:replayed_count, replayed)
      |> Map.put(:replay_failures, Enum.reverse(failures))
      |> Map.put(:replay_complete, failures == [])
      |> Map.put(:_incomplete_melts, incomplete_melts)
      |> Map.put(:_incomplete_swaps, incomplete_swaps)
      |> Map.put(:_replay_blocked_hashes, replay_blocked)

    # Q8: Propagate replay failures so higher-level recovery can attempt fallback.
    if failures == [] do
      {:ok, report}
    else
      Logger.warning("Recovery: #{length(failures)} replay failure(s), falling back to next level")

      {:error, {:replay_failures, report}}
    end
  end

  defp replay_entry(entry, incomplete_melts, incomplete_swaps, blocked) do
    case entry do
      %{type: :melt_started, payload: payload} ->
        Logger.debug("Recovery: replaying melt_started")
        {:ok, melts, swaps} = dispatch_replay(:melt_started, payload, incomplete_melts, incomplete_swaps)
        {:ok, melts, swaps, blocked}

      %{type: :melt_settled, payload: payload} ->
        Logger.debug("Recovery: replaying melt_settled")
        {:ok, melts, swaps} = dispatch_replay(:melt_settled, payload, incomplete_melts, incomplete_swaps)
        {:ok, melts, swaps, blocked}

      %{type: :swap_started, payload: payload} ->
        Logger.debug("Recovery: replaying swap_started")
        {:ok, melts, swaps} = dispatch_replay(:swap_started, payload, incomplete_melts, incomplete_swaps)
        {:ok, melts, swaps, blocked}

      %{type: :swap_settled, payload: payload} ->
        Logger.debug("Recovery: replaying swap_settled")
        {:ok, melts, swaps} = dispatch_replay(:swap_settled, payload, incomplete_melts, incomplete_swaps)
        {:ok, melts, swaps, blocked}

      %{type: :epoch_advanced} ->
        # Legacy WAL entry type — no longer produced, safe to skip.
        {:ok, incomplete_melts, incomplete_swaps, blocked}

      %{type: :keyset_created, payload: payload} ->
        Logger.debug("Recovery: replaying keyset_created")
        dispatch_replay(:keyset_created, payload)
        {:ok, incomplete_melts, incomplete_swaps, blocked}

      %{type: type, payload: payload} ->
        Logger.debug("Recovery: replaying entry, type=#{type}")

        # Propagate dispatch failures — the previous shape discarded
        # them, which turned a failed :proof_spent re-mark into a
        # silent no-op while the report claimed success.
        case dispatch_replay(type, payload) do
          :ok ->
            {:ok, incomplete_melts, incomplete_swaps, blocked}

          {:blocked, hash_entry} ->
            {:ok, incomplete_melts, incomplete_swaps, [hash_entry | blocked]}

          {:error, _} = err ->
            err
        end

      _ ->
        {:ok, incomplete_melts, incomplete_swaps, blocked}
    end
  rescue
    e ->
      Logger.warning("Recovery: replay_entry failed: #{inspect(e)}")
      {:error, e}
  end

  # Liability counters are rebuilt in bulk by reconcile_liability_counters/1
  # before uncommitted replay, so individual dispatch is a no-op.
  defp dispatch_replay(:tokens_minted, _payload), do: :ok
  defp dispatch_replay(:tokens_burned, _payload), do: :ok
  # Fee counters are rebuilt in bulk by reconcile_liability_counters/1.
  defp dispatch_replay(:fees_collected, _payload), do: :ok

  defp dispatch_replay(:payments_in_flight, payload) do
    count = payload |> Map.get(:payments, []) |> length()
    Logger.warning("Recovery: #{count} payments were in-flight at previous shutdown")
    :ok
  rescue
    e ->
      Logger.error("Recovery: dispatch :payments_in_flight failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :payments_in_flight, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :payments_in_flight exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :payments_in_flight, reason}}
  end

  defp dispatch_replay(:proof_spent, payload) do
    secret = Map.get(payload, :secret)
    keyset_id = Map.get(payload, :keyset_id, "recovery")

    if is_binary(secret) do
      # Mint.Spent is not started yet when recovery runs — queue the hash
      # into the blocked set that Spent loads on startup.
      {:blocked, {:crypto.hash(:sha256, secret), keyset_id}}
    else
      # A proof_spent entry without a binary secret is corrupt — fail
      # the replay loudly rather than silently skip it.
      {:error, {:dispatch_failed, :proof_spent, :malformed_secret}}
    end
  rescue
    e ->
      Logger.error("Recovery: dispatch :proof_spent failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :proof_spent, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :proof_spent exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :proof_spent, reason}}
  end

  defp dispatch_replay(:proof_stored, _payload), do: :ok

  defp dispatch_replay(_type, _payload), do: :ok

  # Melt/swap tracking uses explicit accumulators threaded through the replay
  # loop instead of the Process dictionary (safe for concurrent recovery).

  defp dispatch_replay(:melt_started, payload, incomplete_melts, incomplete_swaps) do
    key = melt_join_key(payload)
    amount = Map.get(payload, :amount, 0)

    Logger.warning("Recovery: melt was in progress at crash, key=#{inspect(key)}, amount=#{amount}")

    {:ok, Map.put(incomplete_melts, key, payload), incomplete_swaps}
  rescue
    e ->
      Logger.error("Recovery: dispatch :melt_started failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :melt_started, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :melt_started exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :melt_started, reason}}
  end

  defp dispatch_replay(:melt_settled, payload, incomplete_melts, incomplete_swaps) do
    key = melt_join_key(payload)

    if melt_settled_commit_failed?(payload) do
      Logger.error(
        "Recovery: melt settled but commit failed, blocking hashes on next boot, " <>
          "key=#{inspect(key)}"
      )

      {:ok, incomplete_melts, incomplete_swaps}
    else
      Logger.info("Recovery: melt completed, key=#{inspect(key)}")
      {:ok, Map.delete(incomplete_melts, key), incomplete_swaps}
    end
  rescue
    e ->
      Logger.error("Recovery: dispatch :melt_settled failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :melt_settled, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :melt_settled exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :melt_settled, reason}}
  end

  defp dispatch_replay(:swap_started, payload, incomplete_melts, incomplete_swaps) do
    key = swap_join_key(payload)
    amount = Map.get(payload, :amount, 0)
    Logger.warning("Recovery: swap was in progress at crash — amount=#{amount}")

    {:ok, incomplete_melts, Map.put(incomplete_swaps, key, payload)}
  rescue
    e ->
      Logger.error("Recovery: dispatch :swap_started failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :swap_started, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :swap_started exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :swap_started, reason}}
  end

  defp dispatch_replay(:swap_settled, payload, incomplete_melts, incomplete_swaps) do
    key = swap_join_key(payload)

    {:ok, incomplete_melts, Map.delete(incomplete_swaps, key)}
  rescue
    e ->
      Logger.error("Recovery: dispatch :swap_settled failed: #{inspect(e)}")
      {:error, {:dispatch_failed, :swap_settled, e}}
  catch
    :exit, reason ->
      Logger.error("Recovery: dispatch :swap_settled exited: #{inspect(reason)}")
      {:error, {:dispatch_failed, :swap_settled, reason}}
  end

  # Swaps join on the random swap_id written at swap start (present in
  # both swap_started and swap_settled). Legacy entries fall back to
  # quote_id, then :unknown — the last-resort key collapses concurrent
  # legacy swaps into one, which is the best that can be done for data
  # written before swap_id existed.
  defp swap_join_key(payload) do
    Map.get(payload, :swap_id) || Map.get(payload, :quote_id) || :unknown
  end

  # Wallet-initiated melts have no quote_id — they mint no Cashu quote,
  # they just spend tokens on Lightning directly — so joining
  # :melt_started ↔ :melt_settled on quote_id alone would collapse every
  # concurrent wallet melt to a single nil key and let one settlement
  # discard every in-flight melt's blocked-hash payload. Wallet writes
  # a random melt_id per call for exactly this join; API writes quote_id.
  # Fall through to :unknown as a last resort so recovery still runs
  # even on a WAL entry with neither.
  defp melt_join_key(payload) do
    Map.get(payload, :quote_id) || Map.get(payload, :melt_id) || :unknown
  end

  # Per-counter max(WAL, DETS) reconciliation. Called on every boot
  # so a crash between a Locker.Counter.increment and its DETS sync
  # doesn't leave the counter stuck at the pre-crash value.
  defp reconcile_liability_counters(entries) do
    {wal_minted, wal_burned, wal_fees, _seen_quotes} =
      Enum.reduce(entries, {0, 0, 0, MapSet.new()}, &accumulate_liability_entry/2)

    current_minted = ReservesFacade.minted_total()
    current_burned = ReservesFacade.burned_total()
    current_fees = Map.get(ReservesFacade.fee_totals(), :total_collected, 0)

    reconcile_counter(:minted, wal_minted, current_minted, fn delta ->
      ReservesFacade.restore_counters(:minted, delta)
    end)

    reconcile_counter(:burned, wal_burned, current_burned, fn delta ->
      ReservesFacade.restore_counters(:burned, delta)
    end)

    reconcile_counter(:fees, wal_fees, current_fees, fn delta ->
      ReservesFacade.restore_fee_counter(delta)
    end)
  end

  defp reconcile_counter(name, wal_sum, current, apply_delta) do
    cond do
      wal_sum == current ->
        :ok

      wal_sum > current ->
        delta = wal_sum - current
        apply_delta.(delta)

        Logger.info("Recovery: reconciled #{name} counter, wal=#{wal_sum}, dets=#{current}, delta=+#{delta}")

      wal_sum < current ->
        # WAL says less than DETS — either the WAL was rotated (ops
        # convention: snapshot before rotate) or legacy state. Do NOT
        # decrement, or a rotated segment would appear as a fake
        # burn. Log so the operator can investigate.
        Logger.warning(
          "Recovery: #{name} counter exceeds WAL-derived total, keeping counter, " <>
            "counter=#{current}, wal=#{wal_sum}"
        )
    end
  end

  defp accumulate_liability_entry(
         %{type: :tokens_minted, payload: %{amount: amount, quote_id: quote_id}},
         {minted, burned, fees, seen_quotes}
       )
       when is_integer(amount) and amount > 0 and is_binary(quote_id) do
    if MapSet.member?(seen_quotes, quote_id) do
      {minted, burned, fees, seen_quotes}
    else
      {minted + amount, burned, fees, MapSet.put(seen_quotes, quote_id)}
    end
  end

  defp accumulate_liability_entry(
         %{type: :tokens_minted, payload: %{amount: amount}},
         {minted, burned, fees, seen_quotes}
       )
       when is_integer(amount) and amount > 0,
       do: {minted + amount, burned, fees, seen_quotes}

  # Reconciliation burns are idempotent: if Reconciler crashes between
  # the WAL append and Pending.delete, the next sweep will write a
  # second :tokens_burned for the same quote. Dedup by quote_id +
  # reason so replay can't double-count those orphan compensations.
  defp accumulate_liability_entry(
         %{
           type: :tokens_burned,
           payload: %{amount: amount, quote_id: quote_id, reason: :orphaned_deposit}
         },
         {minted, burned, fees, seen_quotes}
       )
       when is_integer(amount) and amount > 0 and is_binary(quote_id) do
    key = {:orphaned_burn, quote_id}

    if MapSet.member?(seen_quotes, key) do
      {minted, burned, fees, seen_quotes}
    else
      {minted, burned + amount, fees, MapSet.put(seen_quotes, key)}
    end
  end

  defp accumulate_liability_entry(
         %{type: :tokens_burned, payload: %{amount: amount}},
         {minted, burned, fees, seen_quotes}
       )
       when is_integer(amount) and amount > 0,
       do: {minted, burned + amount, fees, seen_quotes}

  defp accumulate_liability_entry(
         %{type: :fees_collected, payload: %{amount: amount}},
         {minted, burned, fees, seen_quotes}
       )
       when is_integer(amount) and amount > 0,
       do: {minted, burned, fees + amount, seen_quotes}

  defp accumulate_liability_entry(_entry, acc), do: acc

  if Mix.env() == :test do
    @doc """
    Test-only accessor for the private liability accumulator. Allows
    scenario tests to pin the dedup invariants (orphan-burn dedup,
    concurrent-mint dedup) without standing up a full recovery run.
    """
    def __accumulate_liability_entry__(entry, acc), do: accumulate_liability_entry(entry, acc)

    @doc """
    Test-only accessor for the private melt-replay dispatcher. Lets
    scenario tests exercise the started/settled join key without a
    full WAL round-trip.
    """
    def __dispatch_melt_replay__(type, payload, incomplete_melts, incomplete_swaps) do
      dispatch_replay(type, payload, incomplete_melts, incomplete_swaps)
    end

    @doc """
    Test-only accessor for the replay entry walker. Lets tests drive
    legacy :proof_spent entries and observe the blocked-hash queue.
    """
    def __replay_entry__(entry, incomplete_melts, incomplete_swaps, blocked) do
      replay_entry(entry, incomplete_melts, incomplete_swaps, blocked)
    end
  end

  defp rebuild_ets(report) do
    Logger.debug("Recovery: step 6 — rebuilding ETS tables from WAL entries")

    # ETS tables are rebuilt by their owning GenServers during startup.
    # This step ensures tables exist by checking if key services are running.
    tables_status =
      try do
        [
          {:spent_set, :ets.whereis(Minted.Mint.Spent) != :undefined},
          {:quotes, :ets.whereis(Minted.Mint.Services.Quotes) != :undefined},
          {:invoices, :ets.whereis(Minted.Lightning.Manager) != :undefined}
        ]
      rescue
        e ->
          Logger.warning("Recovery: rebuild_ets failed to check tables: #{inspect(e)}")
          []
      end

    {:ok, Map.put(report, :ets_rebuilt, true) |> Map.put(:tables_status, tables_status)}
  end

  defp verify_consistency(report) do
    Logger.debug("Recovery: step 7 — verifying data consistency")

    consistency =
      try do
        # Cross-check: the core invariant is minted >= burned.
        # Reading both totals from the same source (ETS/DETS via the facade)
        # and comparing them is the simplest verifiable assertion available
        # before the full Reserves supervision tree is started.
        minted = ReservesFacade.minted_total()
        burned = ReservesFacade.burned_total()
        consistent = minted >= burned

        unless consistent do
          Logger.error("Recovery: consistency check FAILED, burned=#{burned}, minted=#{minted}")
        end

        %{minted_total: minted, burned_total: burned, consistent: consistent}
      rescue
        e ->
          Logger.warning("Recovery: consistency check failed: #{inspect(e)}")
          %{consistent: false, error: inspect(e)}
      end

    # Check for incomplete melts (started but never settled before crash).
    # These represent potential fund loss: Lightning payment may have settled
    # but tokens were never burned. Operator must verify payment status.
    incomplete_melts = Map.get(report, :_incomplete_melts, %{})

    report =
      if map_size(incomplete_melts) > 0 do
        Logger.error(
          "Recovery: CRITICAL: #{map_size(incomplete_melts)} incomplete melt(s) detected — " <>
            "Lightning payment may have settled without token burn. " <>
            "Blocking affected tokens as precaution."
        )

        # Collect all secret_hashes from incomplete melts and store them
        # for Spent to block on startup. This prevents token resurrection:
        # the tokens stay marked as spent until an operator confirms whether
        # the Lightning payment actually settled.
        blocked_hashes = collect_incomplete_melt_hashes(incomplete_melts)
        queue_blocked_hashes(blocked_hashes)

        :telemetry.execute(
          [:minted, :recovery, :incomplete_melts],
          %{count: map_size(incomplete_melts)},
          %{quote_ids: Map.keys(incomplete_melts)}
        )

        Map.put(report, :incomplete_melts, incomplete_melts)
      else
        report
      end

    # Check for incomplete swaps (started but never settled before crash).
    # Block the OLD tokens' secret_hashes from being respent — the swap
    # was interrupted between reservation and commit, so those tokens
    # were verified as spendable but never marked spent in the persistent
    # backend. Recovery-blocked hashes let Spent refuse them on next
    # replay attempt.
    incomplete_swaps = Map.get(report, :_incomplete_swaps, %{})

    report =
      if map_size(incomplete_swaps) > 0 do
        Enum.each(incomplete_swaps, fn {_id, swap_info} ->
          Logger.error(
            "Recovery: CRITICAL: incomplete swap detected — " <>
              "amount=#{Map.get(swap_info, :amount, 0)} sats burned without new signatures issued. " <>
              "Outstanding supply reduced by this amount."
          )
        end)

        # Feed swap secret_hashes into the same blocked-hash file as
        # melt hashes, so Spent refuses to serve them on next replay.
        # The swap WAL entry now carries `secret_hashes` (see swap.ex);
        # legacy entries without the field are handled gracefully.
        swap_hashes = collect_incomplete_swap_hashes(incomplete_swaps)
        queue_blocked_hashes(swap_hashes)

        :telemetry.execute(
          [:minted, :recovery, :incomplete_swaps],
          %{count: map_size(incomplete_swaps)},
          %{}
        )

        Map.put(report, :incomplete_swaps, incomplete_swaps)
      else
        report
      end

    # Queue hashes collected while replaying legacy :proof_spent
    # entries — the double-spend guard for data written before the
    # spent backend existed.
    replay_blocked = Map.get(report, :_replay_blocked_hashes, [])

    report =
      if replay_blocked != [] do
        Logger.warning("Recovery: blocking #{length(replay_blocked)} token hash(es) from replayed proof_spent entries")

        queue_blocked_hashes(replay_blocked)
        Map.put(report, :replay_blocked_count, length(replay_blocked))
      else
        report
      end

    {:ok,
     Map.put(report, :consistency_verified, consistency.consistent)
     |> Map.put(:consistency, consistency)}
  end

  defp log_summary(report, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info("""
    Recovery: completed:
      Level: #{Map.get(report, :level, "unknown")}
      Entries replayed: #{Map.get(report, :replayed_count, 0)}
      Time taken: #{elapsed}ms
    """)

    {:ok, Map.put(report, :elapsed_ms, elapsed)}
  end

  defp publish_recovery_event(report) do
    try do
      EventBus.publish(%StorageEvents.RecoveryCompleted{
        report: report,
        timestamp: DateTime.utc_now()
      })
    rescue
      e ->
        Logger.warning("Recovery: publish_recovery_event failed: #{inspect(e)}")
        :ok
    end

    {:ok, report}
  end

  defp collect_incomplete_melt_hashes(incomplete_melts) do
    Enum.flat_map(incomplete_melts, fn {quote_id, payload} ->
      Logger.error(
        "Recovery: incomplete melt: quote=#{quote_id} " <>
          "amount=#{Map.get(payload, :amount)} " <>
          "bolt11=#{redact(Map.get(payload, :bolt11))}"
      )

      secret_hashes = Map.get(payload, :secret_hashes, [])
      keyset_id = Map.get(payload, :keyset_id, "recovery")
      Enum.map(secret_hashes, fn hash -> {hash, keyset_id} end)
    end)
  end

  defp collect_incomplete_swap_hashes(incomplete_swaps) do
    Enum.flat_map(incomplete_swaps, fn {_id, payload} ->
      secret_hashes = Map.get(payload, :secret_hashes, [])
      # Swap entries store `input_keyset_id`; fall back to a placeholder
      # for legacy entries so downstream Spent lookups still get a stable
      # keyset id.
      keyset_id = Map.get(payload, :input_keyset_id, "recovery")
      Enum.map(secret_hashes, fn hash -> {hash, keyset_id} end)
    end)
  end

  defp queue_blocked_hashes([]), do: :ok

  defp queue_blocked_hashes(blocked_hashes) do
    path = Paths.recovery_blocked_hashes()
    File.mkdir_p!(Path.dirname(path))

    # :sync forces fsync before File.write returns — this file is the
    # double-spend guard that Spent reads on the next boot, so a crash
    # between the write and the kernel flush would silently throw away
    # the blocklist. Also chmod 0600 since the file pairs token hashes
    # with their keyset ids and has no reason to be world-readable.
    case File.write(path, :erlang.term_to_binary(blocked_hashes), [:sync]) do
      :ok ->
        _ = File.chmod(path, 0o600)
        Logger.warning("Recovery: #{length(blocked_hashes)} token hashes persisted to #{path} for Spent blocking")

      {:error, reason} ->
        Logger.error("Recovery: failed to persist blocked hashes to #{path}: #{inspect(reason)}")
        # Fall back to Application.put_env so Spent can still pick them up this session
        Application.put_env(:minted, :recovery_blocked_hashes, blocked_hashes)
    end
  end

  @doc false
  def blocked_hashes_path do
    Paths.recovery_blocked_hashes()
  end

  defp redact(nil), do: "nil"
  defp redact(s) when byte_size(s) <= 8, do: "***"
  defp redact(s), do: binary_part(s, 0, 8) <> "..."

  # --- Fallback Levels ---

  defp attempt_dets_recovery(wal_dir, start_time) do
    Logger.error(
      "Recovery: WAL-level replay failed; DETS-only recovery cannot reconstruct " <>
        "the double-spend guard (no blocked-hashes rebuild, no proof re-mark) — " <>
        "escalating to manual recovery to fail closed"
    )

    # Previous behaviour: opened every DETS file to prove they weren't
    # corrupt, declared "Recovery completed at level 2", and booted
    # serving traffic. Nothing was actually reconstructed — a
    # blocked-hash payload lost to a single bad WAL entry meant the
    # entire double-spend guard was silently disabled for that boot.
    # The right posture is fail-closed: refuse to run without a
    # guard the operator has confirmed reconstructed. Falling through
    # to `attempt_manual_recovery` halts with instructions; the
    # operator restores from backup (Level 3) instead.
    attempt_manual_recovery(wal_dir, start_time)
  end

  defp attempt_manual_recovery(wal_dir, start_time) do
    # Backup restore is handled externally via shell script (cp -r).
    # If we reach this point, the operator needs to restore manually.
    halt_with_instructions(wal_dir, start_time)
  end

  defp halt_with_instructions(wal_dir, start_time) do
    Logger.error("""
    Recovery: FAILED AT ALL LEVELS.

    Manual intervention required:
    1. Check WAL directory: #{wal_dir}
    2. Check DETS files in data/ directory
    3. Check backup files in data/backups/ directory
    4. As last resort, restore from external backup

    The system will be placed in :halted state.
    """)

    try do
      TelemetryFacade.set_halted("Recovery failed at all levels")
    rescue
      e ->
        Logger.warning("Recovery: set_halted failed: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.warning("Recovery: set_halted failed (process not running): #{inspect(reason)}")
    end

    report = %{level: 5, wal_dir: wal_dir, replayed_count: 0, status: :halted}
    {:ok, report} = log_summary(report, start_time)
    _published = publish_recovery_event(report)
    {:error, {:recovery_failed, report}}
  end

  @doc false
  # Returns true when a `:melt_settled` WAL payload marks the commit
  # as having failed after the Lightning payment settled. Recovery
  # must treat such entries as INCOMPLETE — tokens live only in the
  # volatile pending table and will vanish on next restart, so the
  # matching `:melt_started` entry's `secret_hashes` MUST get written
  # to the blocked-hashes file. Otherwise the user could re-spend
  # tokens the mint has already paid Lightning sats for.
  @spec melt_settled_commit_failed?(map()) :: boolean()
  def melt_settled_commit_failed?(payload) when is_map(payload) do
    Map.get(payload, :commit_failed, false) == true
  end

  def melt_settled_commit_failed?(_), do: false
end
