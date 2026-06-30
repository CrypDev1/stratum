# WHAT I NEED FROM YOU

Everything below is additive on top of the live BNB-mainnet core (chainId 56). I did **not**
touch or redeploy any core contract. Provide the addresses/env, run the scripts in order, and host
the two keepers.

---

## A. Real mainnet addresses I need from you

### A1. Per bStock you want live — one row each (REQUIRED, blocks Priority 1)
| Item | Why | Notes |
|---|---|---|
| **bStock token address** | the asset to onboard | BEP-20, 18-dec assumed |
| **Chainlink feed address** | **PRIMARY** fair-value source | the asset's Chainlink aggregator on BNB (USD). Wired via the existing `ChainlinkAdapter`, scaled to 18-dec |
| **bStock/USDT PancakeSwap V3 pool address** | **SECONDARY** deviation check + depeg DEX side | must be a **V3** pool (has `observe()`); confirm ≥ `TWAP_WINDOW` of observation history (grow `observationCardinalityNext` if needed) |

> Oracle wiring (per your instruction): **Chainlink is primary**; the PancakeSwap **TWAP is the secondary
> deviation sanity-check** (NAVOracle flags the price stale if Chainlink vs TWAP deviate beyond
> `MAX_DEVIATION_BPS`) and the DepegMonitor DEX source (market price vs Chainlink fair value).
> Note: the deployed NAVOracle uses `secondary` only as a cross-check, **not** an automatic failover — if
> Chainlink goes stale the price is flagged stale, it does not silently switch to the TWAP (core design).
> If a bStock only has a **V2** pair (no `observe()`), tell me — that needs a different (stateful) TWAP keeper.
> All three arrays (`BSTOCK_TOKENS` / `CHAINLINK_FEEDS` / `BSTOCK_POOLS`) must be equal length, same order.

### A2. PancakeSwap infra (REQUIRED, blocks swaps)
| Env | What | Notes |
|---|---|---|
| `PANCAKE_V3_ROUTER` | PancakeSwap **V3 SwapRouter** | execution venue for `PancakeV3SwapAdapter` |
| `STABLE_TOKEN` | USDT (or USDC) on BNB | the $1 numéraire + portfolio quote |

### A3. Venus (REQUIRED only if you want Earn/Venus)
| Env | What | Notes |
|---|---|---|
| `VENUS_VTOKEN` | the Venus **vToken** market for `STABLE_TOKEN` (e.g. vUSDT) | Compound-fork VBep20 |
| `BLOCKS_PER_YEAR` | BSC blocks/year | for APR annualization; default `10512000` (~3s); update if BSC block time differs |

### A4. Lista (REQUIRED only if you want Earn/Lista)
| Env | What | Notes |
|---|---|---|
| `LISTA_VAULT` | the Lista interest-bearing vault for `STABLE_TOKEN` | **must be ERC-4626.** If Lista's lending core (Moolah/peer-to-peer) is what you want instead, tell me — it is *not* 4626 and needs a dedicated adapter. |
| `LISTA_APR_BPS` | initial reported APR (bps) | only used for router ranking; the keeper can update it |

### A5. Perps (REQUIRED only if you want the perp market)
| Env | What |
|---|---|
| `PERP_MARKET` | the bStock whose live NAV is the perp mark price |
| `POOL_SEED_AMOUNT` / `INSURANCE_SEED_AMOUNT` | stable to seed the LP counterparty + insurance fund |

### A6. Leverage (REQUIRED only if you want the leverage module)
| Env | What |
|---|---|
| `LEVERAGE_PORTFOLIO` | the Index/Vault portfolio used as collateral |

> Then fund its borrow reserve with stable via `LeverageModule.fundReserve(amount)` — the module
> lends from its **own** reserve (isolated), there is no external borrow venue in the contract.

### A7. Admin / signer
- `ADMIN` / `PRIVATE_KEY`: the EOA that holds the admin roles on the live core
  (`ORACLE_ADMIN`, `ATTESTOR`, `DEPEG_ADMIN`, `FACTORY_ADMIN`, `MARKET_KEEPER`, `EMISSIONS_ADMIN`,
  `GAUGE_ADMIN`). You said you hold admin — confirm this EOA does.

