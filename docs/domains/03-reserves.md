# MINTED — Reserves Domain

Solvency tracking, proof of reserves, and Nostr publication.

---

## Purpose

The Reserves domain answers one question continuously: does the mint hold at least as much Bitcoin as it owes in outstanding tokens? Liability is tracked in real time via dedicated counters. Proofs are generated periodically by the `Vault.Generator` library, signed with a Nostr key, and published as NIP-33 replaceable events. Every dependency on Reserves is read-only — other domains call the facade for solvency or counter snapshots; Reserves never reaches into them.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Liability** | Outstanding eCash (`minted - burned`) — the value the mint owes to bearer-token holders |
| **Solvency ratio** | `held / outstanding` expressed as a percentage. ≥100% means fully backed |
| **Reserve proof** | A signed snapshot of held Bitcoin, outstanding eCash, ratio, and timestamp |
| **Snapshot** | The bundle of mint state captured by `Vault.Snapshot.capture/1` for a proof |
| **NIP-33 event** | Nostr replaceable event (kind 30078) keyed by a stable `d` tag — readers always see the latest |
| **Liability counter** | Dedicated counter (via the `locker` library) tracking minted and burned totals |
| **Fee counter** | Tracker for cumulative deposit/withdrawal fees collected |
| **Schnorr signature** | BIP-340 signature used for Nostr event signing |

## Aggregates

**Trackers.Liability** (GenServer) — owns the minted/burned counters. Subscribes to `MintEvents.TokensMinted`, `TokensBurned`, `TokensSwapped` and updates counters via `Locker.Counter`. Provides:
- `current/0` returns `%{minted, burned, outstanding}`
- `minted_total/0`, `burned_total/0`
- `reset_counters/0`, `restore_counters/2` (recovery use)

**Trackers.Fees** (GenServer) — owns the fees counter. Subscribes to `MintEvents.FeesCollected`. Tracks lifetime totals plus a 24-hour rolling window. Provides:
- `current/0` returns `%{total_collected, event_count}`
- `last_24h/0` returns `%{total, count, avg}`
- `reset_counters/0`, `restore_counters/1`

**Source** — pure builder for the `Vault.Snapshot` input: held BTC (from Lightning), outstanding eCash (from Liability), keyset id, timestamp.

**Signer** — Ed25519 / Schnorr signing wrapper used by `Vault.Generator`. Loads the encrypted Nostr signing key via `Storage.Facade.decrypt/1` at boot.

**Publishers.Event** — subscribes to `Vault.Generator` proof completion and publishes `ReservesEvents.ProofGenerated` on the local EventBus.

**Publishers.Nostr** — subscribes to proof completion and publishes the proof as a NIP-33 replaceable event to configured relays via the shared `Minted.Nostr.Relay.Client` (WebSocket one-shot, Tor-routed). Owns the Nostr signing key in process state and exposes `pubkey/0` and `d_tag/1` helpers for the `/v1/info` endpoint.

**Publishers.Vault** — thin shim that forwards `Vault.Generator`'s lifecycle to the Nostr publisher.

## Commands

| Command | Description |
|---------|-------------|
| Generate proof | Driven by `Vault.Generator` on its scheduled tick |
| Increment liability | Side-effect of consuming `TokensMinted` / `TokensBurned` events |
| Track fee | Side-effect of consuming `FeesCollected` events |
| Snapshot solvency | Read-only facade query for the dashboard and wallet UI |
| Publish NIP-33 proof | Sign + broadcast to configured Nostr relays |

## Boundaries

**Owns**: Liability counters, fees counters, proof signing, proof publication (Nostr + EventBus), solvency snapshot logic, Nostr signing key in memory.

**Depends on**:
- `Storage.Facade.decrypt/1` — load the encrypted Nostr signing key on boot.
- `Lightning.Facade.liquidity_status/0` (transitively, via `Vault.Snapshot.capture/1`) — read total held BTC for a proof snapshot.
- External `vault` library — the actual proof generation cycle, history retention, and persistence; the domain wraps it with mint-specific data.
- External `locker` library — atomic counter primitives.

**Depended on by**:
- `Telemetry.Cache` — periodically reads `Reserves.Facade.minted_total`, `burned_total`, `latest_proof` to drive alerts.
- `MintedWeb` controllers — `/v1/reserves` and `/v1/info` query the facade for snapshot and pubkey info.

## Published Language (Reserves.Facade)

External callers interact with Reserves exclusively through `Minted.Reserves.Facade`:

**Solvency snapshot**
- `solvency/0` — the rendered status struct (status, pct, held, outstanding, delta, title) used by the wallet UI and admin dashboard

**Proof history**
- `latest_proof/0`, `proof_history/1`

**Liability counters**
- `minted_total/0`, `burned_total/0`, `liability_snapshot/0`
- `reset_counters/0`, `restore_counters/2` (recovery use)

**Fee counters**
- `fee_totals/0`, `fees_last_24h/0`
- `reset_fee_counters/0`, `restore_fee_counter/1`

**Nostr identity**
- `nostr_pubkey/0`, `guardian_pubkey/0`

No other Reserves module is imported by any other domain.

## Events

**Publishes** (via `Minted.Events.Reserves`):
- `ProofGenerated` — a proof has been signed and published (every ~10 minutes)

The following events are defined in `Minted.Events.Reserves` for the EventBus type vocabulary, but are not currently emitted by any production codepath. Deficit detection currently lives in `Telemetry.Alerts.Manager` (the `:reserve_deficit` rule) which inspects the latest proof snapshot directly:
- `ReserveDeficit`
- `ReserveCriticalDeficit`
- `ReserveRecovered`

**Consumes** (via subscriptions in trackers and publishers):
- `MintEvents.TokensMinted` → Liability tracker increments `minted` counter
- `MintEvents.TokensBurned` → Liability tracker increments `burned` counter
- `MintEvents.TokensSwapped` → Liability tracker offsets minted/burned (net-zero swap)
- `MintEvents.FeesCollected` → Fees tracker increments cumulative + 24h totals

## Invariants

- Outstanding (`minted - burned`) MUST equal the live spent-set delta; Telemetry alerts on divergence
- A reserve proof MUST be signed before publication
- Held BTC MUST be ≥ outstanding eCash for a healthy mint; Telemetry alerts on deficit
- Proofs MUST be published to all configured Nostr relays (`NOSTR_RELAYS` env)
- The Nostr signing key MUST be encrypted at rest and decrypted only into BEAM process state
- Proof history pruning is delegated to `Vault.Generator` and MUST NOT be touched directly

---
