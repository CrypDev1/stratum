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
import { VenusOracleAdapter } from "../src/oracle/VenusOracleAdapter.sol";
import { IVenusOracle } from "../src/interfaces/external/IVenusOracle.sol";

/// @title OnboardAssets
/// @notice Onboards a list of bStocks into the LIVE L0 stack so the PortfolioFactory will accept them as
///         components. Chainlink is the PRIMARY (fair-value) source for every asset.
/// @dev Two modes, chosen per-asset by whether a DEX pool is supplied in `BSTOCK_POOLS`:
///
///      A) CHAINLINK-ONLY (pool == address(0), or `BSTOCK_POOLS` omitted): wires ONLY the ChainlinkAdapter
///         as the NAVOracle primary with `secondary = address(0)` (no DEX cross-check) and posts the PoC
///         attestation. Safety for these assets is enforced by the additive `ChainlinkOnlyDepegMonitor`
///         (wired into the factory by `ConfigureProtocol`), which gates trading purely on Chainlink
///         freshness — a stale feed pauses the asset. Use this for RWA/bStocks whose on-chain pools are
///         empty or observation-cardinality-1 (a TWAP would return 0 and brick the asset). NO DEX source is
///         set on the legacy DepegMonitor in this mode.
///
///      B) TWAP-CROSS-CHECK (pool != address(0)): additionally deploys a PancakeV3TwapAdapter over the
///         bStock/USDT V3 pool and wires it as the NAVOracle `secondary` (deviation sanity-check) AND as the
///         legacy DepegMonitor DEX source. Requires the pool to have `observationCardinality` grown and
///         >= TWAP_WINDOW of history, else the TWAP reads 0 and the asset flags stale. Kept for assets that
///         have a real, deep, TWAP-capable pool.
///
///      Nothing here modifies or redeploys a core contract — it only calls existing admin setters
///      (ORACLE_ADMIN / ATTESTOR / DEPEG_ADMIN) on the live L0.
///
///      PRIMARY source: for bStocks, the raw Chainlink "SingleFeed" aggregators are access-controlled and
///      revert (`OnlyAuthorizedCallerAllowed`) for any contract caller other than an authorized consumer.
///      So set `VENUS_RESILIENT_ORACLE` to price each bStock through Venus's ResilientOracle (the authorized
///      reader whose main source IS that Chainlink feed) via a `VenusOracleAdapter`. `CHAINLINK_FEEDS` is
///      then unused. Omit `VENUS_RESILIENT_ORACLE` only for standard aggregators that permit contract reads.
///
///      Required env:
///        PRIVATE_KEY        deployer/admin EOA (holds ORACLE_ADMIN / ATTESTOR / DEPEG_ADMIN)
///        NAV_ORACLE         live NAVOracle            (default: mainnet)
///        PROOF_OF_COLLATERAL live ProofOfCollateral   (default: mainnet)
///        DEPEG_MONITOR      live DepegMonitor         (default: mainnet; only used in TWAP mode)
///        BSTOCK_TOKENS      comma-separated bStock token addresses
///      Primary source (choose one):
///        VENUS_RESILIENT_ORACLE  Venus ResilientOracle (BNB: 0x6592b5DE802159F3E74B2486b091D11a8256ab8A)
///        CHAINLINK_FEEDS    comma-separated Chainlink aggregator addresses (same order) — standard feeds only
///      Optional env:
///        BSTOCK_POOLS       comma-separated V3 pool addresses (same order); address(0) => Chainlink-only.
///                           Omit entirely for an all-Chainlink-only batch (e.g. the Titans launch set).
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
        // PRIMARY source mode:
        //   - VENUS_RESILIENT_ORACLE set  => price each bStock through Venus's ResilientOracle (the
        //     authorized reader of the access-gated bStock Chainlink SingleFeeds). CHAINLINK_FEEDS unused.
        //   - otherwise                   => wrap each raw CHAINLINK_FEEDS[i] in a ChainlinkAdapter (only
        //     works for standard aggregators that permit contract reads).
        IVenusOracle venus = IVenusOracle(vm.envOr("VENUS_RESILIENT_ORACLE", address(0)));
        address[] memory feeds =
            address(venus) == address(0) ? vm.envAddress("CHAINLINK_FEEDS", ",") : new address[](tokens.length);
        // Pools are OPTIONAL. Omit for an all-Chainlink-only batch; any address(0) entry is Chainlink-only.
        address[] memory pools = vm.envOr("BSTOCK_POOLS", ",", new address[](0));
        require(tokens.length == feeds.length, "tokens/feeds length mismatch");
        require(pools.length == 0 || pools.length == tokens.length, "tokens/pools length mismatch");
        require(tokens.length > 0, "no assets");

        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));
        uint64 maxStaleness = uint64(vm.envOr("MAX_STALENESS", uint256(86_400)));
        uint64 maxClosedStaleness = uint64(vm.envOr("MAX_CLOSED_STALENESS", uint256(604_800)));
        uint32 maxDeviationBps = uint32(vm.envOr("MAX_DEVIATION_BPS", uint256(500)));
        uint32 maxDriftBps = uint32(vm.envOr("MAX_DRIFT_BPS", uint256(1000)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            address pool = pools.length == 0 ? address(0) : pools[i];

            // PRIMARY: Chainlink fair value — read via Venus's authorized ResilientOracle for bStocks whose
            // raw SingleFeed is access-gated, or directly for standard aggregators.
            IOracleAdapter primary = address(venus) != address(0)
                ? IOracleAdapter(address(new VenusOracleAdapter(venus, token)))
                : IOracleAdapter(address(new ChainlinkAdapter(IAggregatorV3(feeds[i]))));

            IOracleAdapter secondary = IOracleAdapter(address(0));
            if (pool != address(0)) {
                // SECONDARY / DEX: PancakeSwap V3 TWAP (deviation sanity-check + legacy depeg DEX side).
                PancakeV3TwapAdapter twap = new PancakeV3TwapAdapter(pool, token, window);
                secondary = IOracleAdapter(address(twap));
            }

            oracle.configureAsset(
                token,
                NAVOracle.AssetConfig({
                    primary: primary,
                    secondary: secondary,
                    maxStaleness: maxStaleness,
                    maxClosedStaleness: maxClosedStaleness,
                    maxDeviationBps: maxDeviationBps,
                    maxDriftBps: maxDriftBps,
                    configured: false
                })
            );

            // Only wire the legacy DepegMonitor DEX side when a real pool exists. Chainlink-only assets are
            // gated by the ChainlinkOnlyDepegMonitor instead (wired into the factory by ConfigureProtocol).
            if (pool != address(0)) {
                depeg.setDexSource(token, secondary);
            }

            // TODO(integration): replace with Binance's real proof-of-collateral feed.
            poc.attest(token, FULL_BACKING_BPS, keccak256(abi.encodePacked("manual-100pct", token)));

            console2.log("Onboarded", token);
            console2.log(
                address(venus) != address(0) ? "  primary: VenusOracleAdapter" : "  primary: ChainlinkAdapter",
                address(primary)
            );
            console2.log(pool == address(0) ? "  mode: CHAINLINK-ONLY (no DEX secondary)" : "  mode: TWAP cross-check");
        }

        vm.stopBroadcast();
        console2.log("Onboarded asset count:", tokens.length);
    }
}
