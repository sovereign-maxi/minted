# MINTED — Mint Domain

Blind signatures, keysets, token lifecycle, and double-spend prevention.

---

## Purpose

The Mint domain is the core of MINTED. It implements Chaumian blinded signatures (BDHKE on secp256k1) that provide the fundamental privacy guarantee: deposits and withdrawals are cryptographically unlinkable. The Mint signs blinded messages it cannot see, and later verifies unblinded signatures it cannot trace back.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Blinded message** | A token secret hidden by a blinding factor — the Mint signs this without seeing the underlying value |
| **Blind signature** | The Mint's signature on a blinded message |
| **Unblinding** | Removing the blinding factor from the signed message, producing a valid token |
| **Token** | A bearer instrument: amount + secret + unblinded signature + keyset ID |
| **Keyset** | A set of 21 signing keys (one per power-of-2 denomination) |
| **Keyset rotation** | Creating a new keyset for minting while honouring old keysets for redemption |
| **Spent set** | The set of SHA256 hashes of all redeemed token secrets — the sole defence against double-spending |
| **Y-index** | NUT-07 secondary index keyed by the secret's hash-to-curve point, used by `/v1/check` |
| **Pending table** | In-memory reservations held during melt; promoted to spent on commit, removed on release |
| **Quote** | A time-limited offer to mint or melt tokens at a specified fee |
| **Swap** | Exchanging valid tokens for new tokens of the same total amount (refreshes privacy) |
| **DLEQ proof** | Discrete log equality proof — proves the Mint used the correct key without revealing it |
| **Denomination** | Power-of-2 token sizes: 1, 2, 4, ... 1,048,576 sats (21 levels) |

## Aggregates

**Services.Signing** — issues blind signatures using the active keyset; rejects non-active keysets.

**Services.Quotes** (GenServer) — owns the quote state machine for both mint and melt:
- `MintQuote` — amount, fee, Lightning invoice, payment_hash, expiry, status
- `MeltQuote` — bolt11, fee, expiry, status, melt_context (tokens + keyset_id captured for the SettlementResolver)
- States: `:pending → :invoiced → :paid → :claimed`, with melt-specific `:paying`, `:settlement_unknown`, `:stale_claimed`, `:expired`

**Services.Swap** — atomic swap orchestration: reserve old tokens, sign new blinded messages, commit reservation. On commit failure the mint halts via `Telemetry.Facade.set_halted/1` rather than returning signatures.

**Services.Redemption** — token verification and redemption primitives: `verify_batch`, `verify_and_reserve`, `commit_reservation`, `release_reservation`, `redeem`.

**Spent** (GenServer) — aggregate root for spent-token tracking. Owns three ETS tables (main spent set, Y-index, pending reservations) and the persistent backend (CubDB by default). Provides atomic `verify_and_reserve` / `commit_reserved` / `release_reserved` and double-spend detection.

**Pending** (GenServer + DETS) — durable store for blind signatures awaiting client storage ACK. After `Services.Signing` produces signatures during a deposit, they are stamped with the originating session id and persisted here keyed by `quote_id` BEFORE being pushed to the client. They stay until the client confirms storage via `wallet:tokens_stored_ok` (entry is deleted) or until `Pending.Reconciler` classifies them as orphaned. Surviving a BEAM crash between sign and ACK is the load-bearing guarantee — without it, a server restart would silently lose the signatures and leave the user with no path to recover the deposit. Stored at `data/mint/pending.dets`.

**Pending.Reconciler** (GenServer worker) — periodic sweep that closes the phantom-liability hole. Every minute it scans `Pending` for entries older than the configured threshold (default 1 hour); for each, it writes a compensating `:tokens_burned` to the WAL tagged `reason: :orphaned_deposit, keyset_id: nil` so the liability counter stays balanced. Re-run is safe: recovery dedups orphan burns by `{quote_id, :orphaned_deposit}`, so a Reconciler crash between WAL append and `Pending.delete` cannot double-count. Each reconcile is wrapped in `try/rescue` so one bad entry can't crash the GenServer mid-sweep. Broadcasts `{:quote_reconciled, quote_id}` on Phoenix.PubSub for connected wallet sessions to clean up client-side blinding state.

**Keysets.Builder** — keyset assembly from pre-generated or runtime-generated key material. `Keyset.generate/0` for fresh keysets or `Builder.assemble_from_keys/1` when loading from JSON.

**Keysets.Loader** — reads encrypted keyset material from disk via `Storage.Facade.encrypt/decrypt`.

**Fees** — fee schedule calculation. Reads ppm config (`deposit_fee_ppm`, `withdrawal_fee_ppm`); for deposits the splice multiplier kicks in when the requested amount exceeds available inbound liquidity.

**Signatures.Blind**, **Signatures.Message**, **Signatures.Response** — value objects for the BDHKE protocol.

**Token** — value object: serialise / deserialise the `cashuA` URI form.

**House** — house-income sub-aggregate. `Mint.House.Facade` is the public surface (`earned/0`, `drawn/0`, `withdrawable/0`, `in_flight/0`, `max_single_request/0`, `request_withdrawal/2`, `complete_withdrawal/2`, `reject_withdrawal/2`). `House.Store` owns two `Locker.Counter` totals (`:total_fees_collected` — read from `Reserves.Trackers.Fees`; `:total_house_withdrawn` — owned here) plus an ETS in-flight register. `withdrawable = collected - drawn - in_flight`. `House.Console` is the operator iex interface for issuing operator-payout invoices. A half-cap on `max_single_request` bounds each withdrawal to at most half of current `withdrawable`.

