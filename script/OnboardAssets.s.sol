// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { NAVOracle } from "../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../src/oracle/ProofOfCollateral.sol";
import { DepegMonitor } from "../src/oracle/DepegMonitor.sol";
import { IOracleAdapter } from "../src/interfaces/IOracleAdapter.sol";
import { IAggregatorV3 } from "../src/interfaces/IAggregatorV3.sol";
import { ChainlinkAdapter } from "../src/oracle/ChainlinkAdapter.sol";
import { PancakeV3TwapAdapter } from "../src/oracle/PancakeV3TwapAdapter.sol";

/// @title OnboardAssets
/// @notice Onboards a list of (bStock, Chainlink feed, USDT pool) triples into the LIVE L0 stack so the
///         PortfolioFactory will accept them as components.
/// @dev For each asset, as admin: (1) deploys a ChainlinkAdapter over the asset's Chainlink feed and wires
///      it as the NAVOracle **primary** (fair-value) source; (2) deploys a PancakeV3TwapAdapter over the
///      bStock/USDT V3 pool and wires it as the NAVOracle **secondary** source — a deviation sanity-check:
///      NAVOracle flags the price stale if primary vs secondary deviate beyond `MAX_DEVIATION_BPS`; (3)
///      wires the SAME TWAP adapter as the DepegMonitor DEX source, so the breaker compares DEX market
///      price (TWAP) against the Chainlink fair value; (4) posts a manual 100% ProofOfCollateral
///      attestation (TODO: replace with Binance's real PoC feed). Markets default open on first configure,
///      so afterwards `DepegMonitor.isTradingSafe` is true (within threshold) and the allow-list passes.
///
///      NOTE: the deployed NAVOracle uses `secondary` purely as a deviation cross-check, not an automatic
///      failover — if Chainlink goes stale the price is flagged stale (consumers refuse it); it does not
///      silently switch to the TWAP. That is the core's design and is not forked here.
///
///      Required env:
///        PRIVATE_KEY        deployer/admin EOA (must hold ORACLE_ADMIN / ATTESTOR / DEPEG_ADMIN)
///        NAV_ORACLE         live NAVOracle           (default: mainnet)
///        PROOF_OF_COLLATERAL live ProofOfCollateral  (default: mainnet)
///        DEPEG_MONITOR      live DepegMonitor        (default: mainnet)
///        BSTOCK_TOKENS      comma-separated bStock token addresses
///        CHAINLINK_FEEDS    comma-separated Chainlink aggregator addresses (same order) — PRIMARY source
///        BSTOCK_POOLS       comma-separated bStock/USDT PancakeSwap V3 pool addresses (same order) — TWAP
///      Optional env (sane defaults):
///        TWAP_WINDOW=1800  MAX_STALENESS=86400  MAX_CLOSED_STALENESS=604800
///        MAX_DEVIATION_BPS=500  MAX_DRIFT_BPS=1000
///
///      Run: `forge script script/OnboardAssets.s.sol:OnboardAssets --rpc-url bsc --broadcast`
contract OnboardAssets is Script {
    // Live mainnet defaults (chainId 56).
    address internal constant NAV_ORACLE_DEFAULT = 0xbe263035a704E5039aCaB282AB011DF8175526e3;
    address internal constant POC_DEFAULT = 0xE28c10B5751bB3E64525fE85951F4A581e253c60;
    address internal constant DEPEG_DEFAULT = 0x7EB90C8F1E8E6bcC0C31A13D37271519dBB50D2a;

    uint256 internal constant FULL_BACKING_BPS = 10_000; // 100%

    function run() external {
        NAVOracle oracle = NAVOracle(vm.envOr("NAV_ORACLE", NAV_ORACLE_DEFAULT));
        ProofOfCollateral poc = ProofOfCollateral(vm.envOr("PROOF_OF_COLLATERAL", POC_DEFAULT));
        DepegMonitor depeg = DepegMonitor(vm.envOr("DEPEG_MONITOR", DEPEG_DEFAULT));

        address[] memory tokens = vm.envAddress("BSTOCK_TOKENS", ",");
        address[] memory feeds = vm.envAddress("CHAINLINK_FEEDS", ",");
        address[] memory pools = vm.envAddress("BSTOCK_POOLS", ",");
        require(tokens.length == feeds.length, "tokens/feeds length mismatch");
        require(tokens.length == pools.length, "tokens/pools length mismatch");
        require(tokens.length > 0, "no assets");

        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));
        uint64 maxStaleness = uint64(vm.envOr("MAX_STALENESS", uint256(86_400)));
        uint64 maxClosedStaleness = uint64(vm.envOr("MAX_CLOSED_STALENESS", uint256(604_800)));
        uint32 maxDeviationBps = uint32(vm.envOr("MAX_DEVIATION_BPS", uint256(500)));
        uint32 maxDriftBps = uint32(vm.envOr("MAX_DRIFT_BPS", uint256(1000)));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];

            // PRIMARY: Chainlink fair value.
            ChainlinkAdapter primary = new ChainlinkAdapter(IAggregatorV3(feeds[i]));
            // SECONDARY / DEX: PancakeSwap V3 TWAP (deviation sanity-check + depeg DEX side).
            PancakeV3TwapAdapter twap = new PancakeV3TwapAdapter(pools[i], token, window);

            oracle.configureAsset(
                token,
                NAVOracle.AssetConfig({
                    primary: IOracleAdapter(address(primary)),
                    secondary: IOracleAdapter(address(twap)),
                    maxStaleness: maxStaleness,
                    maxClosedStaleness: maxClosedStaleness,
                    maxDeviationBps: maxDeviationBps,
                    maxDriftBps: maxDriftBps,
                    configured: false
                })
            );

            // The TWAP is the depeg breaker's DEX side: market (TWAP) vs fair value (Chainlink).
            depeg.setDexSource(token, IOracleAdapter(address(twap)));

            // TODO(integration): replace with Binance's real proof-of-collateral feed.
            poc.attest(token, FULL_BACKING_BPS, keccak256(abi.encodePacked("manual-100pct", token)));

            console2.log("Onboarded", token);
            console2.log("  chainlink (primary)", address(primary));
            console2.log("  twap (secondary/dex)", address(twap));
        }

        vm.stopBroadcast();
        console2.log("Onboarded asset count:", tokens.length);
    }
}
