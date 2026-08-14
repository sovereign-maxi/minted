# MINTED — Product Requirements

Functional requirements, architecture decisions, and system constraints.

---

## 1. Overview

### 1.1 Summary

MINTED is a Tor-native Cashu eCash mint built on Bitcoin. Users deposit Bitcoin via Lightning, receive private eCash tokens with mathematically guaranteed privacy, transact peer-to-peer with complete anonymity, and withdraw back to Lightning. No accounts, no identity, no linkability between deposits and withdrawals.

### 1.2 Project Name

- **Public brand**: MINTED
- **Tagline**: Bitcoin Without a Trail
- **Elixir app name**: `:minted`
- **Release binary**: `minted`

### 1.3 Problem Statement

Bitcoin's transparent blockchain creates a permanent, public ledger of all financial activity. Chain analysis companies exploit this transparency to build surveillance profiles.

Existing privacy solutions are inadequate:

| Solution | Limitation |
|----------|-----------|
| CoinJoin / Mixers | Probabilistic privacy, small anonymity sets, shrinks over time |
| Lightning (alone) | Channel opens/closes are on-chain, routing nodes see payment paths |
| Monero / Zcash | Separate chains, liquidity fragmentation, regulatory targets |
| Custodial mixers | Trust a single party, honeypot risk, exit scam potential |

### 1.4 Solution

An eCash mint where:

- **Privacy is mathematical, not promissory** — Blinded signatures make it *impossible* to link deposits to withdrawals
- **Access is anonymous** — Tor-only, no clearnet, no IP exposure
- **Tokens are bearer instruments** — Whoever holds the token owns the value, no accounts
- **The anonymity set only grows** — Every deposit ever made is part of the set, retroactively
- **Resilient by design** — WAL-backed state, automated backups, crash recovery via OTP supervision
- **Single-node architecture** — Cashu BDHKE on secp256k1 is incompatible with threshold signing; single-node is the only correct shape

### 1.5 What This Is NOT

- **Not a mixer**: No coin shuffling, no probabilistic anonymity, no UTXO manipulation
- **Not an exchange**: No order matching, no trading, no positions
- **Not a money transmitter**: Infrastructure for user-to-user bearer token transfer
- **Not novel cryptography**: Chaum's blind signatures (1982), BDHKE on secp256k1, 40+ years of peer review
- **Not federated**: Cashu BDHKE on secp256k1 is incompatible with threshold signing — single-node is the only correct architecture

---

## 2. Users

### 2.1 Primary

| Persona | Need | Behavior |
|---------|------|----------|
| **Privacy-conscious Bitcoiner** | Break chain analysis linkage | Deposits, holds eCash, withdraws to fresh wallet |
| **P2P transactor** | Send/receive value without surveillance | Trades eCash tokens directly |
| **Merchant** | Accept Bitcoin payments privately | Receives eCash, redeems to Lightning periodically |

### 2.2 Secondary

| Persona | Need |
|---------|------|
| **Wallet developer** | Build on the Cashu-compatible API |
| **Auditor / Verifier** | Independently verify proof of reserves |

### 2.3 Out of Scope

- Users requiring KYC/AML compliance workflows
- Users expecting fiat on/off ramps
- Users without Tor access

---

## 3. Functional Requirements

### 3.1 Mint (Deposit)

**Flow:**
1. User requests mint quote (amount in sats)
2. System returns quote with fee calculation and Lightning invoice
3. User pays invoice via any Lightning wallet
4. System detects payment via Phoenixd webhook
5. User submits blinded token messages + quote reference
6. System signs blinded tokens via BDHKE with DLEQ proofs
7. User claims signed blinds and unblinds locally → valid eCash tokens

**Requirements:**
- FR-M01: System SHALL generate Lightning invoices via Phoenixd REST API
- FR-M02: System SHALL support mint amounts from 1 to 33,000,000 sats (configurable)
- FR-M03: System SHALL calculate deposit fees at configurable ppm (default: 7,500 ppm = 0.75%)
- FR-M04: System SHALL sign blinded tokens only after payment confirmation
- FR-M05: Mint quotes SHALL expire after configurable TTL (default: 1 hour)
- FR-M06: System SHALL return Cashu-compatible blind signatures (BDHKE) with NUT-12 DLEQ proofs
- FR-M07: System SHALL decompose amounts into power-of-2 denomination tokens

