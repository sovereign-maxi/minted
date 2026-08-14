# MINTED — Telemetry Domain

Alert evaluation, health scoring, auto-halt, and operator notification via Nostr DMs and the admin dashboard.

---

## Purpose

Telemetry is how MINTED tells its operator what's happening, what's wrong, and when to intervene. It evaluates alert rules over the live system on a periodic schedule, maintains an aggregate health state, exposes health endpoints for liveness probes, surfaces a real-time event stream on the admin dashboard, and pushes critical events to the operator's Nostr DM.

The domain is read-only with respect to other domains — it observes via facades and the EventBus. It never reaches into another domain's internals.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Alert rule** | A named check (`Minted.Telemetry.Alerts.Rule`) that periodically evaluates a condition and emits an alert if true |
| **Severity** | `:info` / `:warning` / `:critical` / `:emergency` — drives publication channels and health impact |
| **Health state** | `:healthy` / `:degraded` / `:critical` / `:halted` — system-wide aggregate from `Health.System` |
| **Halt** | Auto-imposed read-only mode triggered by emergency conditions or manual operator action |
| **Cache** | ETS-backed snapshot of cross-domain reads, refreshed periodically; alert rules read from this |
| **Event stream** | Live LiveView feed on the admin dashboard backed by a ring buffer (`Events.Stream`) |
| **Nostr DM** | NIP-17 gift-wrapped (NIP-44 encrypted) message to the operator's pubkey via configured relays |

## Aggregates

**Alerts.Manager** (GenServer) — owns the rule registry, schedules periodic evaluation, and routes publication. On each evaluation cycle it runs every rule, emits `AlertFired` / `AlertResolved` on transitions, and forwards critical events to the Nostr publisher.

**Alerts.Rule** — value object: name, severity, period, condition fn, formatter.

**Health.System** (GenServer) — aggregates rule results into the four-state model. Owns the halt gate (`set_halted/1`, `clear_halt/0`, `halted?/0` consumed via the facade) and emits `SystemStatusChanged` on transitions.

**Health.Cache** (GenServer) — periodically reads cross-domain values via the other facades (`Reserves.minted_total`, `Lightning.liquidity_status`, `Storage.get_active_keyset`, `Mint.spent_count`, etc.) and stores them in ETS so alert rules don't have to call out on every evaluation.

**Health.Metrics** — pure helpers turning Cache values into `Ring`-friendly time-series points.

**Health.Peer** — pure helpers for peer-related health checks (kept small after federation was retired).

**Metrics.Collector** — `:telemetry` handler attaching to Phoenix, Cowboy, and application events. Aggregates counters and updates `Cache`.

**Metrics.Ring** — in-memory ring buffer of timestamped metric snapshots. Backs the dashboard charts.

**Metrics.Store** — DETS-backed counter persistence so totals survive restarts.

**Events.Handler** — EventBus subscriber. Consumes domain events to update Cache and append to the event stream.

**Events.Stream** — bounded ring buffer for the admin dashboard's live feed.

**Filter** — Logger filter that tags telemetry-relevant log entries.

**Formatter** — Logger formatter for structured JSON logs.

**Publishers.Nostr** (and `Publishers.Nostr.Nip04` / `Publishers.Nostr.Nip44`) — operator alert delivery via NIP-17 gift-wrapped DMs. Owns ephemeral signing keys for unlinkable metadata privacy. Sends via the shared `Minted.Nostr.Relay.Client` (WebSocket one-shot, Tor-routed).

## Commands

| Command | Description |
|---------|-------------|
| Evaluate alert rule | Run condition fn, emit `AlertFired` / `AlertResolved` on transitions |
| Refresh cache | Read cross-domain values via facades, store in ETS for fast rule reads |
| Halt system | Mark halted, alert operator, refuse expensive operations |
| Resume system | Operator-issued via console (`Telemetry.Facade.set_halted/1` is the only halt entrypoint) |
| Publish Nostr DM | Gift-wrap and broadcast critical alerts to configured relays |
| Snapshot metrics | Capture a `Ring` data point for dashboard charts |

## Boundaries

**Owns**: Alert rules, severity classification, health state aggregation, halt mechanism, event-stream ring buffer, metrics ring buffer, metrics counter store, Nostr DM publication, Logger filter and formatter.

