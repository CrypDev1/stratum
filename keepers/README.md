# Stratum Keepers

Two self-contained off-chain jobs. **Neither is required for basic reads** — onboarded assets
price and trade-gate off the live PancakeSwap TWAP feed regardless. The keepers only (a) push the
emissions schedule and (b) maintain the market open/closed flag and surface depeg status.

Both are **one-shot per invocation** (they do one pass and exit), designed for a scheduler:
cron, systemd timers, GitHub Actions `schedule`, or Gelato Web3 Functions.

## Install

```bash
cd keepers
npm install        # ethers v6
```

## 1. Emissions keeper — `emissions-keeper.js`

Calls `EmissionsMinter.emitTo(recipient)`, settling whatever has accrued since the last mint.
Safe at any cadence; a no-accrual run is a no-op.

```bash
RPC_URL=$BSC_RPC_URL \
PRIVATE_KEY=0x...                # holds EMISSIONS_ADMIN on the minter \
EMISSIONS_MINTER=0x11e3f4d2c27e37ad7438deac5C143a06381C4816 \
EMISSIONS_RECIPIENT=0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE \
node emissions-keeper.js
```

Optional: `MIN_MINTABLE_WEI` (skip dust mints), `DRY_RUN=true`.

> ⚠️ The deployed `GaugeController` only computes gauge **weights** — it has no on-chain
> distributor that forwards STRAT to gauges by weight. This keeper pushes the schedule to one
> `EMISSIONS_RECIPIENT`; splitting it per gauge needs a distributor contract or an off-chain
> split. See the project's "WHAT I NEED FROM YOU" checklist.

**`cast` equivalent:**
```bash
cast send $EMISSIONS_MINTER "emitTo(address)" $EMISSIONS_RECIPIENT \
  --rpc-url $BSC_RPC_URL --private-key $PRIVATE_KEY
# read-only preview:
cast call $EMISSIONS_MINTER "mintable()(uint256)" --rpc-url $BSC_RPC_URL
```

## 2. Market-status + depeg keeper — `market-status-keeper.js`

`MODE=status` (default): sets each asset's NAVOracle market flag to match US equity hours
(Mon–Fri 09:30–16:00 America/New_York, DST-aware), only when it differs on-chain. `MODE=monitor`:
read-only; logs `isTradingSafe` + `depegBps` for alerting.

```bash
RPC_URL=$BSC_RPC_URL \
NAV_ORACLE=0xbe263035a704E5039aCaB282AB011DF8175526e3 \
DEPEG_MONITOR=0x7EB90C8F1E8E6bcC0C31A13D37271519dBB50D2a \
ASSETS=0xToken1,0xToken2 \
PRIVATE_KEY=0x...                # holds MARKET_KEEPER on the oracle (status mode only) \
MODE=status node market-status-keeper.js
```

Optional: `DRY_RUN=true`. Does **not** account for US market holidays — feed a holiday calendar
or pause the schedule on those days.

**`cast` equivalents:**
```bash
cast send $NAV_ORACLE "setMarketStatus(address,bool)" $ASSET true \
  --rpc-url $BSC_RPC_URL --private-key $PRIVATE_KEY
cast call $DEPEG_MONITOR "isTradingSafe(address)(bool)" $ASSET --rpc-url $BSC_RPC_URL
cast call $DEPEG_MONITOR "depegBps(address)(uint256)" $ASSET --rpc-url $BSC_RPC_URL
```

## Scheduling

**cron** (emissions hourly; market-status every 5 min):
```cron
0  *    * * *  cd /opt/stratum/keepers && RPC_URL=... PRIVATE_KEY=... EMISSIONS_MINTER=... node emissions-keeper.js >> /var/log/strat-emissions.log 2>&1
*/5 *   * * *  cd /opt/stratum/keepers && RPC_URL=... PRIVATE_KEY=... NAV_ORACLE=... DEPEG_MONITOR=... ASSETS=... MODE=status node market-status-keeper.js >> /var/log/strat-market.log 2>&1
```

**Gelato Web3 Functions:** wrap each `main()` as the function body; pass env as secrets. Both are
idempotent and side-effect-free when there's nothing to do, so over-triggering is harmless.
