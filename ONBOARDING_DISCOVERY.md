# "Titans" (TTAN) Onboarding — On-Chain Discovery & Simulation (BNB mainnet, chainId 56)

All data read live via `cast`/forge fork against BNB mainnet. No websites scraped.

## ✅ BROADCAST — LIVE on BNB mainnet (chainId 56)
Executed as admin `0x2e7FaF4a5c5705d87e7AB58c4a879D7F8aDb933C`. All three steps succeeded on-chain:
1. **onboard-assets** — NVDAB + SPCXB configured on the live NAVOracle (VenusOracleAdapter primary,
   secondary disabled) + 100% PoC attestations. Adapters: NVDAB `0x8E00AAADDC258d8F081571D29A9656aD96f4f6b8`,
   SPCXB `0x432A4FBdFb65a43B42262726137F428E40f46767`.
2. **configure-protocol** — deployed + wired into the live factory:
   - PancakeV3SwapAdapter `0x1D34D701358AAC012CD70C3786d23633F5E3F29C` (fees NVDAB=500, SPCXB=2500)
   - ChainlinkOnlyDepegMonitor `0x07Cb968907D81d6B2F3A192738BF58dF50fe3C39`
   - GaugeDistributor `0xE5B30CFf0108224aac528aaC5Bc2E9C515B8AFc8` (stage-5 bonus)
   - EmissionsAutomation `0xEa73cE160aB8d5382dE802Ea113d2FD04e8e2787` (Chainlink upkeep target; holds EMISSIONS_ADMIN)
3. **create-titans** — **Titans (TTAN) Index `0x5479Bd2871c644622882B8f7f933D8084c274733`**
   (share token `0x9377916612421DF7F6aA6d90A00156f3A2e8dE3e`), FixedWeightStrategy
   `0xe597A6C22A385A19C80B1515C5ED68532BB49E99`, NVDAB 40% / SPCXB 60%, quote USDT.

Post-broadcast verification: `factory.isPortfolio(TTAN)=true`, `isTradingSafe(NVDAB/SPCXB)=true`,
`navPerShare=1e18`. **Seed mint done:** 25 USDT -> 24.775 TTAN (0.90% cost), holdings 40/60, navPerShare 1.0 (tx 0x5c64f59c28c0f46b3cce42c3fd4eba92559d8da5533caf3b601235cf714b91c9).

## Final launch decision
- **Titans (TTAN)** = **NVDAB 40% / SPCXB 60%**, quoted in USDT, **zero-fee auto-rebalancing Index**
  (`createIndex` + FixedWeightStrategy). SPCXB-heavy tilt routes mints through its deep pool.
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
into the live factory → `createIndex` TTAN (40/60, zero-fee, FixedWeightStrategy) → user mints 100 USDT.

- allow-list passed for both components; prices sane off Chainlink (NVDAB $194.98, SPCXB $161.95).
- mint of **100 USDT → 97.62 TTAN shares**; index acquired **0.1922 NVDAB (~$37.5)** + **0.3735 SPCXB
  (~$60.5)**; navPerShare ≈ 1.0.
- Cost **~2.4%** (down from ~4.4% at 55/45) — the 40/60 SPCXB tilt shifts volume to its deep pool.
- **Residual NVDAB-pool caveat:** the NVDAB leg (~$40) still slips ~6% because its fee-500 pool is thin, so
  a 100-USDT mint needs a per-tx slippage bound above ~6% (or smaller mints, or a deeper NVDAB/USDT LP).
  `CreateTitans` defaults `MAX_SLIPPAGE_BPS=500`; the sim used 1000 to complete a full 100-USDT mint. The
  clean fix is deeper NVDAB liquidity; until then, keep first mints modest or raise the bound.

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
INDEX_WEIGHTS=4000,6000
INDEX_NAME=Titans
INDEX_SYMBOL=TTAN
```

## Product-type note (TTAN = zero-fee Index)
TTAN is a rules-based **Index** (`createIndex` + FixedWeightStrategy): no management fee, and the admin
rebalancer trades back toward the 40/60 target within the tolerance band. (A management fee would require a
Vault; not used here per your instruction.)
