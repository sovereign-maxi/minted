# MINTED

Bitcoin without a trail.

A Chaumian eCash mint on Bitcoin's Lightning Network. Deposit Bitcoin, receive blind-signed bearer tokens, withdraw to any wallet. The mint cannot link deposits to withdrawals — it is mathematically incapable of doing so.

Reference implementation of the [Cashu](https://cashu.space/) protocol (NUTs 00-08, 12) built on BDHKE over secp256k1. Single-node, Tor-native, Phoenixd-backed.

Protocol specification: [github.com/sovereign-maxi/minted-docs](https://github.com/sovereign-maxi/minted-docs).

## Architecture

Single-node. Direct blind signing via Cashew (Rust NIF). Auto-rotating keysets with configurable TTL.

Nine bounded contexts under a `rest_for_one` supervision tree:

| Context | Responsibility |
|---------|---------------|
| **Mint** | Token issuance, redemption, swap, fees, spent set |
| **Lightning** | Phoenixd gateway — invoices, payments, settlement resolution |
| **Reserves** | Proof of reserves, solvency monitoring, Nostr publication |
| **Storage** | WAL, ETS, CubDB/DETS, keyset persistence, crash recovery |
| **Wallet** | LiveView orchestration of deposits, melts, swaps, backup/restore |
| **Identity** | Rate limiting, PoW challenges, abuse escalation |
| **Telemetry** | Alert rules, health scoring, auto-halt, Nostr DM alerts |
| **Oracle** | BTC/USD price feed |
| **Events** | EventBus, domain event structs, Display protocol |

Two Phoenix endpoints, each intended for a dedicated Tor hidden service:

- **MintedWeb** (dev `:4000`, prod `$PORT`) — Cashu NUT API + wallet LiveView
- **MintedAdminWeb** (dev `:4001`, prod `$ADMIN_PORT`) — read-only operator dashboard

## Prerequisites

- Elixir 1.19 / OTP 27 (see `.tool-versions`)
- Rust (stable) for the Cashew NIF
- [Phoenixd](https://phoenix-server.xyz/) — Lightning gateway
- Tor — required for production

## Setup

```bash
mix deps.get
git config core.hooksPath hooks
```

## Development

```bash
iex -S mix phx.server

mix test                    # unit
mix test --only integration # integration
mix test --only scenario    # scenario
```

- Wallet: <http://localhost:4000/wallet>
- Admin:  <http://localhost:4001/admin/dashboard>

## API

All endpoints under `/v1`, JSON.

| Method | Path | NUT | Description |
|--------|------|-----|-------------|
| `GET`  | `/v1/info` | 06 | Mint info and capabilities |
| `GET`  | `/v1/keysets` | 01/02 | List keysets |
| `GET`  | `/v1/keysets/:id` | 01/02 | Get keyset by ID |
| `POST` | `/v1/mint/quote` | 04 | Request deposit quote (Lightning invoice) |
| `POST` | `/v1/mint/quote/:id` | 04 | Claim tokens (submit blinded messages) |
| `POST` | `/v1/melt/quote` | 05 | Request withdrawal quote |
| `POST` | `/v1/melt/quote/:id` | 05 | Execute withdrawal (pay Lightning invoice) |
| `POST` | `/v1/swap` | 03 | Swap tokens (denomination change) |
| `POST` | `/v1/check` | 07 | Check token spend status |
| `GET`  | `/v1/reserves` | — | Current reserve proof |
| `GET`  | `/v1/reserves/history` | — | Reserve proof history |

## Reference-implementation defaults

| Operation | Fee |
|-----------|-----|
| Deposit | 0.75% (7,500 ppm) |
| Withdrawal | 0% + Lightning routing pass-through |
| Swap | Free |
| P2P transfer | Free |

Fees are configurable — the protocol doesn't mandate a schedule. A conforming mint chooses its own.

## Documentation

| Doc | Purpose |
|-----|---------|
| [domains/00-overview.md](docs/domains/00-overview.md) | Architecture and domain map |
| [domains/01-mint.md](docs/domains/01-mint.md) | Mint domain — blind signatures, keysets, spent set |
| [domains/02-lightning.md](docs/domains/02-lightning.md) | Lightning domain — invoices, payments, settlement resolution |
| [domains/03-reserves.md](docs/domains/03-reserves.md) | Reserves domain — solvency, proof of reserves, Nostr publication |
| [domains/04-storage.md](docs/domains/04-storage.md) | Storage domain — WAL, ETS, crash recovery |
| [domains/05-wallet.md](docs/domains/05-wallet.md) | Wallet domain — LiveView deposits, melts, swaps, backup/restore |
| [domains/06-identity.md](docs/domains/06-identity.md) | Identity domain — rate limiting, PoW, abuse escalation |
| [domains/07-telemetry.md](docs/domains/07-telemetry.md) | Telemetry domain — alerts, health, auto-halt, Nostr DMs |
| [domains/08-oracle.md](docs/domains/08-oracle.md) | Oracle domain — BTC/USD price feed |
| [domains/09-events.md](docs/domains/09-events.md) | Events domain — EventBus and Display protocol |
| [prds/00-product-requirements.md](docs/prds/00-product-requirements.md) | Functional + non-functional requirements |

## Dependencies

```elixir
{:cashew,    path: "../cashew"},
{:blueprint, path: "../blueprint"},
{:oracle,    path: "../oracle"},
{:seer,      path: "../seer"},
{:locker,    path: "../locker"},
{:vault,     path: "../vault"},
{:fire_bird, path: "../firebird"},
```

All primitives are published under [github.com/sovereign-maxi](https://github.com/sovereign-maxi).

## License

MIT. See [LICENSE](LICENSE).
