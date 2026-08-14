# MINTED — Oracle Domain

BTC/USD price feed for wallet display only.

---

## Purpose

The Oracle domain provides a current BTC/USD price for display in the wallet UI. No mint or melt decision depends on this value — fees are denominated in sats, deposits and withdrawals are denominated in sats, and the user's balance is denominated in sats. The dollar figure on screen is purely a convenience.

Because nothing financial depends on the price, the oracle is allowed to be best-effort: if all sources are unreachable, the wallet renders without the dollar figure rather than failing.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Price feed** | A periodic fetch of BTC/USD from one or more sources, aggregated into a single value |
| **Source** | An external price API (e.g. an exchange ticker) reachable via the Tor HTTP tunnel |
| **Snapshot** | The most recent successful price plus the `updated_at` timestamp |

## Aggregates

**Feed** (GenServer) — periodic price fetcher and snapshot holder. Schedules fetches at a configurable interval, queries one or more sources via the Tor HTTP tunnel, aggregates results, and updates the snapshot. Publishes `OracleEvents.PriceUpdated` on every successful update.

**Client** — HTTP client adapter that goes through the Tor HTTP tunnel like every other outbound HTTP call.

## Commands

| Command | Description |
|---------|-------------|
| Fetch price | Periodic tick — query sources, aggregate, update snapshot |
| Read snapshot | Read-only via facade for the wallet UI |

## Boundaries

**Owns**: The price feed lifecycle, the snapshot, the source list, the aggregation logic.

**Depends on**:
- External price APIs reachable via Tor HTTP tunnel (`:minted, :tor_http_tunnel`).
- Production boot refuses to start without a configured Tor HTTP tunnel.

**Depended on by**: `MintedWeb` wallet LiveView only.

## Published Language (Oracle.Facade)

External callers interact with Oracle exclusively through `Minted.Oracle.Facade`:

- `current_price/0` — returns `{price_usd | nil, updated_at | nil}`. Either field can be nil if the feed has not yet succeeded; callers must handle that case.

No other Oracle module is imported by any other domain.

## Events

**Publishes** (via `Minted.Events.Oracle`):
- `PriceUpdated` — a successful fetch produced a fresh snapshot

**Consumes**: None.

## Invariants

- No mint or melt decision MAY depend on the oracle price; this domain is display-only
- The wallet UI MUST tolerate a `nil` price gracefully (no crash, no error to the user)
- Outbound HTTP MUST go through the Tor HTTP tunnel — never clearnet
- A stale snapshot MUST be visibly stale in the UI (the `updated_at` timestamp drives that decision)

---
