# Keeper automation — hosting the two keepers (BNB mainnet)

Two jobs keep the protocol running. Neither is required for basic reads/trading; they push emissions and
maintain the market open/closed flag. Recommended split:

| Keeper | Host | Why | Funds |
|---|---|---|---|
| **Emissions** | **Chainlink Automation** (on-chain, custom-logic upkeep) | condition is a pure on-chain read (`mintable()`), so it needs no off-chain logic | **LINK** on the upkeep |
| **Market-status** | **Gelato Web3 Function** (off-chain JS) | needs DST-aware US-hours logic that can't run on-chain | **Gelato 1Balance** (USDC) or task balance |

Live addresses used below: EmissionsMinter `0x11e3f4d2c27e37ad7438deac5C143a06381C4816` ·
GaugeDistributor `0xE5B30CFf0108224aac528aaC5Bc2E9C515B8AFc8` · NAVOracle
`0xbe263035a704E5039aCaB282AB011DF8175526e3` · NVDAB `0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436` ·
SPCXB `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1`.

---

## 1. Emissions → Chainlink Automation

### a) Deploy the on-chain adapter (grants itself the mint role via your admin)
`EmissionsAutomation` is a custom-logic upkeep target: `checkUpkeep` returns true once `mintable() > 0`
(and ≥ `MIN_MINTABLE_WEI`); `performUpkeep` calls `EmissionsMinter.emitTo(recipient)` and then
`GaugeDistributor.distribute()`. The script also grants it `EMISSIONS_ADMIN` on the minter.

```bash
# .env: PRIVATE_KEY (admin), GAUGE_DISTRIBUTOR=0xE5B30CFf0108224aac528aaC5Bc2E9C515B8AFc8
# optional: EMISSIONS_RECIPIENT (default = GAUGE_DISTRIBUTOR), MIN_MINTABLE_WEI
forge script script/RegisterKeepers.s.sol:RegisterKeepers --rpc-url bsc --broadcast -vvvv
```
Note the printed `EmissionsAutomation` address.

### b) Register the upkeep
Go to **https://automation.chain.link** → connect the admin wallet → **Register new Upkeep** →
**Custom logic** →
- Target contract address: the `EmissionsAutomation` address from (a)
- Gas limit: `500000`
- Starting balance: **5 LINK** (see funding below)
- Check data: `0x` (empty)

After registration, copy the upkeep's **Forwarder** address and (optional, recommended) lock performs to it:
```bash
cast send <EMISSIONS_AUTOMATION> "setForwarder(address)" <FORWARDER> \
  --rpc-url bsc --private-key $PRIVATE_KEY
```

### c) Fund
- **LINK on BNB Chain** (token `0x404460C6A5EdE2D891e8297795264fDe62ADBB75`). Start with **~5 LINK**;
  top up when the upkeep balance runs low (Chainlink UI shows the burn rate). Each perform is cheap
  (one `emitTo` + one `distribute`), so 5 LINK lasts a long time at hourly cadence.
- No BNB needed by you — Chainlink pays gas from the LINK balance.

> Prereq already satisfied by the deploy: the `EmissionsMinter` holds `MINTER` on STRAT, and the adapter
> now holds `EMISSIONS_ADMIN` on the minter. If you rotate the adapter, re-grant `EMISSIONS_ADMIN`.

---

## 2. Market-status → Gelato Web3 Function

Source: `keepers/gelato/market-status/` (`index.js` + `schema.json`). It sets each asset's NAVOracle
market flag to match US regular hours (Mon–Fri 09:30–16:00 America/New_York, DST-aware), only when it
differs on-chain.

### a) Deploy the W3F
Use a Gelato Web3 Functions template repo (`npx @gelatonetwork/web3-functions-sdk`) and drop in the two
files, or deploy from the Gelato app (**https://app.gelato.network** → Functions → Create). Set `userArgs`:
```json
{
  "navOracle": "0xbe263035a704E5039aCaB282AB011DF8175526e3",
  "assets": ["0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436", "0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1"]
}
```
Trigger: **time-based, every 5 minutes** (`*/5 * * * *`). A no-change run returns `canExec:false` (free).

### b) Grant the role to Gelato's dedicated msg.sender
Gelato executes the returned `setMarketStatus` call from a **dedicated msg.sender** it shows for your task.
`setMarketStatus` is `onlyRole(MARKET_KEEPER)`, so grant it:
```bash
cast send 0xbe263035a704E5039aCaB282AB011DF8175526e3 \
  "grantRole(bytes32,address)" $(cast keccak "MARKET_KEEPER") <GELATO_DEDICATED_MSGSENDER> \
  --rpc-url bsc --private-key $PRIVATE_KEY
```

### c) Fund
- Deposit into **Gelato 1Balance** (USDC) at https://app.gelato.network/1balance — start with **~20 USDC**;
  it sponsors execution gas across your tasks. (Legacy Automate alternative: fund the task with a small
  amount of **BNB**, ~0.05–0.1 BNB.)
- The dedicated msg.sender needs **no balance** (Gelato pays gas), only the `MARKET_KEEPER` role.

> US holidays are NOT handled — pause the task on market holidays or extend `index.js` with a calendar.

---

## Alternative: plain cron (no third party)
Both `keepers/emissions-keeper.js` and `keepers/market-status-keeper.js` run one-shot from cron with a
keeper key that holds the roles (see `keepers/README.md`). Simplest to stand up, but you host and fund the
keeper EOA with BNB for gas yourself.