---

## B. Run order (each: `forge build && forge test`, then broadcast)

1. **Onboard assets** → `script/OnboardAssets.s.sol` (needs A1, A7). After this the factory accepts
   the bStocks and they price/trade-gate.
2. **Wire swap adapter + optional Earn/Perp/Leverage** → `script/ConfigureProtocol.s.sol` (needs A2;
   A3/A4/A5/A6 enable the optional stages). Idempotent; pass back printed addresses to re-run safely.
3. **Seed perps** (if used) → `script/SeedPerp.s.sol` (needs A5 + the deployed pool/engine).
4. **Create a gauge per product** (optional) → `script/CreateGauge.s.sol` (needs `GAUGE`).

---

## C. Env var names (exact) — see `.env.example` for the full annotated list
`PRIVATE_KEY` `ADMIN` `NAV_ORACLE` `PROOF_OF_COLLATERAL` `DEPEG_MONITOR` `PORTFOLIO_FACTORY`
`EMISSIONS_MINTER` `GAUGE_CONTROLLER` `STABLE_TOKEN` `PANCAKE_V3_ROUTER`
`BSTOCK_TOKENS` `CHAINLINK_FEEDS` `BSTOCK_POOLS` `TWAP_WINDOW` `MAX_STALENESS` `MAX_CLOSED_STALENESS`
`MAX_DEVIATION_BPS` `MAX_DRIFT_BPS`
`VENUS_VTOKEN` `BLOCKS_PER_YEAR` `LISTA_VAULT` `LISTA_APR_BPS` `EARN_IDLE_BUFFER_BPS`
`PERP_MARKET` `POOL_SEED_AMOUNT` `INSURANCE_SEED_AMOUNT` `PERP_LIQUIDITY_POOL` `PERP_ENGINE`
`LEVERAGE_PORTFOLIO` `LEVERAGE_MODULE` `GAUGE`
`STRAT` `GAUGE_DISTRIBUTOR` `SWAP_ADAPTER` `EARN_YIELD_ROUTER`
Keepers: `RPC_URL` `EMISSIONS_RECIPIENT` `MIN_MINTABLE_WEI` `ASSETS` `MODE` `DRY_RUN`
Fork test: `FORK_RPC` `VENUS_UNDERLYING_WHALE`

---

## D. Keepers YOU must host (see `keepers/README.md`)
1. **Emissions keeper** (`keepers/emissions-keeper.js`) — pushes the 300M schedule. Cron hourly–daily.
   Holds `EMISSIONS_ADMIN`.
2. **Market-status + depeg keeper** (`keepers/market-status-keeper.js`) — maintains the US-hours
   open/closed flag and monitors depeg. Cron ~5 min. Holds `MARKET_KEEPER`.

Neither keeper is required for basic reads/trading — they only maintain flags and push emissions.

---

## E. Things NOT reachable via admin on the live core (I did NOT fork — flagging instead)

1. **Idle assets of the already-deployed Index/Vault portfolios cannot be auto-routed to yield.**
   `PortfolioBase` has no yield-router hook or admin setter. Earn ships as a **standalone** product
   (users deposit into the new `YieldRouter` directly). Auto-deploying portfolio idle cash would
   require a core change.
2. ~~No on-chain per-gauge emissions distributor.~~ **RESOLVED — built `GaugeDistributor`** (additive,
   `src/token/GaugeDistributor.sol`). Point `EmissionsMinter.emitTo` at it (`EMISSIONS_RECIPIENT`);
   `distribute()` splits new STRAT across gauges by veSTRAT-voted weight; `claim(gauge)` pays the
   gauge's admin-set receiver (default the gauge). Deployed by `ConfigureProtocol.s.sol` (stage 5) and
   driven by the emissions keeper. You only need to: set `EMISSIONS_RECIPIENT`/`GAUGE_DISTRIBUTOR`, and
   (optionally) configure a `rewardReceiver` per gauge via `setRewardReceiver`.
3. **Proof-of-Collateral is a manual 100% attestation** (`OnboardAssets` posts `10000` bps, with a
   TODO). Wiring Binance's real PoC feed needs that feed's address/format from you.

If any of E1/E2 matters for launch, say the word and I'll build the additive contract for it.
