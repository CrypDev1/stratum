# Stratum Protocol

**The on-chain operating system for tokenized equities.**

Stratum turns any tokenized stock (starting with Binance bStocks on BNB Chain) into a composable, leverageable, tranche-able, and AI-manageable asset. It is a permissionless protocol stack: passive **indexes** and active **vaults** share one core, sit on top of a fair-value oracle, and feed a fee-driven token flywheel.

> bStocks are BEP-20 tokens 1:1 backed by real US shares (NVDA, Micron, Sandisk, Circle, Tesla at launch), trading 24/7 with daily Proof-of-Collateral. Stratum is the demand engine that makes them productive.

---

## Architecture (layered)

| Layer | Module | What it does |
|------|--------|--------------|
| **L0** | Oracle & Proof-of-Collateral | Fair-value NAV for every tokenized equity, including the ~17h/day + weekends the US market is closed. Depeg + collateral-health monitoring. The moat. |
| **L1** | Portfolios (Index + Vault) | One core mints composable BEP-20 Portfolio tokens. Index = rules-based weights, auto-rebalanced. Vault = manager-driven, with mgmt/performance fees. |
| **L2** | Leverage & Yield | Idle assets auto-earn lending yield (Venus/Lista). One-click leveraged portfolios. Portfolio tokens usable as collateral. |
| **L3** | Structured Products | Pendle-style principal/yield splitting and senior/junior tranching on any portfolio. |
| **L4** | Derivatives | 24/7 perps/options on index tokens, priced off the L0 oracle. |
| **L5** | AI-Agent Vaults | On-chain agent-managed portfolios — "AI managing your AI stocks." |
| **★** | Token Flywheel | ve-tokenomics + gauge voting; protocol fees from every layer route to lockers who direct incentive emissions. |

The viral surface: **permissionless one-click thematic ETFs** — anyone tokenizes a thesis ("AI Capex", "Memory Supercycle"), instantly tradeable, leverageable, tranche-able.

---

## Repo layout

```
stratum/
├── src/
│   ├── oracle/          # L0 — NAVOracle, ProofOfCollateral, price adapters
│   ├── core/            # L1 — PortfolioFactory, PortfolioToken, Index/Vault logic
│   ├── leverage/        # L2 — yield routing + leverage looping adapters
│   ├── structured/      # L3 — tranching + principal/yield split
│   ├── derivatives/     # L4 — perps/options engine
│   ├── agents/          # L5 — AI-agent vault framework
│   ├── token/           # ★  — STRAT token, veSTRAT, GaugeController, FeeDistributor
│   ├── interfaces/      # shared interfaces
│   └── libraries/       # shared math / utils
├── test/                # Forge tests (unit, fuzz, invariant) mirroring src/
├── script/              # deployment + config scripts
├── BUILD_PROMPT.md      # ← give this to Claude Code to build everything
├── foundry.toml
└── README.md
```

---

## Quickstart (in Codespaces)

```bash
# 1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 2. Install deps
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std

# 3. Build + test
forge build
forge test -vvv
```

Then launch Claude Code and paste:
> Read BUILD_PROMPT.md and implement the protocol exactly as specified, layer by layer, with full test coverage. Start with L0.

---

## Status

🚧 Pre-alpha — contracts under active development. Nothing here is audited. Not financial advice.

## License

MIT