### 3.2 Melt (Withdrawal)

**Flow:**
1. User requests melt quote with a bolt11 Lightning invoice
2. System returns quote with fee calculation
3. User submits tokens + quote reference
4. System verifies token signatures and reserves them in the spent set
5. System pays the Lightning invoice via Phoenixd
6. On success: tokens committed (permanently spent), user receives Bitcoin
7. On failure: tokens released (available again), user can retry
8. On ambiguous outcome: tokens HELD in pending, quote marked `:settlement_unknown`

**Requirements:**
- FR-E01: System SHALL verify token signatures using the keyset that signed them (active or retired)
- FR-E02: System SHALL reject tokens present in the spent set (double-spend prevention)
- FR-E03: System SHALL atomically reserve tokens before payment, commit on success, release on definitive failure
- FR-E04: System SHALL pay Lightning invoices via Phoenixd
- FR-E05: System SHALL calculate withdrawal fees at configurable ppm (default: 0 ppm; user pays Lightning routing fee directly)
- FR-E06: If Lightning payment fails definitively, system SHALL release the reservation (atomic)
- FR-E07: If Lightning payment outcome is ambiguous (timeout), system SHALL HOLD the reservation (fail-closed) and mark the quote `:settlement_unknown`
- FR-E08: Maximum 5 concurrent outbound payments; soft timeout 35s, hard timeout 40s
- FR-E09: System SHALL return overpayment as signed change tokens via NUT-08 (Lightning fee return)
- FR-E10: Change tokens SHALL be signed using the active keyset, not the input keyset
- FR-E11: Change token liability SHALL be recorded via WAL before signatures are returned

### 3.3 Settlement Resolution (Automated)

**Flow:**
1. Quotes in `:settlement_unknown` state are tracked by the SettlementResolver GenServer
2. Resolver polls Phoenixd for the actual outcome of stuck payments
3. Minimum age before first check: 10 minutes (allows Phoenixd to settle naturally)
4. Polling interval: 60 seconds
5. On confirmed success: tokens committed, quote marked `:claimed`
6. On confirmed failure: tokens released, quote marked `:invoiced` (user can retry)
7. Still pending: no action, retry next cycle

**Requirements:**
- FR-SR01: System SHALL maintain a SettlementResolver GenServer that periodically polls Phoenixd for ambiguous outcomes
- FR-SR02: Resolver SHALL only act on quotes older than the configured min-age (default: 10 minutes)
- FR-SR03: Resolver SHALL commit or release token reservations based on Phoenixd's authoritative outcome
- FR-SR04: Resolver SHALL be idempotent — repeated polling does not double-commit or double-release

### 3.4 Swap

**Requirements:**
- FR-SW01: System SHALL accept valid tokens and return new blind signatures for the same total amount (NUT-03)
- FR-SW02: Swap SHALL be atomic — old tokens spent and new tokens signed in a single operation
- FR-SW03: Swaps SHALL be free (no fee)

### 3.5 Token Operations

**Requirements:**
- FR-T01: Tokens SHALL use 21 power-of-2 denominations: 2^0 (1 sat) through 2^20 (1,048,576 sats)
- FR-T02: Tokens SHALL conform to the Cashu NUT specification
- FR-T03: Token serialization SHALL use base64url encoding with `cashuA` prefix
- FR-T04: Each token SHALL contain: amount, secret, unblinded signature point (C), keyset ID
- FR-T05: System SHALL support multiple keysets simultaneously (active for minting, retired for redemption)
- FR-T06: System SHALL support manual keyset rotation via remote console
- FR-T07: Retired keysets SHALL retain their private keys and accept tokens for redemption (melt) indefinitely
- FR-T08: Expired keysets SHALL have their private keys scrubbed (only used as a kill switch for compromised keys)

### 3.6 Spend Checking

**Requirements:**
- FR-SP01: System SHALL provide an endpoint to check if tokens are spent or unspent (NUT-07)
- FR-SP02: Spend check SHALL accept a list of token Y values
- FR-SP03: Spend check SHALL return spent/unspent classification per token

### 3.7 Lightning Integration

