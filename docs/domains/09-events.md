# MINTED — Events Shared Kernel

Typed domain event structs, EventBus distribution, and the Display protocol.

---

## Purpose

Domains MUST NOT call each other's internal modules. They communicate via two channels:

1. **Facades** — synchronous, typed entry points for direct work (e.g. Lightning calling `Mint.Facade.list_quotes_by_status/1`)
2. **EventBus** — asynchronous, typed publish/subscribe for fan-out and cross-cutting concerns (Telemetry observation, audit logs, dashboard ticker)

This module owns the EventBus, the canonical event taxonomy, the topic derivation rules, and the `Display` protocol used to render any event into a human-readable description for logs, the dashboard, and Nostr DMs.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Domain event** | A typed struct describing something that happened in a domain (e.g. `Mint.TokensMinted`) |
| **EventBus** | The publish/subscribe mechanism — `Phoenix.PubSub.local_broadcast` under the hood |
| **Topic** | A logical channel derived from the event struct's module name (e.g. `events:mint:tokens_minted`) |
| **Display** | A protocol implemented by every domain event, returning `{label, summary, meta}` for rendering |
| **Subscriber** | A process that joins a topic and receives events as bare struct messages in `handle_info/2` |
| **Audit trail** | The full history of domain events written to the WAL by Storage when a state mutation also publishes |

## Aggregates

**EventBus** — a thin wrapper around `Phoenix.PubSub.local_broadcast`. Public API:
- `publish(event)` — broadcasts on a topic derived from the struct module
- `publish(event, suffix)` — broadcasts on a sub-topic for keyed subscribers (e.g. `payment_id`)
- `subscribe(module)` — current process joins the topic for that event type
- `subscribe(module, suffix)` — subscribe to a keyed sub-topic
- `unsubscribe(module)`, `unsubscribe(module, suffix)`

Topic derivation drops `Minted.Events` from the module path and underscores the rest:
`Minted.Events.Mint.TokensMinted` → `events:mint:tokens_minted`.

**Display** (protocol) — every domain event implements `Display.to_human/1` returning a `{label, summary, meta}` tuple used by Telemetry's event stream, the admin dashboard, and Nostr publishers.

## Event Catalog

The catalog is per-domain and lives in `lib/minted/events/<domain>.ex`. Each module groups its domain's events.

### `Minted.Events.Mint`
- `TokensMinted` — blind signatures issued
- `TokensBurned` — tokens committed as spent
- `TokensSwapped` — atomic swap completed
- `QuoteCreated` — mint or melt quote created
- `QuoteUpdated` — quote status changed
- `FeesCollected` — fee captured on quote settlement
- `DoubleSpendDetected` — incoming token already in spent set
- `OrphanDepositReconciled` — `Pending.Reconciler` aged out an in-flight signature the client never returned for; compensating `:tokens_burned` written

### `Minted.Events.House`
- `WithdrawalRequested` — operator invoiced a house-income payout; amount moves into in-flight
- `WithdrawalCompleted` — Lightning payment settled; the house `:total_house_withdrawn` counter is incremented
- `WithdrawalRejected` — insufficient balance, half-cap violation, or Lightning failure; in-flight is cleared

### `Minted.Events.Lightning`
- `InvoicePaid` — incoming Lightning payment confirmed
- `InvoiceExpired` — invoice TTL elapsed without payment
- `PaymentSent` — outbound payment settled
- `PaymentFailed` — single-attempt failure
- `PaymentExhausted` — all retries failed; payment definitively failed
- `PaymentUnknown` — payment outcome ambiguous; awaits Settlement Resolver
- `LiquidityLow` — balance crossed below the low watermark
- `LiquidityCritical` — balance crossed below the critical watermark
- `LiquidityRecovered` — balance returned above the high watermark

### `Minted.Events.Reserves`
- `ProofGenerated` — reserve proof signed and published
- `ReserveDeficit`, `ReserveCriticalDeficit`, `ReserveRecovered` — defined for the type vocabulary; not currently emitted (deficit detection lives in Telemetry alerts)

### `Minted.Events.Storage`
- `KeysetCreated` — new keyset persisted
- `KeysetExpired` — keyset marked expired
- `CompactionCompleted` — spent-set entries pruned for an expired keyset
- `RecoveryCompleted` — WAL replay finished with a structured report
- `LegacyKeyDecryptFallback` — a legacy-format at-rest secret was decrypted via the fallback path

### `Minted.Events.Identity`
- `RateLimitEscalated` — abuse signal triggered increased PoW difficulty for a circuit hash

### `Minted.Events.Telemetry`
- `AlertFired` — a rule transitioned to firing
- `AlertResolved` — a previously firing rule is now clean
- `SystemStatusChanged` — system health moved between states
- `TorDown`, `TorDegraded`, `TorRecovered` — Tor reachability transitions
- `KeysetRotated` — informational mirror of a Storage keyset rotation

### `Minted.Events.Wallet`
- `BalanceChanged` — session-scoped wallet balance changed

### `Minted.Events.Oracle`
- `PriceUpdated` — BTC/USD snapshot refreshed

## Boundaries

**Owns**: EventBus implementation, topic derivation convention, Display protocol, the canonical event-type registry under `Minted.Events.*`.

**Depends on**: `Phoenix.PubSub` only — the underlying transport.

**Depended on by**: Every domain (publishers and subscribers).

## Published Language

`Minted.Events.EventBus` is the public API; all four functions (`publish/1`, `publish/2`, `subscribe/1,2`, `unsubscribe/1,2`) are part of the published language. The `Display` protocol is also part of the public surface — every domain that defines events MUST implement it for those events.

## Invariants

- Domain events MUST be plain structs (no pids, no functions, no resources)
- Every domain event MUST implement the Display protocol
- Publishers MUST NOT depend on the existence of any specific subscriber
- Subscribers MUST tolerate event delivery in any order (no causal ordering across topics)
- An event publish MUST NOT block on subscriber processing (`local_broadcast` semantics; fire-and-forget)
- An unhandled subscriber error MUST NOT prevent the event from reaching other subscribers
- Topic derivation MUST follow the documented rule (`Minted.Events.Mint.TokensMinted → events:mint:tokens_minted`); cross-domain code that constructs topic strings manually is a bug

---
