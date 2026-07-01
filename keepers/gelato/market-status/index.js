/**
 * Gelato Web3 Function — Titans / bStock market-status keeper
 * -----------------------------------------------------------
 * Sets each configured asset's NAVOracle market flag to match US equity regular hours
 * (Mon-Fri 09:30-16:00 America/New_York, DST-aware) — only when it differs on-chain, so a
 * no-change run costs nothing to execute. Mirrors keepers/market-status-keeper.js (MODE=status).
 *
 * Deploy as a Gelato Web3 Function (https://docs.gelato.network/web3-services/web3-functions).
 * The Gelato "dedicated msg.sender" for this task MUST hold MARKET_KEEPER on the NAVOracle.
 *
 * userArgs (schema.json):
 *   navOracle : address   — live NAVOracle (0xbe263035a704E5039aCaB282AB011DF8175526e3)
 *   assets    : string[]  — bStock addresses to maintain (e.g. [NVDAB, SPCXB])
 *
 * Does NOT account for US market holidays — pause the task on those days or extend with a calendar.
 */
const { Web3Function } = require("@gelatonetwork/web3-functions-sdk");
const { Contract } = require("ethers");

const NAV_ABI = [
  "function marketOpen(address asset) view returns (bool)",
  "function setMarketStatus(address asset, bool open)",
];

// US regular trading hours in America/New_York, DST-aware via Intl (no external tz data).
function isUsMarketOpen(now) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const get = (t) => parts.find((p) => p.type === t)?.value;
  const wd = get("weekday");
  if (wd === "Sat" || wd === "Sun") return false;
  const hour = parseInt(get("hour"), 10);
  const minute = parseInt(get("minute"), 10);
  const mins = hour * 60 + minute;
  return mins >= 9 * 60 + 30 && mins < 16 * 60; // [09:30, 16:00)
}

Web3Function.onRun(async (context) => {
  const { userArgs, multiChainProvider } = context;
  const provider = multiChainProvider.default();
  const nav = new Contract(userArgs.navOracle, NAV_ABI, provider);
  const assets = userArgs.assets;

  const shouldBeOpen = isUsMarketOpen(new Date());
  const callData = [];

  for (const asset of assets) {
    let onChain;
    try {
      onChain = await nav.marketOpen(asset);
    } catch (e) {
      continue; // unconfigured asset — skip
    }
    if (onChain !== shouldBeOpen) {
      callData.push({
        to: userArgs.navOracle,
        data: nav.interface.encodeFunctionData("setMarketStatus", [asset, shouldBeOpen]),
      });
    }
  }

  if (callData.length === 0) {
    return { canExec: false, message: `no change (market ${shouldBeOpen ? "open" : "closed"})` };
  }
  return { canExec: true, callData };
});
