# Stratum Build Progress

Foundry + Solidity 0.8.26, `via_ir=true`, OZ v5.6.1, forge-std v1.16.1.

## Layer status

- [x] **L0 — Oracle & Proof-of-Collateral** ✅ build green, 55 tests pass
- [x] **L1 — Portfolios: Index + Vault** ✅ build green, 49 tests pass (incl. invariants)
- [x] **L2 — Leverage & Yield** ✅ build green, 28 tests pass (incl. invariants)
- [x] **L3 — Structured Products** ✅ build green, 17 tests pass
- [x] **L4 — Derivatives** ✅ build green, 18 tests pass
- [x] **L5 — AI-Agent Vaults** ✅ build green, 14 tests pass
- [x] **★ Token Flywheel** ✅ build green, 26 tests pass
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

---

## L1 — Portfolios: Index + Vault ✅

| Contract | Status | Notes |
|---|---|---|
| `core/PortfolioToken` | ✅ | ERC20 share, mint/burn restricted to manager |
| `core/PortfolioBase` | ✅ | Cloneable NAV engine; NAV-fair mint, in-kind oracle-free redeem |
| `core/IndexPortfolio` | ✅ | Strategy-driven rebalance, tolerance band + per-asset max-trade cap |
| `core/VaultPortfolio` | ✅ | Manager executeTrade (whitelist + per-trade cap), streaming + HWM perf fees |
| `core/FeeManager` | ✅ | Pure dilution fee math, capped, fuzzed |
| `core/PortfolioFactory` | ✅ | Clone deploy, L0 health whitelist, forced protocol cut |
| `core/strategies/FixedWeightStrategy`,`MarketCapWeightStrategy` | ✅ | Pluggable weights |
| `mocks/MockSwapRouter` | ✅ | Parity DEX with settable slippage |

**Tests (49):** mint/redeem NAV fairness (fuzz), **arbitrage peg invariant** + **fully-backed invariant**
(128k calls, 0 reverts), rebalance toward target within caps, fee accrual + HWM correctness,
executeTrade guardrails (whitelist/size), factory whitelist enforcement, pause leaves redeem open.

### Design decisions
- **Redeem is in-kind and oracle-independent** — works while paused or oracle stale, so users can always
  exit. Mint requires fresh prices + `isTradingSafe` per component.
- Fees are charged by **share dilution**; Vault accrues on the *pre-deposit* state so a new depositor
  never pays a performance fee on their own capital.
- The **quote stablecoin is not gated** on the depeg breaker (no equity feed); only equity components are.
- NAV excludes transient idle quote; `navBefore` is snapshotted before pulling quote so
  `added = navAfter - navBefore` equals the deposited value at swap parity → exact NAV-fair shares.
- Each portfolio deploys its own `PortfolioToken` (not a clone) in `initialize` — clean manager binding.

### TODO(integration)
- PancakeSwap V2/V3 router adapter to replace `MockSwapRouter`.

---

## L2 — Leverage & Yield ✅

| Contract | Status | Notes |
|---|---|---|
| `leverage/MoneyMarketYieldAdapter` (+ `VenusYieldAdapter`,`ListaYieldAdapter`) | ✅ | Wrap money market → IYieldAdapter |
| `leverage/YieldRouter` | ✅ | Best-rate allocation, idle buffer for redemptions |
| `leverage/LeverageModule` | ✅ | Isolated-margin looping leverage, HF checks, deleverage, liquidate |
| `leverage/LeveragedIndex` | ✅ | Single-token target-leverage product, leverage rebalancing |
| `mocks/MockMoneyMarket` | ✅ | Index-accruing lending mock |

**Tests (28):** yield routing to best rate, idle-buffer maintenance, divest-on-withdraw, yield accrual;
**no-value-lost** + accounting-identity invariants (128k calls); leverage open/HF/leverage caps;
**liquidation only when HF<1 AND trading safe**, **no liquidation when circuit-breaker halted**;
deleverage/repay/close; LeveragedIndex fair deposit/withdraw + closed-form leverage rebalance.

### Design decisions
- LeverageModule borrows from an internal **stable reserve** (LP-funded); the lent principal returns on
  repay/close — no external lending integration needed for the core (TODO: real Venus/Lista borrow).
- Liquidation requires **every component `isTradingSafe`** — a tripped breaker blocks liquidations so
  positions aren't closed on bad/halted prices.
- Debt is USD-pegged (stable = quote); a borrow-rate accrual models the **leverage spread** fee.
- `LeveragedIndex` rebalance uses the closed form `delta = Lt·equity − collateral` so borrowing's own
  collateral purchase is accounted for (hits target in one step).

### TODO(integration)
- Real Venus vToken / Lista market wiring; real DEX router for deleverage sells.

---

## L3 — Structured Products ✅

| Contract | Status | Notes |
|---|---|---|
| `structured/ControlledToken` | ✅ | Controller-minted ERC20 with optional transfer-settle hook |
| `structured/YieldSplitter` | ✅ | PT/YT split, per-token yield accumulator, maturity redemption |
| `structured/TrancheVault` | ✅ | Senior/Junior waterfall, coverage ratio, in-kind settlement |

**Tests (17):** PT+YT **reconstruct-the-wrapped-asset invariant** (fuzzed yield) + principal always
backed; yield accrual/claim; combine; maturity principal redemption; tranche waterfall under
gain/loss/severe-loss; **senior-priority-over-junior invariant** (fuzzed return); coverage-breach reject.

