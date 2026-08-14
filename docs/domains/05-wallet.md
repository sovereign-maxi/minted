# MINTED — Wallet Domain

LiveView orchestration of deposits, melts, swaps, backup, and restore. Tokens live in the user's browser localStorage; the server signs and tracks liability but does not custody.

---

## Purpose

The Wallet domain is the orchestration layer between the LiveView UI, the Mint domain, the Lightning domain, and the in-flight `Mint.Pending` durable signature store. Because MINTED is a self-custodial mint, the user IS the wallet — but the cryptographic operations split across the network boundary: the **client (browser, WASM)** generates secrets and blinding factors, the **server (LiveView)** signs blinded messages, and the **client** unblinds and persists the resulting tokens to localStorage.

The Wallet domain owns the protocol that keeps these two halves synchronised, including the ACK gate that prevents a phantom-liability bug where the server signs but the client fails to store.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Claim** | The post-payment step where the wallet hands a paid mint quote to the BDHKE protocol |
| **Blinded message** | `B' = hash_to_curve(secret) + r*G`, generated client-side and sent to the server for signing |
| **Blind signature** | The server's `C' = k*B'` response, sent back to the client for unblinding |
| **Unblinding** | Client-side computation of `C = C' - r*K` to produce a valid token |
| **ACK gate** | The server holds blind signatures in `Mint.Pending` until the client confirms it has unblinded and stored the resulting tokens, only then logging the deposit to the activity feed |
| **Activity feed** | A client-side localStorage list of wallet operations rendered by the LiveView |
| **Pending blinding state** | Per-quote secrets + blinding factors persisted to client localStorage so a browser reload mid-deposit doesn't strand the deposit |
| **Stale claimed** | A claimed melt quote whose payment never resolved; surfaced for operator action |

## Aggregates

**Service** (stateless orchestrator) — public API of the Wallet domain:
- `claim_deposit/1` — legacy server-side BDHKE roundtrip (still present for tests/rollback, no longer the primary flow)
- `sign_blinded_messages/2` — client-blinded variant; verifies quote, writes `:tokens_minted` WAL, atomically claims, signs blinded messages, records fee
- `request_melt/1`, `execute_melt/2` — quote and execute a withdrawal
- `import_backup/1`, `export_backup/1` — round-trip the cashu URI form for disaster recovery

`Service` holds no state. It composes `Mint.Facade`, `Lightning.Facade`, `Storage.Facade`, and `Mint.Pending`.

**MintedWeb.WalletLive** — the LiveView session. Owns the deposit ACK protocol via three handlers:
- `wallet:tokens_stored_ok` — client confirms it stored tokens; server pushes activity entry, deletes from `Mint.Pending`
- `wallet:tokens_stored_failed` — client failed to unblind/store; server retains entry for retry, surfaces error
- `wallet:request_signatures` — client asks the server to redeliver signatures for a quote it never finished (page reload, server crash recovery)

Each handler is rate-limited per socket and bound to the originating session id stored in `Mint.Pending`, so a different connected session cannot ACK or extract signatures for a deposit it didn't initiate.

## Commands

| Command | Description |
|---------|-------------|
| Sign blinded messages | Validate quote, write WAL, claim atomically, sign client-supplied blinded messages, persist to `Mint.Pending`, push to client |
| Acknowledge token storage | After client unblinds and writes to localStorage, log activity and clear `Mint.Pending` entry |
| Reject token storage | If client unblinding fails, retain `Mint.Pending` entry so the user can retry without losing the deposit |
| Request signatures | Redeliver signatures from `Mint.Pending` (e.g. after page reload or server restart) |
| Request melt | Build a melt quote via `Mint.Facade.create_melt_quote/2` |
| Execute melt | Reserve tokens, write WAL, request payment via Lightning, commit or release |
| Swap | Reserve old, sign new, commit (atomic via `Mint.Facade.swap/4`) |
| Import backup | Validate token CRDs against the spent set; restore unspent tokens to client localStorage |

