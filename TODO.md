# MINTED — TODO

Verify NUT numbers against [cashubtc/nuts](https://github.com/cashubtc/nuts) before implementing.

## NUT compliance

- [ ] NUT-15: Multi-part payments (MPP)
- [ ] NUT-17: WebSocket subscriptions (Phoenix Channels)
- [ ] NUT-18: Payment requests
- [ ] NUT-19: Cached responses / idempotency
- [ ] NUT-20: Signed responses
- [ ] HTLC spending conditions
- [ ] Deterministic-secret restore — audit the mint-side `restore` endpoint
- [ ] Spec-compliance matrix in README, auto-verified by tests

## Reference hardening

- [ ] Cross-mint interop test suite (nutshell + cdk)
- [ ] Golden BDHKE / blinding / signing vectors, contribute upstream
- [ ] Property-based tests over BDHKE, serialisation, keyset rotation, token state
- [ ] Cargo-fuzz targets on the cashew NIF boundary
- [ ] Boot-time config validation with friendly diagnostics

## Developer experience

- [ ] `mix mint.*` CLI: status, keyset.rotate, keyset.list, reserves, melt.retry, info
- [ ] `docs/OPERATE.md` — fork-and-run runbook (threat model, sizing, LSP options, rotation, PoR, monitoring, backup, failure modes)
- [ ] `docs/adr/NNNN-*.md` for load-bearing decisions
- [ ] Reserves-proof publisher signed for client-side verification via `callable`

## Observability

- [ ] Built-in Prometheus `/metrics` endpoint
- [ ] OpenTelemetry traces across mint quote → payment → issuance → redemption
- [ ] Documented SLO targets

## Ecosystem contributions

- [ ] Upstream spec proposals for gaps MINTED found (replay protection, keyset rotation edges, error taxonomy)
- [ ] `cashu-ex` — Elixir wallet SDK on hex.pm
- [ ] Draft a NUT if the operational lessons are protocol-shaped

## Research

- [ ] Multi-mint federation (mint-to-mint token acceptance)
- [ ] Structured attestations over BDHKE (tickets, licenses, coupons)
- [ ] Delayed-reveal payments
- [ ] Anonymous credentials over Cashu blinding
- [ ] Mint-to-mint atomic swap
