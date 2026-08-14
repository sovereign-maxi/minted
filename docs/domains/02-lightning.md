# MINTED — Lightning Domain

Deposit and withdrawal rails via the Lightning Network, plus settlement resolution for ambiguous outcomes.

---

## Purpose

The Lightning domain manages all Bitcoin movement in and out of MINTED. Deposits arrive as Lightning payments (user pays an invoice), withdrawals go out as Lightning payments (mint pays the user's invoice). Phoenixd (ACINQ) provides Lightning connectivity. Webhook callbacks notify the mint of incoming payment events. A settlement resolver polls Phoenixd to recover melts whose outcome was ambiguous at the time of execution.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Invoice** | A bolt11 Lightning payment request generated for a deposit |
| **Payment** | An outbound Lightning payment to a user's invoice (withdrawal) |
| **Phoenixd** | ACINQ's Lightning node implementation used as the payment backend |
| **Webhook** | Phoenixd's HTTP callback notifying MINTED of payment events |
| **Splice fee** | An additional fee charged by Phoenixd when inbound liquidity is insufficient |
| **Liquidity** | Available inbound/outbound channel capacity |
| **Circuit breaker** | Per-name circuit (e.g. `:phoenixd`) that fast-fails calls after consecutive failures |
| **Settlement unknown** | A melt quote whose Lightning outcome timed out — tokens stay reserved until resolved |
| **Settlement Resolver** | GenServer that polls Phoenixd to commit or release reservations on `:settlement_unknown` quotes |

## Aggregates

**Manager** (GenServer) — owns the invoice lifecycle:
- **Invoice** — entity: bolt11 string, amount, payment_hash, quote reference, status, timestamps
- Tracks invoices from creation through paid / expired
- Persists state via Storage WAL adapter

**Executor** (task-based) — outbound payment execution:
- **Payment** — entity: payment_id, bolt11, amount, attempts, status
- Not a GenServer — uses an ETS counter to enforce a max-concurrent ceiling (5)
- `execute_and_await/1` blocks the caller until `PaymentSent` / `PaymentExhausted` / timeout

**Monitor** — facade over `FireBird.Monitor` ETS table; reads current Phoenixd balance and channel state without polling synchronously.

**Bridge** — translates `FireBird` payment events into `Minted.Events.Lightning.*` and republishes on the local EventBus.

**Breaker** — circuit breaker keyed by name (`:phoenixd`); 5 consecutive failures opens for 30s, then half-open probe before closing.

**Webhook** — Phoenixd HTTP callbacks are validated in `MintedWeb.Plugs.PhoenixdWebhook`, a thin wrapper over `FireBird.Webhook`. HMAC verification, timestamp window validation, and atomic deduplication run before any business logic.

**Settlement.Resolver** (GenServer) — periodic poller. Every minute (configurable), it scans `Mint.list_quotes_by_status(:settlement_unknown)`. For quotes older than `min_age_ms` (default 10 minutes), it queries Phoenixd's outgoing-payment endpoint and:
- On confirmed success → `Spent.commit_reserved/1` and `Quote.mark_paid/1` + `Quote.claim/1`
- On confirmed failure (404 or `completedAt` set with no preimage) → `Spent.release_reserved/1` and `Quote.abort_payment/1`
- Still pending → no action, retry next cycle

**Adapters.Client** — `{module, config}` tuple wiring for FireBird so production uses the HTTP client and tests use a Mox-backed mock.

**Adapters.WAL** — write-ahead log adapter for FireBird's invoice persistence.

**Fees** — pure helper computing Lightning routing fee estimates and splice fee uplifts.

**Holder** — long-lived ETS table owner so process crashes do not lose Lightning state.

## Commands

| Command | Description |
|---------|-------------|
| Create invoice | Generate a bolt11 invoice via Phoenixd, persist to Manager state |
| Process webhook | Validate HMAC + timestamp + dedup, mark invoice paid, publish `InvoicePaid` |
| Execute payment | Pay a user's bolt11 via Phoenixd; await settlement event |
| Resolve settlement | Poll Phoenixd for ambiguous melts and commit / release the reservation |
| Liquidity status | Read current balance and inbound from FireBird Monitor |
| Routing fee estimate | Compute the disclosed withdrawal fee for a given amount |

## Boundaries

**Owns**: Invoice lifecycle, payment execution, Phoenixd integration, liquidity monitoring, webhook validation, settlement resolution, circuit breaker, FireBird supervision.

**Depends on**:
- External: Phoenixd. All outbound HTTP routes through the Tor HTTP CONNECT tunnel configured at `:minted, :tor_http_tunnel`. Production boot refuses to start without it.
- `Storage.Facade` — invoice WAL adapter, manager DETS persistence.
- `Mint.Facade.list_quotes_by_status/1`, `update_quote/2` — used by the Settlement Resolver to discover and update stuck quotes.
- `Mint.Spent.commit_reserved/1` and `Spent.release_reserved/1` — invoked by the Resolver on resolution.

**Depended on by**:
- `Mint.Facade` via `Lightning.Facade.inbound_liquidity/0` (splice-fee calculation) and `routing_fee_estimate/1` (withdrawal fee disclosure).
- `Wallet.Service` via `Lightning.Facade.parse_bolt11_amount/1` and `create_invoice/3` for deposit flows.
- `Telemetry.Facade` via `health_check/0` for the Lightning health alert.

No other domain names a Lightning internal module.

## Published Language (Lightning.Facade)

External callers interact with Lightning exclusively through `Minted.Lightning.Facade`:

- **Liquidity**: `liquidity_status/0`, `inbound_liquidity/0`
- **Invoices**: `create_invoice/3`
- **Bolt11**: `parse_bolt11_amount/1`
- **Payments**: `execute_payment_and_await/1`
- **Fees**: `routing_fee_estimate/1`
- **Health**: `health_check/0`

No other Lightning module is imported by any other domain.

## Webhook Security

Webhook validation runs before any business logic in `MintedWeb.Plugs.PhoenixdWebhook` (a thin wrapper over `FireBird.Webhook`):

1. **HMAC-SHA256 signature** — `x-phoenix-signature` header verified against `WEBHOOK_SECRET` (mandatory in production, ≥32 bytes; constant-time compare via `Plug.Crypto.secure_compare/2`).
2. **Timestamp window** — `x-phoenix-timestamp` must be within 5 minutes of server time (replay protection). Required in production.
3. **Atomic deduplication** — payment_hash inserted via `:ets.insert_new/2` into a 1-hour TTL dedup table backed by DETS for crash-safety. Concurrent webhooks for the same payment_hash race for the insert; the loser short-circuits.
4. **Type guards** — `payment_hash` and `preimage` must both be binary (no atom or list slip-through).

If any step fails, the webhook returns the appropriate error code and the call never reaches the Manager.

## Events

**Publishes** (via `Minted.Events.Lightning`):
- `InvoicePaid` — incoming payment received and confirmed
- `InvoiceExpired` — invoice TTL elapsed without payment
- `PaymentSent` — outbound payment settled (preimage returned)
- `PaymentFailed` — single-attempt failure; may or may not retry
- `PaymentExhausted` — all retries failed; payment definitively failed
- `PaymentUnknown` — payment outcome ambiguous; awaits Settlement Resolver
- `LiquidityLow` — balance crossed below the low watermark
- `LiquidityCritical` — balance crossed below the critical watermark
- `LiquidityRecovered` — balance returned above the high watermark

**Consumes**: None directly. Driven by:
- Phoenixd webhooks (HTTP callbacks)
- Manager polling for invoice state changes
- Executor task supervision for payment outcomes
- Settlement Resolver scheduled tick

## Invariants

- Mint signing MUST only occur after `InvoicePaid` is observed; no signing on invoice creation
- A failed outbound payment (`PaymentExhausted` or definitive 404) MUST NOT mark tokens as spent
- An ambiguous outbound payment (`:settlement_timeout`) MUST hold tokens reserved until the Settlement Resolver resolves
- Maximum 5 concurrent outbound payments (Executor `@max_concurrent`)
- Circuit breaker MUST open Phoenixd calls after 5 consecutive failures and stay open for 30s
- Webhook MUST validate HMAC, timestamp, and dedup before invoking business logic
- Settlement Resolver MUST be idempotent — repeated polls of the same quote MUST NOT double-commit or double-release

---
