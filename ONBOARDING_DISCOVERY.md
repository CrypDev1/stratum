# "Titans" (TTAN) Onboarding — On-Chain Discovery & Simulation (BNB mainnet, chainId 56)

All data read live via `cast`/forge fork against BNB mainnet. No websites scraped. No transactions
broadcast (waiting on your "GO" — Gate 2).

## Final launch decision
- **Titans (TTAN)** = **NVDAB 55% / SPCXB 45%**, quoted in USDT, **0.45% management fee**.
- **TSLAB dropped** — hard technical reason (not just pricing): its only V3 pool (TSLAB/USDC) has **zero
  in-range liquidity**, so mint's `USDT->TSLAB` swap would revert. It is un-buyable on-chain today. This
  holds even under the Chainlink-only pricing path (liquidity is irrelevant to the *safety* check but still
  required to *acquire* the component at mint).
- MUB / SNDKB / CRCLB dropped earlier — not listed on Venus at all.

## Verified addresses (Titans set)
| bStock | token | vToken | Chainlink price (via Venus) | V3/USDT pool | pool liq |
|---|---|---|---|---|---|
| **NVDAB** | `0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436` | `0xEb8Ca841cBe1BC4832A10b15c7dAB1081eDaD371` | $194.98 | `0xCC2bFfaeC373a6004bb6cCc8a62Cdd66061f7C6a` (fee 500) | `5.78e19` (thin) |
| **SPCXB** | `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1` | `0xC36dFaCc7a125859C106F29b9F2d874CCF29A55A` | $161.95 | `0x977DaFFC095b33872E2741c19568925015C35b4d` (fee 2500) | `1.575e23` (deep) |

Infra: Venus ResilientOracle `0x6592b5DE802159F3E74B2486b091D11a8256ab8A` · PancakeV3 SwapRouter
`0x1b81D678ffb9C0263b24A97847620C99d213eB14` · USDT `0x55d398326f99059fF775485246999027B3197955`.
Admin EOA `0x2e7FaF4a5c5705d87e7AB58c4a879D7F8aDb933C` holds ORACLE_ADMIN / ATTESTOR / DEPEG_ADMIN /
FACTORY_ADMIN / MARKET_KEEPER (verified on-chain).

## Two discoveries that shaped the implementation

### 1. The bStock Chainlink "SingleFeed" aggregators are access-gated
A fresh `ChainlinkAdapter` reading the raw feed reverts with `OnlyAuthorizedCallerAllowed()` — the feeds
only serve authorized consumers (Venus's ResilientOracle is one). (`cast` reads worked only because
`eth_call` defaults to `from = 0x0`.) **Fix:** price bStocks through Venus's ResilientOracle via a new
additive `VenusOracleAdapter` — still Chainlink-primary (Venus's main source for these IS that Chainlink
SingleFeed), just via the authorized reader. Venus reverts on a stale Chainlink price; the adapter catches
that and returns 0, so the NAVOracle flags the asset stale and **trading pauses on a stale feed** (the
required fail-safe). No DEX/TWAP failover.

### 2. `isTradingSafe` needs a non-zero DEX price — impossible for these pools (cardinality 1 / thin)
The live `DepegMonitor` requires a working DEX source; a TWAP over these cardinality-1 pools returns 0 and
would brick every asset. **Fix:** additive `ChainlinkOnlyDepegMonitor` — `isTradingSafe = not halted &&
NAVOracle price fresh & non-zero` (keeps the guardian halt). Wired into the factory via `setWiring`
(FACTORY_ADMIN) so **newly-created** portfolios (TTAN) use it; existing portfolios are untouched. No core
contract modified or redeployed. **Gate 1 (would a redeploy be needed?) — NO; fully admin-reachable.**

## Fork simulation result (live core, real pools) — PASSED
Ran the whole broadcast sequence against a BNB-mainnet fork (`test/Titans.fork.t.sol`):
onboard (Venus-oracle, Chainlink-only) → deploy+wire `ChainlinkOnlyDepegMonitor` + `PancakeV3SwapAdapter`
into the live factory → `createVault` TTAN (55/45, 45 bps) → user mints 100 USDT.

- allow-list passed for both components; prices sane off Chainlink (NVDAB $194.98, SPCXB $161.95).
- mint of **100 USDT → 95.59 TTAN shares**; vault acquired **0.2582 NVDAB (~$50.3)** + **0.2794 SPCXB
  (~$45.2)**; navPerShare ≈ 1.0.
- Cost ~4.4%, almost entirely the **NVDAB thin-pool** leg (~8.6% slippage on a $55 buy); SPCXB's deep pool
  was ~0. **Operational note:** for production either size NVDAB mints small, raise per-tx slippage, or have
  an LP deepen the NVDAB/USDT (fee-500) pool. (Sim used 10% slippage to complete; `CreateTitans` defaults to
  5% — large NVDAB legs may revert until the pool deepens.)

## Ready-to-paste env (already in `.env.example`)
```dotenv
STABLE_TOKEN=0x55d398326f99059fF775485246999027B3197955
PANCAKE_V3_ROUTER=0x1b81D678ffb9C0263b24A97847620C99d213eB14
VENUS_RESILIENT_ORACLE=0x6592b5DE802159F3E74B2486b091D11a8256ab8A
BSTOCK_TOKENS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1
DEPLOY_CHAINLINK_ONLY_DEPEG=true
SWAP_POOL_FEE_TOKENS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1
SWAP_POOL_FEE_TIERS=500,2500
INDEX_COMPONENTS=0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436,0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1
INDEX_WEIGHTS=5500,4500
INDEX_NAME=Titans
INDEX_SYMBOL=TTAN
MGMT_FEE_BPS=45
```

## Product-type note (TTAN = Vault)
In this codebase a management fee is a FeeManager feature that only **Vault** portfolios carry;
rules-based `createIndex` charges no fee. To honor the 0.45% fee, TTAN is created as a Vault holding the
fixed 55/45 basket with a passive manager (admin) — behaves like a fee-bearing index fund. Say the word to
switch to a zero-fee auto-rebalancing Index instead.