### Design decisions
- **In-kind settlement** everywhere: PT/YT and tranche tokens redeem the underlying *portfolio shares*,
  so structured products never force-sell into the market (consistent with L1's redeem philosophy).
- YT yield uses a **per-token accumulator** settled on transfer via the ControlledToken hook, so YT is
  freely transferable while yield follows the pre-transfer holder.
- `YieldSplitter` assumes a non-decreasing wrapper index (a yield-bearing token), keeping PT principal
  backed; the reconstruct invariant `underlyingValue == ptValue + ytValue` holds by construction.
- Tranche waterfall pays **Senior first up to its capped claim**, Junior the residual/first-loss.

### TODO(integration)
- Origination fee wiring through `FeeManager` (currently structural; waterfall is the tested core).
- Post-maturity YT yield freeze (currently yield can keep accruing after maturity).

---

## L4 — Derivatives ✅

| Contract | Status | Notes |
|---|---|---|
| `derivatives/LiquidityPool` | ✅ | Vault-backed counterparty, LP shares, engine-only payouts |
| `derivatives/PerpEngine` | ✅ | Isolated-margin perps, NAV-marked (after-hours aware), funding, liquidations, insurance fund |
| `OptionsVault` | ⏳ | Deferred (explicitly optional in the spec) |

**Tests (18):** open gated on fresh oracle + isTradingSafe; long/short PnL; loss-to-pool; funding accrual
with skew; **leverage cap**; **liquidation when under maintenance**, **no liquidation when halted**;
insurance-fund solvency; **PnL conservation invariant** (no stable created/destroyed, fuzzed price/side);
LP share-value math.

### Design decisions
- The **LiquidityPool is the sole counterparty**: trader profit is paid by the pool, loss flows to the
  pool, funding flows trader↔pool. This makes **PnL conservation** structural (all flows are transfers).
- **Funding** is skew-proportional (`coef · (OI_long−OI_short)/OI`), accumulated in a signed index;
  +ve index ⇒ longs pay. Symmetric so a balanced book nets ~zero through the pool.
- Opens require fresh oracle AND `isTradingSafe`; **liquidations are blocked while halted** (same as L2).
- **Bad debt** beyond a trader's margin draws on the **insurance fund**; open/liquidation fees feed it.

### TODO(integration)
- `OptionsVault` (cash-settled European options vs NAV at expiry).
- Utilization-based dynamic funding curve refinement.

---

## L5 — AI-Agent Vaults ✅

| Contract | Status | Notes |
|---|---|---|
| `agents/AgentPolicy` | ✅ | Hard guardrails: whitelist, max position, epoch turnover, drawdown kill, timelock |
| `agents/AgentVault` | ✅ | VaultPortfolio whose manager is the agent; every trade gated by the policy |
| `agents/AgentRegistry` | ✅ | Append-only, vault-only track-record accounting |

**Tests (14):** agent trades within policy; **turnover/position/whitelist guardrails reject** out-of-bounds
actions (+ fuzzed malicious agent stays bounded); **drawdown kill switch halts the vault**; timelocked
param changes; registry **only-vault reporting + append-only** track record.

### Design decisions
- "**Agent proposes, policy disposes**": `AgentVault.executeTrade` checkpoints NAV (drawdown), runs the
  swap, then calls `AgentPolicy.recordTrade`; any breach reverts the whole action atomically.
- Policy params are **governance-owned and timelocked** — the agent can never widen its own limits.
- **NAV now counts idle quote 1:1** (the USD numéraire) so an agent trading a component into the
  stablecoin doesn't spuriously move NAV / trip the drawdown switch. (Also tightens L1 accounting.)
- `AgentRegistry` is tamper-evident: only the bound vault reports, history is append-only.

---

## ★ Token Flywheel ✅

| Contract | Status | Notes |
|---|---|---|
| `token/STRAT` | ✅ | Capped ERC20, MINTER-gated |
| `token/EmissionsMinter` | ✅ | Linear emission, never exceeds schedule, decay via rate change |
| `token/veSTRAT` | ✅ | Curve-style lock, decaying power, global point + slope changes |
| `token/GaugeController` | ✅ | veSTRAT-weighted gauge votes, normalized relative weights |
| `token/FeeDistributor` | ✅ | Per-epoch pro-rata fee distribution to lockers |
| `BribeMarket` | ⏳ | Deferred (explicitly optional) |

**Tests (26):** emissions linear + **never exceed schedule** (fuzz); ve **lock/decay math** (fuzz),
increase amount/time, withdraw; gauge **weight normalization** (sums to 1e18), re-vote/over-allocation;
fee distribution pro-rata, **no-double-claim**, **claims never exceed rewards** (fuzz).

### Design decisions
- `veSTRAT` uses the canonical Curve global point (`bias − slope·Δt`) with **scheduled slope changes** at
  each lock's expiry, so `totalSupply()` decays correctly without iterating holders.
- `GaugeController` records voting power at vote time (weekly cadence) and replaces a voter's prior
  allocation on re-vote — no double counting; `relativeWeight` normalizes to 1e18.
- `FeeDistributor` is **epoch-based**: lockers `checkpoint` their power into an epoch, rewards split
  pro-rata, claims are one-shot per epoch → no double-claim, no over-distribution.

### TODO(integration)
- `BribeMarket` for vote incentives; wire each Index/Vault/Perp module to forward fees to FeeDistributor.