**Depends on**: Every domain's facade (read-only):
- `Mint.Facade.spent_count`, `Mint.Facade.oldest_quote_in_status`, `Mint.Facade.spent_set_memory_bytes`
- `Lightning.Facade.liquidity_status`, `Lightning.Facade.health_check`
- `Reserves.Facade.minted_total`, `Reserves.Facade.burned_total`, `Reserves.Facade.latest_proof`
- `Storage.Facade.get_active_keyset`, `Storage.Facade.backup_dir`

Plus the EventBus for live observation of domain events.

**Depended on by**: Every domain via `Telemetry.Facade.set_halted/1` (failsafe halt) and the admin LiveView via the read-only facade methods.

## Published Language (Telemetry.Facade)

External callers interact with Telemetry exclusively through `Minted.Telemetry.Facade`:

- **Halt control**: `set_halted/1`
- **Health**: `system_status/0`, `health_components/0`
- **Alerts**: `active_alerts/0`
- **Metrics**: `system_metrics/0`, `metrics_series/2`

No other Telemetry module is imported by any other domain. (`Guards.ensure_operational!/0` lives in `Minted.Guards`, not Telemetry, but it consults `Health.System.halted?/0` to decide.)

## Alert Rules

`Alerts.Manager` registers 30 production rules at time of writing. The exact list is the source of truth — `lib/minted/telemetry/alerts/manager.ex` is law — and CI pins the count in `manager_test.exs`.

### Naming convention

Apply uniformly to every new rule:

- **Threshold metrics with multiple severity tiers** use the `_high` / `_critical` suffix pair (or `_low` / `_critical` when the metric trips going DOWN, e.g. `liquidity_low` / `liquidity_critical`). A `_high` rule MUST have a `_critical` sibling — never solo. CI enforces this in the `manager_test.exs` "naming convention" test.
- **State events** (binary or descriptive conditions) use a propositional phrase that reads true when the alert fires: `reserve_deficit`, `tor_unreachable`, `backup_overdue`, `orphan_deposits_reconciled`. No severity suffix.

Severity itself is metadata on the `Rule` struct, not part of the name. Don't repeat severity in the name except to differentiate paired threshold tiers.

### Current rules

**Paired threshold metrics**:
`cpu_high` / `cpu_critical`, `memory_high` / `memory_critical`, `disk_usage_high` / `disk_usage_critical`, `pending_signatures_high` / `pending_signatures_critical`, `double_spend_rate_high` / `double_spend_rate_critical`, `spent_set_memory_high` / `spent_set_memory_critical`, `liquidity_low` / `liquidity_critical`

**State events**:
`reserve_deficit`, `liability_invariant`, `lightning_unreachable`, `proof_publication_missed`, `payment_exhausted`, `backup_overdue`, `rate_limit_surge`, `dets_near_limit`, `keyset_rotation_due`, `melt_settlement_stuck`, `tor_unreachable`, `tor_degraded`, `orphan_deposits_reconciled`

## Events

**Publishes** (via `Minted.Events.Telemetry`):
- `AlertFired` — a rule transitioned to firing
- `AlertResolved` — a previously firing rule is now clean
- `SystemStatusChanged` — system health moved between states (`:healthy → :degraded → :critical → :halted`)
- `TorDown` / `TorDegraded` / `TorRecovered` — Tor reachability transitions (driven by `tor_unreachable` / `tor_degraded` rules)
- `KeysetRotated` — keyset rotation observed (informational; persistence is in `Storage.Events`)

**Consumes**: Every domain event via `Events.Handler` for the dashboard's event stream and Cache updates. The Cache is also updated by direct facade reads on a refresh tick, not exclusively by event consumption.

## Invariants

- An alert rule MUST evaluate without raising — all errors caught and the rule marked `:errored`
- Halt MUST be respected by every domain via `Guards.ensure_operational!/0`, which consults `Health.System.halted?/0`
- Nostr publications MUST use ephemeral keys (per-message gift-wrap) — the operator's primary key is never exposed
- Metrics counters MUST be monotonic (never decremented)
- The event stream ring buffer MUST drop oldest entries when full (no unbounded memory growth)
- Critical alerts MUST be delivered to the operator's Nostr DM within one rule cycle

---
