#!/usr/bin/env node
/**
 * Stratum — Oracle Market-Status + Depeg Keeper
 * ---------------------------------------------
 * Keeps each onboarded asset's NAVOracle market-open flag current and surfaces the
 * DepegMonitor trading-safe / depeg status. The NAVOracle stays live 24/7, but flipping
 * the market-open flag lets it switch between the live feed (open) and last-close + bounded
 * drift (closed). This keeper does NOT need to run for basic reads — onboarded assets price
 * and trade-gate fine on the live TWAP feed regardless; it only maintains the open/closed
 * flag and (optionally) alerts on depeg.
 *
 * Modes (MODE env):
 *   status   (default) — set each asset's market open/closed to match US equity hours, only
 *                        when it differs from on-chain state (no redundant txs). Then report.
 *   monitor            — read-only: log isTradingSafe + depegBps per asset; send no tx.
 *
 * Run one-shot from cron/Gelato. Suggested: every 5–15 min during the US session edges.
 *   MODE=status node market-status-keeper.js
 *
 * Required env:
 *   RPC_URL          BSC RPC endpoint
 *   NAV_ORACLE       NAVOracle    (mainnet: 0xbe263035a704E5039aCaB282AB011DF8175526e3)
 *   DEPEG_MONITOR    DepegMonitor (mainnet: 0x7EB90C8F1E8E6bcC0C31A13D37271519dBB50D2a)
 *   ASSETS           comma-separated bStock token addresses to maintain
 *   PRIVATE_KEY      keeper key holding MARKET_KEEPER on the oracle (required for MODE=status)
 * Optional env:
 *   DRY_RUN          "true" to log intended setMarketStatus calls without sending
 */
const { ethers } = require("ethers");

const NAV_ABI = [
  "function marketOpen(address asset) view returns (bool)",
  "function setMarketStatus(address asset, bool open)",
  "function getPrice(address asset) view returns (uint256 price, uint256 updatedAt, bool isStale)",
];
const DEPEG_ABI = [
  "function isTradingSafe(address asset) view returns (bool)",
  "function depegBps(address asset) view returns (uint256)",
];

function reqEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env ${name}`);
  return v;
}

/** True if US regular equity trading hours (Mon–Fri, 09:30–16:00 America/New_York). */
function isUsMarketOpen(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const get = (t) => parts.find((p) => p.type === t)?.value;
  const wd = get("weekday");
  let hour = parseInt(get("hour"), 10);
  if (hour === 24) hour = 0; // some runtimes emit 24 for midnight
  const minute = parseInt(get("minute"), 10);
  const isWeekday = ["Mon", "Tue", "Wed", "Thu", "Fri"].includes(wd);
  const minutes = hour * 60 + minute;
  return isWeekday && minutes >= 9 * 60 + 30 && minutes < 16 * 60;
  // NOTE: does not account for US market holidays; pass a holiday calendar or skip those days.
}

async function main() {
  const mode = (process.env.MODE || "status").toLowerCase();
  const provider = new ethers.JsonRpcProvider(reqEnv("RPC_URL"));
  const assets = reqEnv("ASSETS")
    .split(",")
    .map((a) => a.trim())
    .filter(Boolean);
  const dryRun = (process.env.DRY_RUN || "").toLowerCase() === "true";

  const navRead = new ethers.Contract(reqEnv("NAV_ORACLE"), NAV_ABI, provider);
  const depeg = new ethers.Contract(reqEnv("DEPEG_MONITOR"), DEPEG_ABI, provider);

  const wantOpen = isUsMarketOpen();
  console.log(`[market] mode=${mode} US-market-open=${wantOpen} assets=${assets.length}`);

  let nav = navRead;
  if (mode === "status" && !dryRun) {
    const wallet = new ethers.Wallet(reqEnv("PRIVATE_KEY"), provider);
    nav = new ethers.Contract(reqEnv("NAV_ORACLE"), NAV_ABI, wallet);
  }

  for (const asset of assets) {
    try {
      const [safe, dbps] = await Promise.all([depeg.isTradingSafe(asset), depeg.depegBps(asset)]);
      const [, , isStale] = await navRead.getPrice(asset);
      console.log(`[market] ${asset} tradingSafe=${safe} depegBps=${dbps} stale=${isStale}`);

      if (mode === "status") {
        const cur = await navRead.marketOpen(asset);
        if (cur === wantOpen) continue;
        if (dryRun) {
          console.log(`[market]   DRY_RUN: would setMarketStatus(${asset}, ${wantOpen})`);
          continue;
        }
        const tx = await nav.setMarketStatus(asset, wantOpen);
        console.log(`[market]   setMarketStatus(${asset}, ${wantOpen}) -> ${tx.hash}`);
        await tx.wait();
      }
    } catch (e) {
      console.error(`[market] ${asset} ERROR:`, e.message || e);
    }
  }
}

main().catch((e) => {
  console.error("[market] FATAL:", e.message || e);
  process.exit(1);
});
