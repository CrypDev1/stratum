# Stratum Build Progress

Foundry + Solidity 0.8.26, `via_ir=true`, OZ v5.6.1, forge-std v1.16.1.

## Layer status

- [x] **L0 — Oracle & Proof-of-Collateral** ✅ build green, 55 tests pass
- [ ] L1 — Portfolios: Index + Vault
- [ ] L2 — Leverage & Yield
- [ ] L3 — Structured Products
- [ ] L4 — Derivatives
- [ ] L5 — AI-Agent Vaults
- [ ] ★ Token Flywheel
- [ ] Deployment scripts + end-to-end test

---

## L0 — Oracle & Proof-of-Collateral ✅

| Contract | Status | Notes |
|---|---|---|
| `libraries/PriceLib` | ✅ | 18-dec scaling, deviationBps, bounded drift (fuzzed) |
| `interfaces/*` | ✅ | IPriceOracle, INAVOracle, IOracleAdapter, IAggregatorV3, IProofOfCollateral, IDepegMonitor |
| `oracle/ChainlinkAdapter` | ✅ | Wraps AggregatorV3 → 18-dec; rejects non-positive / stale rounds |
| `oracle/NAVOracle` | ✅ | Primary+secondary cross-check, market open/closed, after-hours bounded drift, staleness+deviation guards |
| `oracle/ProofOfCollateral` | ✅ | Attestations, isHealthy, collateralRatio, breach events, freshness |
| `oracle/DepegMonitor` | ✅ | depegBps + isTradingSafe circuit breaker (halt/stale/depeg) |
| `mocks/*` | ✅ | MockOracleAdapter, MockAggregatorV3, MockERC20 |

**Tests (55):** PriceLib fuzz (scaling/deviation/drift bounds), ChainlinkAdapter sign+round guards,
NAVOracle open/closed transitions + drift clamp + staleness + deviation, PoC breach/freshness,
DepegMonitor halt/stale/depeg-threshold.

### Design decisions
- Oracle reads **never revert on stale/deviating data** — they return `isStale=true` and let consumers
  decide. They revert only on genuine misconfiguration (unconfigured asset, no close price). This keeps
  circuit-breaker semantics in one place (`DepegMonitor.isTradingSafe`).
- After-hours drift is **clamped at read time** to `±maxDriftBps`, so a faulty keeper input can never
  move fair value beyond the governance bound.
- Adapters are **one-feed-per-instance** (mirrors Chainlink AggregatorV3), composed by NAVOracle.

### Open questions / TODO(integration)
- Real Chainlink/Pyth feed addresses for bStocks on BNB Chain.
- Real DEX TWAP adapter for `DepegMonitor` DEX source (currently MockOracleAdapter).
