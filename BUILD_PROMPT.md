# Claude Code Build Prompt — Stratum Protocol

> Paste this entire file's intent to Claude Code, or simply tell it:
> **"Read BUILD_PROMPT.md and implement the protocol exactly as specified, layer by layer, with full test coverage. Begin with L0 and do not move to the next layer until the current one builds and all its tests pass."**

---

## 0. Your role and operating rules

You are building **Stratum Protocol**, a permissionless smart-contract stack that turns tokenized equities (Binance **bStocks**, BEP-20 tokens 1:1-backed by real US shares on BNB Chain) into composable, leverageable, tranche-able, AI-manageable assets.

**Hard rules — follow all of them:**

1. **Stack:** Foundry + Solidity `0.8.26`, `via_ir = true`, optimizer on. Use OpenZeppelin contracts for ERC20/access/security primitives (`forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std`). Add remappings in `remappings.txt`.
2. **Build layer by layer (L0 → ★).** Do not start a layer until the previous one compiles and its tests pass. After each layer: run `forge build` and `forge test`, fix everything, then commit with a clear message (`feat(l0): NAV oracle + proof-of-collateral`).
3. **Every contract gets tests.** Unit tests for all external functions, fuzz tests for all math/accounting, and invariant tests for the core accounting (e.g. "Portfolio token supply is always fully backed by underlying value"). Target meaningful coverage, not vanity numbers — test the dangerous paths.
4. **Security-first.** Use `ReentrancyGuard` on all state-changing external calls that touch tokens; checks-effects-interactions everywhere; `SafeERC20`; pausability via `Pausable`; role-based access via `AccessControl` (no single `onlyOwner` god-mode in production modules); explicit slippage/deadline params on all swaps; no unbounded loops over user-supplied arrays without a cap. Add a `// SECURITY:` NatSpec note on every function handling value.
5. **Full NatSpec** (`@notice`, `@dev`, `@param`, `@return`) on every public/external function and every contract.
6. **No placeholders left behind.** If you stub something (e.g. an external DEX router), define a clean interface, write a mock for tests, and leave a clearly marked `// TODO(integration):` with what real address/adapter is needed. Never leave a function silently unimplemented.
7. **Gas-aware** but correctness-first. Use custom errors (not revert strings), `immutable`/`constant` where possible, and pack storage.
8. **Modularity.** Layers communicate only through interfaces in `src/interfaces/`. A higher layer must never import a lower layer's concrete implementation directly — always the interface. This keeps every layer independently testable and upgrade-friendly.
9. **Keep a running `PROGRESS.md`** at the repo root: check off each contract as built + tested, and note any design decisions or open questions.

Directory layout to follow:

```
src/{oracle,core,leverage,structured,derivatives,agents,token,interfaces,libraries}
test/  (mirrors src/)
script/
```

---

## L0 — Oracle & Proof-of-Collateral (the moat)

**Goal:** a reliable fair-value NAV for every tokenized equity, including the ~17h/day + weekends the underlying US market is closed, plus collateral-health monitoring.

Build:

- **`IPriceOracle`** interface: `getPrice(address asset) returns (uint256 price, uint256 updatedAt, bool isStale)` — 18-decimal USD price.
- **`NAVOracle`**: aggregates one or more price sources per asset. Support a **primary feed** (e.g. Chainlink-style `AggregatorV3` adapter) and a **fallback fair-value model** used when the market is closed or the primary is stale. Track `marketOpen` status per asset (configurable trading-hours calendar, settable by a `MARKET_KEEPER` role). When closed, return last close adjusted by an optional, bounded "implied" drift input signed by an oracle keeper, and flag the value as `afterHours = true`. Enforce a max-staleness window and a max deviation guard between sources.
- **`ProofOfCollateral`**: stores periodic attestations (per asset: backing ratio, attestation timestamp, source hash). Expose `isHealthy(asset)` (backing ≥ threshold AND attestation fresh) and a `collateralRatio(asset)`. Emit events on every update and on any breach.
- **`DepegMonitor`**: compares an asset's market (DEX) price vs NAVOracle fair value; exposes `depegBps(asset)` and a circuit-breaker `isTradingSafe(asset)` that higher layers MUST consult before minting/redeeming/liquidating.
- **Adapters:** `ChainlinkAdapter`, and a `MockOracleAdapter` for tests. Provide a `PriceLib` library for scaling decimals safely.

