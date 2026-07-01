// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";
import { IPortfolio } from "../src/interfaces/IPortfolio.sol";

/// @title CreateTitans
/// @notice Deploys the launch index "Titans" (TTAN) via the LIVE PortfolioFactory.
/// @dev TTAN holds a fixed NVIDIA + SpaceX basket (NVDAB 55% / SPCXB 45%) quoted in USDT.
///
///      PRODUCT-TYPE NOTE: TTAN is created as a **Vault**, not a rules-based Index. In this codebase a
///      management fee is a FeeManager feature that only Vault portfolios carry (`createVault` takes
///      `managementFeeBps`); rules-based `createIndex` portfolios charge no fee. Since the launch spec
///      requires a 0.45% management fee, TTAN is a Vault holding the fixed basket with a passive manager
///      (the admin). `mint` still allocates by the component weights and shares track NAV, so it behaves
///      like a fee-bearing index fund. To instead ship a zero-fee auto-rebalancing Index, use
///      `createIndex` + a FixedWeightStrategy (no management fee possible there).
///
///      Every component must already pass the factory allow-list (PoC healthy + isTradingSafe) — i.e. it
///      must have been onboarded (`OnboardAssets`) and the Chainlink-only depeg monitor wired
///      (`ConfigureProtocol` with DEPLOY_CHAINLINK_ONLY_DEPEG=true) BEFORE this runs.
///
///      Required env:
///        PRIVATE_KEY        admin EOA
///        STABLE_TOKEN       quote asset (USDT on BNB)
///        INDEX_COMPONENTS   comma-separated component token addresses (default: NVDAB,SPCXB)
///        INDEX_WEIGHTS      comma-separated weights in bps, same order, sum 10000 (default: 5500,4500)
///      Optional env:
///        PORTFOLIO_FACTORY (default mainnet)  ADMIN (default: sender)
///        INDEX_NAME=Titans  INDEX_SYMBOL=TTAN
///        MGMT_FEE_BPS=45  PERF_FEE_BPS=0  MAX_SLIPPAGE_BPS=500  MAX_TRADE_BPS=5000
///
///      Run: `forge script script/CreateTitans.s.sol:CreateTitans --rpc-url bsc --broadcast`
contract CreateTitans is Script {
    address internal constant FACTORY_DEFAULT = 0x514ff906D211c86685db3DA68B8d18876A1665bd;
    // Titans launch basket (BNB mainnet).
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    function run() external returns (address portfolio) {
        PortfolioFactory factory = PortfolioFactory(vm.envOr("PORTFOLIO_FACTORY", FACTORY_DEFAULT));
        address admin = vm.envOr("ADMIN", msg.sender);
        address stable = vm.envAddress("STABLE_TOKEN");

        address[] memory tokens = vm.envOr("INDEX_COMPONENTS", ",", _defaultTokens());
        uint256[] memory weights = vm.envOr("INDEX_WEIGHTS", ",", _defaultWeights());
        require(tokens.length == weights.length && tokens.length > 0, "components/weights mismatch");

        IPortfolio.Component[] memory comps = new IPortfolio.Component[](tokens.length);
        uint256 sum;
        for (uint256 i; i < tokens.length; ++i) {
            comps[i] = IPortfolio.Component({ asset: tokens[i], weightBps: weights[i] });
            sum += weights[i];
        }
        require(sum == 10_000, "weights must sum to 10000");

        string memory name = vm.envOr("INDEX_NAME", string("Titans"));
        string memory symbol = vm.envOr("INDEX_SYMBOL", string("TTAN"));
        uint16 mgmtFeeBps = uint16(vm.envOr("MGMT_FEE_BPS", uint256(45))); // 0.45%
        uint16 perfFeeBps = uint16(vm.envOr("PERF_FEE_BPS", uint256(0)));
        uint16 maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(500)));
        uint16 maxTradeBps = uint16(vm.envOr("MAX_TRADE_BPS", uint256(5000)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        portfolio = factory.createVault(
            name, symbol, stable, comps, maxSlippageBps, admin, admin, mgmtFeeBps, perfFeeBps, maxTradeBps
        );
        vm.stopBroadcast();

        console2.log("Titans (TTAN) deployed:", portfolio);
        console2.log("  quote (USDT):", stable);
        console2.log("  management fee (bps):", mgmtFeeBps);
        for (uint256 i; i < comps.length; ++i) {
            console2.log("  component", comps[i].asset, comps[i].weightBps);
        }
    }

    function _defaultTokens() internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = NVDAB;
        t[1] = SPCXB;
    }

    function _defaultWeights() internal pure returns (uint256[] memory w) {
        w = new uint256[](2);
        w[0] = 5500; // NVDAB 55%
        w[1] = 4500; // SPCXB 45%
    }
}
