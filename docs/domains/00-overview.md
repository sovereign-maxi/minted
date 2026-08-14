# MINTED — Domain Overview

## What It Is

MINTED is a Tor-native Cashu eCash mint on Bitcoin. Users deposit via Lightning, receive blinded eCash tokens with mathematically guaranteed privacy, transact peer-to-peer, and withdraw back to Lightning. No accounts, no identity, no linkability between deposits and withdrawals.

## Architecture

Lightning-only. Single-node. Direct BDHKE signing. WAL-backed state. Event-driven telemetry. Tor hidden services for all endpoints.

```
┌─────────────────────────────────────────────────────────────┐
│                         MINTED                              │
│                                                             │
│  ┌───────────┐  ┌───────────┐                               │
│  │   Mint    │  │ Lightning │                               │
│  │           │  │           │                               │
│  │ Signing   │  │ Phoenixd  │                               │
│  │ Fees      │  │ Invoices  │                               │
│  │ Quotes    │  │ Webhooks  │                               │
│  │ Spent Set │  │ Resolver  │                               │
│  └─────┬─────┘  └─────┬─────┘                               │
│        │              │                                     │
│  ┌─────┴──────────────┴────────────────────┐                │
│  │              Storage (WAL + ETS)        │                │
│  └─────────────────────────────────────────┘                │
│                                                             │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐                │
│  │ Reserves  │  │ Telemetry │  │  Identity │                │
│  │ Proofs    │  │ Alerts    │  │ Rate Limit│                │
│  │ Solvency  │  │ Health    │  │ PoW (seer)│                │
│  └───────────┘  └───────────┘  └───────────┘                │
│                                                             │
│  ┌───────────┐  ┌───────────┐                               │
│  │  Wallet   │  │  Oracle   │                               │
│  │ Tokens    │  │ BTC/USD   │                               │
│  │ Activity  │  │           │                               │
│  └───────────┘  └───────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

## Domains

| # | Domain | Purpose |
|---|--------|---------|
| 1 | [Mint](01-mint.md) | Blind signing, fee calculation, quote lifecycle, spent set |
| 2 | [Lightning](02-lightning.md) | Phoenixd integration, invoices, payments, webhooks, settlement resolver |
| 3 | [Reserves](03-reserves.md) | Proof of reserves, solvency tracking, liability/fees counters, Nostr publication |
| 4 | [Storage](04-storage.md) | WAL, ETS, CubDB, DETS, keyset persistence, recovery |
| 5 | [Wallet](05-wallet.md) | Server-side claim/redemption helper, token storage hints, activity feed |
| 6 | [Identity](06-identity.md) | Rate limiting and PoW gate (delegating to `seer`) |
| 7 | [Telemetry](07-telemetry.md) | Alerts, metrics, health monitoring, Nostr DMs |
| 8 | [Oracle](08-oracle.md) | BTC/USD price feed for display |
| 9 | [Events](09-events.md) | EventBus, domain events, Display protocol |

## Cross-Domain Dependencies

All cross-domain communication goes through facades. No module imports another domain's internal modules directly.

| From | To | Via |
|------|-----|-----|
| Mint | Lightning | `Lightning.Facade` (`inbound_liquidity` for splice-fee calculation, `routing_fee_estimate`) |
| Mint | Storage | `Storage.Facade` (WAL writes, keyset reads, spent-set backend lifecycle) |
| Mint.House | Reserves | `Reserves.Facade.fee_totals` (read-only — House derives `earned` from the Fees tracker) |
| Mint.House | Lightning | `Lightning.Facade` (invoice / payment for operator house-income payouts) |
| Lightning | Storage | `Storage.Facade` (invoice persistence via WAL adapter) |
| Reserves | Storage | `Storage.Facade` (encrypted nostr signing key) |
| Wallet | Lightning | `Lightning.Facade` (parse bolt11, request invoices) |
| Wallet | Mint | `Mint.Facade` (server-assisted claim, fee calculation) |
| Telemetry | Mint | `Mint.Facade` (spent_count, oldest_quote_in_status) |
| Telemetry | Lightning | `Lightning.Facade` (liquidity_status, health_check) |
| Telemetry | Reserves | `Reserves.Facade` (minted_total, burned_total, latest_proof) |
| Telemetry | Storage | `Storage.Facade` (active keyset, backup dir for overdue check) |

EventBus (under `Events`) provides asynchronous fan-out for cross-cutting concerns (Telemetry observation, dashboard ticker). It is a transport, not a dependency direction.

## Deposit-to-Withdrawal Flow

```
User → Tor → LiveView
  → Mint (request quote)
  → Lightning (create invoice via Phoenixd)
  → User pays invoice
  → Lightning (Phoenixd webhook: invoice paid)
  → Mint (claim: blind sign tokens)
  → User receives tokens (server-side BDHKE roundtrip in Wallet.Service)
  → ... time passes ...
  → User submits withdrawal (melt)
  → Mint (verify, reserve in pending table)
  → Lightning (pay user's invoice via Phoenixd)
  → Mint (commit reservation on success / release on definitive failure)
  → If outcome is ambiguous: Lightning.Settlement.Resolver polls Phoenixd
    and commits or releases the reservation when the outcome resolves
  → Done. Deposit and withdrawal are unlinkable.
```