**Tests:** fuzz price scaling; staleness + deviation guards; market-open/closed transitions; depeg circuit-breaker triggers; PoC breach events.

---

## L1 — Portfolios: Index + Vault (the core)

**Goal:** one core that mints composable BEP-20 **Portfolio tokens** representing a fully-backed basket of underlying tokenized equities. `Index` = rules-based; `Vault` = manager-driven. Same accounting engine.

Build:

- **`PortfolioToken`** (ERC20, BEP-20 compatible): the tradeable share. Decimals 18. Mint/redeem only by its `PortfolioManager`.
- **`IPortfolio`** interface + **`PortfolioBase`** (shared logic): holds underlying components `{address asset, uint256 weightBps}[]`, computes `totalNAV()` via `NAVOracle`, `navPerShare()`, and handles **mint** (deposit underlying or a single quote asset → receive shares) and **redeem** (burn shares → receive pro-rata underlying). Mint/redeem must be NAV-fair so external arbitrage keeps the token pegged. All swaps go through an injected **`ISwapRouter`** adapter (PancakeSwap on BNB Chain) with slippage + deadline.
- **`IndexPortfolio`** (extends base): immutable-ish rules. A `REBALANCER` role (or permissionless keeper with a guard) can call `rebalance()` which reads target weights from a `IWeightStrategy` and trades toward them within tolerance + max-trade-size caps. Provide two strategies: `FixedWeightStrategy` and `MarketCapWeightStrategy` (interface-driven so more can be added).
- **`VaultPortfolio`** (extends base): a `manager` address controls allocations via `setTargetWeights()` / `executeTrade()` within guardrails (whitelisted assets, max leverage = 1x here, per-trade caps). Charges a streaming **management fee** and a high-water-mark **performance fee** via a `FeeManager`. Depositors get vault shares; manager and protocol split fees.
- **`PortfolioFactory`**: permissionless deployment of new Index or Vault portfolios (clone pattern / minimal proxies for gas). Registers them, sets the protocol fee cut, and enforces an asset whitelist sourced from L0 (only assets with healthy PoC + safe trading status can be included).
- **`FeeManager`**: streaming + performance + protocol fees, with high-water-mark accounting.

**Tests:** mint/redeem NAV fairness (fuzz); arbitrage peg invariant (`token value ≈ underlying value` always); rebalance stays within tolerance; fee accrual + high-water-mark correctness; factory whitelist enforcement; reentrancy on mint/redeem.

---

## L2 — Leverage & Yield engine

**Goal:** make idle assets productive and offer one-click leverage.

Build:

- **`IYieldAdapter`** + **`VenusYieldAdapter`** / **`ListaYieldAdapter`** (interface + mocks for test): deposit idle underlying into a money market, track yield, withdraw on redeem. A `YieldRouter` decides allocation across adapters by best rate, with a configurable idle buffer for redemptions.
- **`LeverageModule`**: one-click looping — deposit Portfolio token as collateral → borrow stablecoin → buy more underlying → repeat to a target leverage, with a hard max-leverage cap, health-factor checks against L0 prices, and a `deleverage()` + `liquidate()` path (liquidations gated by `DepegMonitor.isTradingSafe`).
- **`LeveragedIndex`**: a productized wrapper that exposes a target-leverage index as a single token, rebalancing leverage as price moves.

**Tests:** yield routing math; idle buffer always covers expected redemptions (invariant); leverage health-factor enforcement; liquidation only when unsafe; no liquidation when trading is halted by circuit-breaker.

---

## L3 — Structured Products (tranching + PT/YT)

**Goal:** split risk/return on any portfolio.

Build:

- **`YieldSplitter`**: wraps a yield-bearing Portfolio token and mints **PT** (principal) and **YT** (yield) tokens with a maturity; redeem PT 1:1 at maturity, YT accrues yield until then. (Pendle-style.)
- **`TrancheVault`**: deposits into a base portfolio and issues **Senior** (capped, protected return, first claim) and **Junior** (leveraged, residual, first-loss) tranche tokens. Waterfall distribution on settlement; senior coverage ratio enforced.
- Reuse `FeeManager` for origination fees.