## Commands

| Command | Description |
|---------|-------------|
| Create mint quote | Calculate fee, create quote with expiry, generate Lightning invoice via Lightning.Facade |
| Create melt quote | Parse bolt11, calculate fee, create quote with expiry |
| Sign blinded tokens | After payment confirmed, produce blind signatures; publish `TokensMinted` |
| Verify and reserve | Validate signatures against the input keyset, hold tokens in pending |
| Commit reservation | Promote pending entries to the durable spent set; publish `TokensBurned` |
| Release reservation | Drop pending entries (definitive payment failure or operator decision) |
| Swap | Atomically reserve old tokens, sign new blinded messages, commit |
| Check spent | NUT-07 — return spent/unspent status by Y-point |
| Compact keyset | Remove spent entries scoped to an expired keyset |

## Boundaries

**Owns**: Blind signing, token verification, keysets in memory, spent set + Y-index + pending tables, quotes, fee calculation, BDHKE / DLEQ helpers.

**Depends on**:
- `Storage.Facade` — keyset reads (`get_active_keyset`), WAL writes for liability events, spent-set backend lifecycle (`open_spent_set_backend`), recovery hashes path, encrypt/decrypt for keyset material.
- `Lightning.Facade` — `inbound_liquidity` for splice-fee calculation, `routing_fee_estimate` for withdrawal fee disclosure.
- `Telemetry.Facade.set_halted/1` — failsafe halt on swap commit failure.
- `Guards.ensure_operational!/0` — refuses operations while halted.

**Does not own**: Lightning payment execution, on-disk keyset persistence (Storage), client-side wallet token storage (Wallet).

## Published Language (Mint.Facade)

External callers interact with Mint exclusively through `Minted.Mint.Facade`. The complete public surface:

**Keysets**
- `generate_keyset/0`, `keyset_from_store_map/1`, `get_keyset_key/2`, `active_keyset_id/0`

**Signing**
- `sign/3` (with `publish_event: bool` opt to suppress double-counting from swaps)

**Swap**
- `swap/4`

**Redemption**
- `verify_batch/2`, `verify_and_reserve/2`, `commit_reservation/2`, `release_reservation/2`, `redeem/2`

**Spent set**
- `spent?/1`, `spent_by_y?/1` (NUT-07), `spent_count/0`, `mark_spent/2`, `compact_keyset/1`

**Fees**
- `deposit_fee/1`, `withdrawal_fee/1`

**Quotes**
- `get_quote/1`, `list_quotes_by_status/1`, `update_quote/2`, `create_mint_quote/1`, `create_melt_quote/2`, `find_active_mint_quote/0`, `find_active_mint_quotes/0`

**BDHKE helpers**
- `blind/1`, `unblind/3`

**Token serialisation**
- `serialize_token/1`, `deserialize_token/1`

**Observability**
- `spent_set_memory_bytes/0` (telemetry use), `oldest_quote_in_status/1` (settlement-stuck alert use)

No other Mint module is imported by any other domain.

## Events

**Publishes** (via `Minted.Events.Mint`):
- `TokensMinted` — blind signatures issued (sign and swap callers)
- `TokensBurned` — tokens committed as spent (redemption commit)
- `TokensSwapped` — atomic swap completed
- `QuoteCreated` — mint or melt quote created
- `QuoteUpdated` — quote status changed
- `FeesCollected` — fee captured on quote settlement
- `DoubleSpendDetected` — incoming token already in spent set
- `OrphanDepositReconciled` — Reconciler aged out a Pending entry the client never returned for; compensating `:tokens_burned` written

**Publishes** (via `Minted.Events.House`, for the House sub-aggregate):
- `WithdrawalRequested` — operator invoiced a house-income payout; amount moves into in-flight
- `WithdrawalCompleted` — Lightning payment settled; `:total_house_withdrawn` incremented
- `WithdrawalRejected` — insufficient balance, half-cap violation, or Lightning failure; in-flight cleared

**Consumes**:
- `Lightning.InvoicePaid` — drives the `:invoiced → :paid` transition for mint quotes
- Lightning payment results (`PaymentSent` / `PaymentExhausted`) — handled by the Lightning Settlement Resolver, which calls back into Mint to commit or release reservations

## Invariants

- A token secret MUST appear in the durable spent set at most once
- Signing MUST only occur for the active keyset (retired keysets reject `sign/3`)
- Retired keysets MUST verify and redeem their own tokens indefinitely
- Swap MUST be atomic — reserve, sign, and commit happen in a single GenServer call; commit failure halts the mint rather than returns signatures
- The spent set MUST be append-only during normal operation (compaction is keyset-scoped only)
- Every blind signature MUST carry a DLEQ proof (NUT-12)
- Reservations in the pending table MUST be either committed (durable spent) or released; abandoned reservations are recovered on boot from the WAL `:melt_started` entries
- Blind signatures destined for a deposit MUST be persisted to `Mint.Pending` BEFORE being pushed to the client; a BEAM crash in between would silently lose them with no recovery path
- `Mint.Pending` entries MUST be bound to the originating session id; cross-session ACK or extraction is rejected
- A `Pending` entry orphaned past the Reconciler threshold MUST produce a compensating `:tokens_burned` so `outstanding == minted - burned` stays accurate when no holder can ever redeem the signed tokens
- The mint MUST refuse work via `Guards.ensure_operational!/0` when halted

---