**Requirements:**
- FR-L01: System SHALL generate invoices for deposits via Phoenixd REST API
- FR-L02: System SHALL pay invoices for withdrawals via Phoenixd REST API
- FR-L03: System SHALL detect payments via authenticated Phoenixd webhooks (HMAC via `WEBHOOK_SECRET`, mandatory in production, minimum 32 bytes)
- FR-L04: Webhook payloads SHALL be type-validated (payment_hash and preimage must be binary)
- FR-L05: Webhook timestamp SHALL be within 5 minutes of server time (replay protection)
- FR-L06: Webhook payment_hash SHALL be deduplicated (1-hour ETS + DETS dedup)
- FR-L07: System SHALL monitor Phoenixd balance with configurable thresholds
- FR-L08: System SHALL alert when balance crosses threshold boundaries
- FR-L09: System SHALL maintain a circuit breaker around Phoenixd calls (5 consecutive failures → 30s open)

### 3.8 Proof of Reserves

**Requirements:**
- FR-R01: System SHALL generate proof of reserves at configurable interval
- FR-R02: Proof SHALL include: Lightning balance, total eCash outstanding (minted - burned), solvency ratio
- FR-R03: Proof SHALL be cryptographically signed (Nostr Schnorr signature)
- FR-R04: Proof SHALL be verifiable: BTC held >= eCash outstanding
- FR-R05: Proof SHALL be published to the `/v1/reserves` API endpoint with history at `/v1/reserves/history`
- FR-R06: Proof SHALL be published to configured Nostr relays as NIP-33 replaceable events

### 3.9 Cashu NUT Compliance

| NUT | Name | Implementation |
|-----|------|---------------|
| NUT-00 | Notation and models | Blind signature primitives (BDHKE) |
| NUT-01 | Mint public keys | `GET /v1/keysets`, `GET /v1/keysets/:id` |
| NUT-02 | Keyset ID derivation | SHA256 of sorted concatenated pubkeys, first 8 bytes |
| NUT-03 | Swap | `POST /v1/swap` |
| NUT-04 | Mint (deposit) | `POST /v1/mint/quote`, `POST /v1/mint/quote/:id` |
| NUT-05 | Melt (withdrawal) | `POST /v1/melt/quote`, `POST /v1/melt/quote/:id` |
| NUT-06 | Mint information | `GET /v1/info` |
| NUT-07 | Spend checking | `POST /v1/check` |
| NUT-08 | Lightning fee return | Change tokens for melt overpayment, signed with active keyset |
| NUT-12 | DLEQ proofs | Discrete log equality proofs included with blind signatures |

### 3.10 Admin Dashboard

Served on a separate port (default: 4001) bound to a dedicated Tor hidden service. The `.onion` address itself is the capability — no password or token authentication. Write operations are not exposed over HTTP.

**Requirements:**
- FR-A01: Admin endpoint SHALL be reachable only via the configured admin `.onion` (OnionOnly plug)
- FR-A02: OnionOnly plug SHALL fail closed in production if no admin hostname is configured
- FR-A03: Admin onion hostname SHALL be configured via `TOR_ADMIN_ONION_HOSTNAME` environment variable
- FR-A04: Dashboard SHALL display: solvency, house income, flow (lifetime), Lightning status, system metrics, active alerts, event stream
- FR-A05: Dashboard SHALL follow Blueprint design language

### 3.11 Keyset Management

**Requirements:**
- FR-K01: System SHALL support multiple concurrent keysets (active + retired)
- FR-K02: Keyset rotation SHALL be operator-initiated via remote console (`Minted.Storage.Facade.rotate_keyset/2`)
- FR-K03: A `keyset_rotation_due` alert SHALL fire when the active keyset is older than 30 days
- FR-K04: Retired keysets SHALL retain private keys and accept tokens for redemption (melt) indefinitely
- FR-K05: New tokens SHALL only be minted with the active keyset
- FR-K06: Keyset private keys SHALL be encrypted at rest (AES-256-GCM with HKDF-derived key)
- FR-K07: `MINTED_ENCRYPTION_KEY` environment variable SHALL be required in production (mandatory at boot)
- FR-K08: Compromised keysets MAY be expired manually, which scrubs private keys (kill switch for melt as well as mint)

---

## 4. Non-Functional Requirements

### 4.1 Privacy

