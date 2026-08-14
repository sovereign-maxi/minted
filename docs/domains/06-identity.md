# MINTED — Identity Domain

Anonymous request gating: rate limiting, proof-of-work, and abuse-driven escalation.

---

## Purpose

There are no accounts in MINTED. Identity is the gate that protects expensive operations from anonymous abuse without identifying the caller. Every request goes through a single plug (`Identity.Gate`) that:

1. Extracts a per-request anonymous identifier (the "circuit hash") from the request envelope — never the IP address
2. Classifies the operation as cheap, medium, or expensive
3. Applies a rate limit budget per circuit hash
4. Requires a proof-of-work challenge for expensive or recently-exhausted callers
5. Tracks abuse signals (e.g. double-spend attempts) and escalates the difficulty multiplier for repeat offenders

All cryptographic primitives, rate-limit storage, and PoW issuance/verification are delegated to the `seer` library. Identity is a thin domain that wires `seer` into the request pipeline and adds mint-specific operation classification and escalation policy.

## Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Circuit hash** | Per-request anonymous identifier extracted from the request envelope by `seer` (no IP, no user agent) |
| **Operation class** | One of `:cheap`, `:medium`, `:expensive` — drives rate budget and PoW difficulty |
| **Rate budget** | Per-class, per-circuit-hash request count over a sliding window |
| **PoW challenge** | A computational puzzle the client must solve before an expensive operation succeeds |
| **PoW difficulty** | Bits of leading-zero work required, adjustable per circuit hash and operation |
| **Escalation** | Difficulty multiplier applied to a circuit hash that has triggered abuse signals |
| **Cooldown** | Period during which an escalated circuit hash must keep solving harder PoW |

## Aggregates

**Gate** (Plug) — single entry point in the Phoenix pipeline. Stateless. Composes:
- `Seer.Circuit.Extractor.extract/1` — anonymous identifier
- `Seer.RateLimiter` — rate budget enforcement
- `Seer.Challenge` — PoW issuance and verification
- `Seer.Difficulty` — current difficulty calculation
- `Identity.Escalation` — multiplier lookup and abuse signal recording

Reads `:minted, :identity, :request_gate_enabled` at compile time, allowing tests to disable the gate while still asserting `circuit_id_hash` is assigned.

**Escalation** — abuse-signal store. Subscribes to abuse events (notably `MintEvents.DoubleSpendDetected`) and raises a difficulty multiplier for the offending circuit hash for a cooldown period. Publishes `IdentityEvents.RateLimitEscalated` on every escalation.

## Commands

| Command | Description |
|---------|-------------|
| Extract circuit hash | Pure, anonymous; via `Seer.Circuit.Extractor` |
| Classify operation | Map request method/path to `:cheap`, `:medium`, or `:expensive` |
| Check rate limit | Enforce per-class budget; deny over-budget callers |
| Require PoW | Issue a challenge or verify a submitted solution; deny insufficient work |
| Record abuse signal | Persist a circuit hash escalation; emit `RateLimitEscalated` |

## Boundaries

**Owns**: Operation classification, the request gate plug, escalation policy, abuse-signal handling.

**Depends on**:
- External `seer` library — circuit extraction, rate limiting, PoW issuance and verification, difficulty math.

**Depended on by**: `MintedWeb` only. No other domain imports Identity.

## Published Language

Identity does not currently expose a `Identity.Facade`. The Phoenix pipeline imports `Minted.Identity.Gate` directly as a plug, and `Minted.Identity.Escalation` listens via the EventBus. Both are part of the public surface implicitly, but neither has a typed facade because the entry points are framework hooks (Plug, EventBus subscriber), not function calls from another domain.

## Events

**Publishes** (via `Minted.Events.Identity`):
- `RateLimitEscalated` — a circuit hash crossed an abuse threshold and now faces increased PoW difficulty for a cooldown window

**Consumes**:
- `MintEvents.DoubleSpendDetected` — increments the offending circuit hash's escalation counter

## Invariants

- The Gate plug MUST run before any business logic in the request pipeline (mounted on the `:api` and `:browser` pipelines)
- Circuit hash extraction MUST NOT use the source IP or any other identifying header — `seer` is the sole source of truth
- A request that fails rate limiting or PoW MUST NOT reach the controller; the plug halts the conn
- Escalation multipliers MUST decay after the configured cooldown window
- The gate MUST be enabled in production (`:minted, :identity, :request_gate_enabled` defaults to true; tests opt out explicitly)

---