**Tests:** PT+YT value always reconstructs the wrapped asset (invariant); maturity redemption; tranche waterfall correctness under gain/loss scenarios (fuzz the underlying return); senior never paid less than junior in a loss until junior is wiped (invariant).

---

## L4 — Derivatives (24/7 perps/options on index tokens)

**Goal:** round-the-clock leveraged exposure priced off the L0 oracle.

Build:

- **`PerpEngine`**: isolated-margin perpetuals on a Portfolio/index token. Mark price = `NAVOracle` fair value (after-hours aware). Funding-rate mechanism, position open/close, margin, liquidation engine, and an insurance fund. All risk checks consult `DepegMonitor` (widen margins / halt opens when trading unsafe or oracle stale).
- **`OptionsVault`** (optional if time allows): cash-settled European calls/puts settled against NAVOracle at expiry.
- A simple `LiquidityPool` (vault-backed) acting as counterparty, with caps and utilization-based funding.

**Tests:** funding accrual; margin + liquidation correctness (fuzz price paths); insurance-fund solvency invariant; no new positions when oracle stale/halted; PnL conservation invariant (sum of trader PnL + LP PnL + fees = 0 minus protocol fee).

---

## L5 — AI-Agent Vaults

**Goal:** agent-managed tokenized-tech-stock portfolios — the "AI managing your AI stocks" narrative — implemented safely on-chain.

Build:

- **`AgentVault`** (extends `VaultPortfolio`): instead of a human manager, an authorized **agent executor** (an off-chain signer / keeper bound to an on-chain policy) submits rebalances. The on-chain **`AgentPolicy`** enforces hard guardrails the agent CANNOT violate: whitelisted assets, max position size, max turnover per epoch, max drawdown kill-switch, and a timelock on parameter changes. The agent proposes; the policy disposes.
- **`AgentRegistry`**: registers agent strategies with public, on-chain performance/track-record accounting (so the vault marketplace can rank them trustlessly).

**Tests:** policy guardrails reject out-of-bounds agent actions (fuzz malicious agent inputs); drawdown kill-switch halts the vault; track-record accounting is tamper-evident.

---

## ★ Token Flywheel (ve-tokenomics + gauges)

**Goal:** capture fees from every layer and route them to align creators, managers, and holders.

Build:

- **`STRAT`** (ERC20 governance/utility token, capped supply, with an emissions schedule contract `EmissionsMinter`).
- **`veSTRAT`**: vote-escrow lock (Curve-style: lock STRAT for up to N years → non-transferable veSTRAT, decaying with time).
- **`GaugeController`**: veSTRAT holders vote weekly on gauge weights; each Index/Vault can have a gauge that directs STRAT emissions to its depositors/LPs.
- **`FeeDistributor`**: collects protocol fees from L1–L4 (creation, mgmt/perf, leverage spread, tranche origination, perp funding) and distributes to veSTRAT lockers pro-rata.
- **`BribeMarket`** (optional): lets portfolio creators incentivize veSTRAT voters to direct emissions to their gauge.

**Tests:** ve lock/decay math (fuzz); gauge weight normalization; fee distribution accounting (no fees lost or double-claimed — invariant); emissions never exceed schedule.

---

## Deployment & scripts

- `script/Deploy.s.sol`: deploys the full stack to BNB testnet in dependency order (L0 → ★), wiring addresses via a `Config` struct. Parameterize via env (`.env.example` provided).
- Provide a `DeployMocks.s.sol` that stands up mock bStocks + mock oracle + mock DEX so the whole system can be exercised on a local Anvil fork without external dependencies.
- Add a `Makefile` with `build`, `test`, `fmt`, `snapshot`, `deploy-testnet`, `coverage` targets.

---

## Definition of done

- `forge build` clean, `forge test` green (unit + fuzz + invariant) for every layer.
- `forge coverage` run and summarized in `PROGRESS.md`.
- Every external value-handling function has NatSpec + a `// SECURITY:` note.
- `slither .` runs (if available) with all findings either fixed or explicitly justified in `PROGRESS.md`.
- A short `ARCHITECTURE.md` diagram (mermaid) showing how the layers connect via interfaces.
- Mock-based end-to-end test: create an "AI Index" → mint → earn yield → split into PT/YT → open a perp against it → vote a gauge → claim fees. One test proving the whole stack composes.

**Start now with L0. Build it, test it, commit it, then continue.**
