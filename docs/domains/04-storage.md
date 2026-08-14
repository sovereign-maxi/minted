# MINTED — Storage Domain

Persistence, write-ahead log, ETS table ownership, and crash recovery.

---

## Purpose

The Storage domain is the durability layer for everything else. It provides:

- A write-ahead log (`Locker.WAL`) for crash-safe state mutations
- A protected ETS table holder so consumer crashes don't lose state
- A persistent keyset store (CubDB-backed)
- A pluggable spent-set backend (CubDB by default; DETS for tests)
- A recovery pipeline that replays the WAL on boot
- Encryption helpers (AES-256-GCM) for at-rest secrets

Backup and restore of the on-disk state are operational concerns handled by external scripts; this domain is responsible only for keeping that state consistent and durable on disk.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **WAL** | Write-Ahead Log — append-only sequence of typed entries (`Locker.WAL.Entry`) with CRC32 checksums |
| **Entry** | A typed record in the WAL (e.g. `:keyset_created`, `:tokens_burned`, `:melt_started`) |
| **Holder** | Long-lived process that owns `:protected` ETS tables for consumers whose own GenServer may crash |
| **Keyset store** | CubDB-backed persistent storage for signing keysets, encrypted at rest |
| **Spent-set backend** | Pluggable persistent backend for spent token hashes (CubDB or DETS) |
| **Recovery** | The bootstrap pipeline that replays the WAL and rebuilds in-memory state |
| **Compaction** | Removing spent-set entries scoped to an expired keyset |
| **Blocked hashes file** | Per-recovery file written by Recovery for in-flight melt tokens to prevent re-spend |

## Aggregates

**Keysets.Store** (GenServer) — CubDB-backed persistent keyset storage. ETS table is `:protected` and owned by `Storage.Holder`, so a crashed Store process does not lose the table. Provides `get/1`, `get_active/0`, `list/0`, `put/1`, `rotate/2`, `expire/1`. Encrypts private key material via `Storage.Encryption` before disk write.

**Storage.Encryption** — AES-256-GCM helpers keyed off `MINTED_ENCRYPTION_KEY`. Single root for every at-rest secret in the application: keyset private keys, the Reserves Nostr signing key, the Vault.Generator guardian key.

**Backends** — pluggable behaviour for the spent-set backend; concrete implementations in `Backends.CubDB` and `Backends.DETS`. Selected at boot via `Storage.Facade.open_spent_set_backend/0`.

**WAL** — boot-time configuration for `Locker.WAL`. Owns the segment directory, segment size, and replay configuration.

**Holder** — ETS table holder process. Owns `:protected` tables for consumers (e.g. Lightning Manager, Wallet Service) whose own GenServer may crash without losing table state.

**Compaction** — keyset-scoped spent-set pruning. Reads from `Mint.Facade.compact_keyset/1` and emits `CompactionCompleted`.

**Handler** — EventBus subscriber that consumes storage-related events for telemetry and dashboard display.

**Runner** — boot-time orchestrator that calls `Recovery.run/0` via `handle_continue` so the supervisor tree is up before recovery begins.

**Recovery** (and `Recovery.Verifier`, `Recovery.Rebuilder`) — multi-level recovery pipeline:
1. **Level 1 — WAL replay**: scan segments, detect data loss, verify each entry's CRC, find uncommitted entries, replay, rebuild ETS, verify consistency.
2. **Level 2 — DETS rebuild**: if WAL replay reports gaps, attempt to reconstruct from the persistent backend.
3. **Manual halt**: on irrecoverable corruption, halt the system with operator instructions.

Recovery also writes `recovery_blocked_hashes` to disk during boot — `Mint.Spent` consumes this on init to block tokens whose melts were in-flight at crash time.

**Paths** — single source of truth for every persistent file path, grouped by bounded context under `MINTED_DATA_DIR`. `ensure_dirs!/0` is called on application startup before any supervisor.

## Commands

| Command | Description |
|---------|-------------|
| Append WAL entry | Write a typed entry, fsync on close per WAL config |
| Replay WAL on boot | Reconstruct state from log; halt on corruption |
| Open spent-set backend | Centralised backend selection for `Mint.Spent` |
| Encrypt / decrypt | At-rest crypto for keysets and the Nostr signing key |
| Compact keyset | Prune spent-set entries for an expired keyset |

## Boundaries

**Owns**: WAL configuration, ETS table ownership (`Storage.Holder`), keyset store, spent-set backend lifecycle, encryption helpers, recovery pipeline, path resolution.

**Depends on**:
- External `locker` library — WAL primitives.
- External `cubdb` library — persistent key-value store.
- File system under `MINTED_DATA_DIR` — created with mode `0o700`.

**Depended on by**: Every domain that persists state. All access via `Storage.Facade`.

## Published Language (Storage.Facade)

External callers interact with Storage exclusively through `Minted.Storage.Facade`:

**Keysets**
- `get_keyset/1`, `get_active_keyset/0`, `list_keysets/0`
- `put_keyset/1`, `rotate_keyset/2`, `expire_keyset/1`

**WAL**
- `write_wal/2`, `append_wal_entry/1`, `read_all_wal/0`

**Spent-set backend**
- `open_spent_set_backend/0`

**Encryption**
- `encrypt/1`, `decrypt/1`, `encrypt_term/1`, `decrypt_term/1`

**Recovery**
- `recovery_blocked_hashes_path/0`

**Paths**
- `base_dir/0`, `backup_dir/0` (read-only path, used by Telemetry's overdue-backup check), `keys_path/0`
- `mint_quotes_path/0`, `mint_pending_path/0`, `mint_spent_set_dets_path/0`
- `lightning_invoices_path/0`, `lightning_invoice_quote_map_path/0`
- `reserves_proofs_path/0`, `telemetry_metrics_path/0`
- `operator_audit_path/0`, `halt_state_path/0`
- `ensure_dirs!/0` (called once at boot)

No other Storage module is imported by any other domain.

## Events

**Publishes** (via `Minted.Events.Storage`):
- `KeysetCreated` — new keyset persisted via `put_keyset/1`
- `KeysetExpired` — keyset marked expired via `expire_keyset/1`
- `CompactionCompleted` — spent-set entries pruned for an expired keyset
- `RecoveryCompleted` — WAL replay finished with a structured report

**Consumes**: None — Storage is the substrate, not a reactor.

## Invariants

- The WAL MUST be written before any state mutation is considered durable
- Recovery MUST replay entries in order; corruption halts startup rather than skipping silently
- Recovery MUST dedup `:tokens_minted` entries by `quote_id` (concurrent `/v1/mint` racers can produce orphans before the atomic claim wins)
- Recovery MUST dedup orphan `:tokens_burned` entries by `{quote_id, :orphaned_deposit}` so a `Pending.Reconciler` crash between WAL append and `Pending.delete` cannot double-count the burn on re-run
- Keysets stored on disk MUST be encrypted (AES-256-GCM via `Storage.Encryption`)
- Spent-set backend selection MUST be controlled exclusively by `Storage.Facade.open_spent_set_backend/0`; no other domain names `Backends.CubDB` or `Backends.DETS` directly
- `Storage.Holder` MUST own `:protected` tables for any consumer whose state must outlive crashes of its own GenServer
- The recovery blocked-hashes file MUST be written with `:sync` and `0o600` so a crash between write and fsync does not lose the double-spend guard
- Path resolution MUST go through `Storage.Paths` only — no other module hard-codes `data_dir` subpaths
- No Ecto, no PostgreSQL, no migrations

---
