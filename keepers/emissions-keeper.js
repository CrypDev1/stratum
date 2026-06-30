#!/usr/bin/env node
/**
 * Stratum — Emissions Keeper
 * --------------------------
 * Pushes the linear 300M STRAT community-emissions schedule by calling
 * `EmissionsMinter.emitTo(recipient)`. Each invocation settles whatever has accrued
 * since the last mint (`mintable()`), so it is safe to run on any cadence — more
 * frequent runs just produce smaller mints. Idempotent: a no-accrual run is a no-op.
 *
 * Run one-shot from cron/Gelato (recommended cadence: hourly–daily):
 *   node emissions-keeper.js
 *
 * Required env:
 *   RPC_URL              BSC RPC endpoint
 *   PRIVATE_KEY          keeper key holding EMISSIONS_ADMIN on the minter
 *   EMISSIONS_MINTER     EmissionsMinter address (mainnet: 0x11e3f4d2c27e37ad7438deac5C143a06381C4816)
 * Optional env:
 *   EMISSIONS_RECIPIENT  who receives the mint (default: GAUGE_CONTROLLER below)
 *   GAUGE_CONTROLLER     default recipient (mainnet: 0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE)
 *   MIN_MINTABLE_WEI     skip the tx if mintable() is below this (default: 0 = always mint when >0)
 *   DRY_RUN              "true" to log only, send no tx
 *
 * NOTE: the deployed GaugeController only computes gauge weights; it has no on-chain
 * distributor that forwards STRAT to individual gauges by weight. This keeper pushes
 * the schedule to EMISSIONS_RECIPIENT; per-gauge distribution must be handled by an
 * additional distributor contract or off-chain (see WHAT I NEED FROM YOU checklist).
 */
const { ethers } = require("ethers");

const MINTER_ABI = [
  "function mintable() view returns (uint256)",
  "function totalEmitted() view returns (uint256)",
  "function maxEmissions() view returns (uint256)",
  "function ratePerSecond() view returns (uint256)",
  "function emitTo(address to) returns (uint256)",
];

const GAUGE_CONTROLLER_DEFAULT = "0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE";

function reqEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env ${name}`);
  return v;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(reqEnv("RPC_URL"));
  const wallet = new ethers.Wallet(reqEnv("PRIVATE_KEY"), provider);
  const minter = new ethers.Contract(reqEnv("EMISSIONS_MINTER"), MINTER_ABI, wallet);

  const recipient =
    process.env.EMISSIONS_RECIPIENT || process.env.GAUGE_CONTROLLER || GAUGE_CONTROLLER_DEFAULT;
  const minMintable = BigInt(process.env.MIN_MINTABLE_WEI || "0");
  const dryRun = (process.env.DRY_RUN || "").toLowerCase() === "true";

  const [mintable, emitted, max] = await Promise.all([
    minter.mintable(),
    minter.totalEmitted(),
    minter.maxEmissions(),
  ]);

  console.log(`[emissions] mintable=${ethers.formatEther(mintable)} STRAT`);
  console.log(`[emissions] emitted=${ethers.formatEther(emitted)} / cap=${ethers.formatEther(max)}`);

  if (mintable === 0n) {
    console.log("[emissions] nothing accrued — schedule may be complete or freshly minted; no-op.");
    return;
  }
  if (mintable < minMintable) {
    console.log(`[emissions] mintable below MIN_MINTABLE_WEI (${minMintable}); skipping.`);
    return;
  }
  if (dryRun) {
    console.log(`[emissions] DRY_RUN: would emitTo(${recipient}) ~${ethers.formatEther(mintable)} STRAT`);
    return;
  }

  console.log(`[emissions] emitTo(${recipient})...`);
  const tx = await minter.emitTo(recipient);
  console.log(`[emissions] sent ${tx.hash}; waiting...`);
  const rcpt = await tx.wait();
  console.log(`[emissions] confirmed in block ${rcpt.blockNumber}`);
}

main().catch((e) => {
  console.error("[emissions] ERROR:", e.message || e);
  process.exit(1);
});
