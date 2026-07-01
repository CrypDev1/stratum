# Stratum Protocol — Architecture

Stratum turns tokenized equities (Binance **bStocks** on BNB Chain) into composable, leverageable,
tranche-able, AI-manageable assets. The stack is built in layers; **higher layers depend only on the
interfaces of lower layers** (`src/interfaces/`), never on concrete implementations — so each layer is
independently testable and upgradeable.

## Layer dependency graph

```mermaid
graph TD
    subgraph L0["L0 — Oracle & Proof-of-Collateral (the moat)"]
        NAV[NAVOracle<br/>fair value, after-hours drift]
        POC[ProofOfCollateral<br/>backing attestations]
        DEPEG[DepegMonitor<br/>circuit breaker]
        ADP[ChainlinkAdapter / Adapters]
        ADP --> NAV
        NAV --> DEPEG
    end

    subgraph L1["L1 — Portfolios (the core)"]
        BASE[PortfolioBase<br/>NAV-fair mint/redeem]
        IDX[IndexPortfolio]
        VLT[VaultPortfolio]
        FAC[PortfolioFactory<br/>clones + whitelist]
        FEE[FeeManager]
        STRAT_W[Weight Strategies]
        BASE --> IDX
        BASE --> VLT
        FAC --> IDX
        FAC --> VLT
        STRAT_W --> IDX
        FEE --> VLT
    end

    subgraph L2["L2 — Leverage & Yield"]
        YR[YieldRouter]
        YA[Venus/Lista YieldAdapters]
        LEV[LeverageModule]
        LIDX[LeveragedIndex]
        YA --> YR
        LEV --> LIDX
    end

    subgraph L3["L3 — Structured Products"]
        SPLIT[YieldSplitter<br/>PT / YT]
        TRANCHE[TrancheVault<br/>Senior / Junior]
    end

    subgraph L4["L4 — Derivatives (24/7)"]
        PERP[PerpEngine]
        LP[LiquidityPool]
        LP --> PERP
    end

    subgraph L5["L5 — AI-Agent Vaults"]
        AV[AgentVault]
        AP[AgentPolicy<br/>hard guardrails]
        AR[AgentRegistry]
        AP --> AV
    end

    subgraph STAR["★ Token Flywheel"]
        TOK[STRAT + EmissionsMinter]
        VE[veSTRAT]
        GC[GaugeController]
        FD[FeeDistributor]
        TOK --> VE --> GC
        VE --> FD
    end

    NAV -.IPriceOracle/INAVOracle.-> BASE
    DEPEG -.IDepegMonitor.-> BASE
    POC -.IProofOfCollateral.-> FAC
    BASE -.IPortfolio.-> LEV
    BASE -.IPortfolio.-> SPLIT
    BASE -.IPortfolio.-> TRANCHE
    VLT -.extends.-> AV
    NAV -.mark price.-> PERP
    DEPEG -.risk gate.-> PERP
    DEPEG -.liquidation gate.-> LEV
    FAC -.fees.-> FD
    PERP -.funding fees.-> FD
    GC -.directs emissions.-> IDX
```

## Interface boundaries

| Interface | Defined by | Consumed by |
|---|---|---|
| `IPriceOracle` / `INAVOracle` | L0 `NAVOracle` | L1 `PortfolioBase`, L2 `LeverageModule`, L4 `PerpEngine`, strategies |
| `IProofOfCollateral` | L0 `ProofOfCollateral` | L1 `PortfolioFactory` (whitelist) |
| `IDepegMonitor` | L0 `DepegMonitor` | L1 mint/redeem, L2 liquidations, L4 opens |
| `ISwapRouter` | adapter (PancakeSwap) | L1 allocation/rebalance, L2 deleverage |
| `IWeightStrategy` | L1 strategies | `IndexPortfolio.rebalance` |
| `IPortfolio` | L1 `PortfolioBase` | L2/L3/L4 wrappers |
| `IYieldAdapter` / `IMoneyMarket` | L2 adapters | `YieldRouter` |
| `IFeeManager` | L1 `FeeManager` | `VaultPortfolio`, structured products |

## Cross-cutting safety model

- **One circuit breaker.** `DepegMonitor.isTradingSafe(asset)` is the single pre-trade gate consulted
  before every mint/redeem/leverage-open/perp-open/liquidation. A tripped breaker (manual halt, oracle
  stale, or DEX↔NAV depeg over threshold) blocks new risk — and blocks liquidations so positions are
  never closed on bad prices.
- **Oracle-independent exits.** L1 `redeem` (and L3 in-kind settlement) never read prices, so users can
  always exit even if the oracle is stale or the contract is paused.
- **NAV-fair accounting.** Mint shares = depositValue · supply / NAV; redeem is pro-rata in-kind. The
  `fully-backed` and `arbitrage-peg` invariants are fuzzed over 100k+ calls.
- **Conservation invariants.** Perp PnL conservation, tranche waterfall priority, PT+YT reconstruction,
  yield no-value-lost, and fee no-double-claim are each enforced by invariant/fuzz tests.
- **Guardrails over trust.** AI agents (`AgentVault`) propose; `AgentPolicy` disposes — whitelist, max
  position, epoch turnover and a drawdown kill switch the agent can never widen (timelocked governance).