- NFR-P01: System SHALL NOT be able to link deposits to withdrawals (cryptographic guarantee)
- NFR-P02: System SHALL NOT store or log user IP addresses
- NFR-P03: System SHALL NOT require user accounts or identifying information
- NFR-P04: All user-facing services SHALL be accessible only via Tor hidden services
- NFR-P05: Zero clearnet exposure — no DNS records, no public IP, no CDN
- NFR-P06: Spent set SHALL store only hashes of token secrets
- NFR-P07: All outbound HTTP from the application SHALL go through the Tor HTTP tunnel
- NFR-P08: Production boot SHALL fail if `TOR_HTTP_TUNNEL_PORT` is not configured

### 4.2 Security

- NFR-S01: Keyset private keys SHALL be encrypted at rest (AES-256-GCM)
- NFR-S02: Backups SHALL be encrypted and integrity-verified
- NFR-S03: Rate limiting SHALL be applied to API endpoints
- NFR-S04: Proof-of-work challenges SHALL gate expensive operations (deposit, withdrawal, swap, check) via the `seer` library
- NFR-S05: Admin surface SHALL be reachable only via dedicated Tor hidden service (OnionOnly plug, fail-closed in prod)
- NFR-S06: Phoenixd webhooks SHALL be authenticated via HMAC (mandatory `WEBHOOK_SECRET` in production, ≥32 bytes)
- NFR-S07: Data volume SHALL be encrypted at rest
- NFR-S08: No swap partition (no risk of keys being swapped to disk)
- NFR-S09: Strict Content-Security-Policy on all responses; identifying headers (server, x-powered-by) stripped
- NFR-S10: All error responses to users SHALL be generic (no stack traces, no framework version disclosure)

### 4.3 Availability

- NFR-A01: System SHALL implement automatic crash recovery (WAL replay, ETS rebuild from CubDB and DETS)
- NFR-A02: System SHALL perform automatic backups with HMAC integrity verification
- NFR-A03: System SHALL push encrypted backups to a remote repository on a configurable schedule
- NFR-A04: System SHALL expose health endpoints: `/health/live`, `/health/ready`
- NFR-A05: System SHALL implement 4-state health model: healthy → degraded → critical → halted
- NFR-A06: System SHALL evaluate 30 alert rules covering all subsystems
- NFR-A07: System SHALL alert operator via Nostr DMs (NIP-17 gift-wrapped) on warning/critical/emergency conditions
- NFR-A08: System SHALL auto-halt on critical conditions: disk > 95%, reserve deficit, manual halt
- NFR-A09: SettlementResolver SHALL automatically resolve `:settlement_unknown` quotes via Phoenixd polling

---

## 5. Architecture

### 5.1 Technology Stack

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Application** | Elixir / OTP 27 | Mint logic, API, supervision, recovery |
| **Web** | Phoenix / LiveView | REST API, web wallet, admin dashboard |
| **Cryptography (server)** | Rust NIFs (Cashew) | BDHKE, hash-to-curve, keyset derivation, DLEQ proofs |
| **Cryptography (client)** | WASM (Nutty) | Client-side blinding/unblinding in browser |
| **Lightning** | Phoenixd (ACINQ) via FireBird | Deposit/withdrawal rails, liquidity |
| **Network** | Tor hidden services | Anonymous user access |
| **Storage** | ETS + CubDB + DETS | In-memory state, persistent key-value, spent token tracking |
| **Recovery** | WAL + automated encrypted backups (local + remote) | Write-ahead log, snapshots with HMAC |
| **Monitoring** | Telemetry + LiveView + Nostr DMs | Alert rules, 4-state health, event-driven dashboard |

See [domains/00-overview.md](../domains/00-overview.md) for domain architecture.

### 5.2 Single-Node Architecture

Federation was investigated and ruled out — Cashu BDHKE on secp256k1 requires the full private key for signing, making threshold signing cryptographically impossible without a fundamental protocol change. Every mint MUST run as a single node holding its own keys.

Deployment shape (host OS, disk encryption, boot procedure, backup destination, colocation with Phoenixd) is left entirely to the operator.

---

## 6. Fee Structure

| Operation | Fee | Notes |
|-----------|-----|-------|
| Deposit | 0.75% (7,500 ppm) | Shown before payment, collected upfront |
| Withdrawal | 0% (operator) | User pays only the Lightning routing fee, passed through |
| Swap | Free | Denomination splitting/combining |
| P2P transfer | Free | Bearer token handoff |

Fee bounds: minimum 1 sat. Splice-out fees on Phoenixd may apply when channel inbound liquidity is exceeded.