## Deposit ACK Flow

```
Browser                              Server
   │                                    │
   │ wallet:blinded_messages ──────────▶│  sign_blinded_messages/2
   │                                    │  ├─ WAL :tokens_minted
   │                                    │  ├─ Quote.claim (atomic)
   │                                    │  ├─ BDHKE sign
   │                                    │  ├─ Mint.Pending.put (durable)
   │  ◀──────────── wallet:blind_signatures
   │ unblind locally                    │
   │ writeTokens(localStorage)          │
   │ wallet:tokens_stored_ok ──────────▶│  Mint.Pending.delete
   │                                    │  push wallet:add_activity
   │  ◀──────────── wallet:add_activity─│  send_update DepositPanel (modal closes)
```

Failure paths:

- **Client unblinding fails** → `wallet:tokens_stored_failed`. Server retains `Mint.Pending` entry; user can reload to retry. Activity is NOT logged.
- **Server crashes between sign and ACK** → `Mint.Pending` survives in DETS. On reconnect, the client requests redelivery via `wallet:request_signatures` and the server pushes the same signatures.
- **Client never returns** (browser closed, device lost) → `Mint.Pending.Reconciler` ages the entry out after the configured threshold (default 1 hour) and writes a compensating `:tokens_burned` WAL entry tagged `reason: :orphaned_deposit` so the liability counter stays balanced.

## Boundaries

**Owns**: deposit ACK protocol, melt orchestration, swap orchestration, backup/restore round-trip, the `WalletLive` socket lifecycle, the rate-limited deposit-handler trio.

**Depends on**:
- `Mint.Facade` — quote management, BDHKE helpers, signing, swap, redemption primitives
- `Mint.Pending` — durable in-flight signature store
- `Mint.Pending.Reconciler` — orphan reconciliation (subscribed via Phoenix.PubSub)
- `Lightning.Facade` — invoice creation, payment execution, fee estimates, bolt11 parsing
- `Storage.Facade` — WAL writes for liability events
- `Guards.ensure_operational!/0` — refuses operations while the system is halted

**Depended on by**: `MintedWeb` (LiveViews and components only). No other domain imports Wallet.

## Published Language

Wallet does not expose a `Wallet.Facade` — its only consumer is the web layer in the same release. The web layer imports `Minted.Wallet.Service` directly.

Should a second consumer ever appear, a facade module should be introduced and direct imports forbidden.

## Events

**Publishes**:
- `MintEvents.FeesCollected` — emitted by `Service` when a deposit collects a fee (deduplicated; only Wallet emits this)
- `MintEvents.TokensMinted` — emitted after `sign_blinded_messages/2`

**Consumes**:
- `{:quote_reconciled, quote_id}` (Phoenix.PubSub on `Reconciler.pubsub_topic/0`) — broadcasts to connected sessions so the client can drop the matching pending blinding state from localStorage

## Invariants

- The WAL `:tokens_minted` entry MUST be written before the quote is claimed; a crash after WAL but before claim leaves a durable record, while the reverse would lose it
- The `Mint.Pending` entry MUST be written before `wallet:blind_signatures` is pushed to the client; a crash between persists nothing the client can recover from
- `wallet:add_activity` MUST NOT be pushed before the client confirms storage via `wallet:tokens_stored_ok`
- `Mint.Pending` entries MUST be bound to the originating socket id; cross-session ACK / extraction is rejected with a logged warning
- Each deposit-handler handler MUST be rate-limited per socket to prevent log/CPU amplification by a hostile client
- The originating modal MUST receive `send_update DepositPanel, :claim_result` on either ACK or NACK so the UI never hangs on "claiming…"
- A failed signing run after a successful claim MUST mark the quote `:stale_claimed` (Mint quote state machine) rather than reverting to `:paid`, since liability is already recorded

---
