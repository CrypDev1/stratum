// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";
import { IPortfolio } from "../src/interfaces/IPortfolio.sol";
import { FixedWeightStrategy } from "../src/core/strategies/FixedWeightStrategy.sol";

/// @title CreateTitans
/// @notice Deploys the launch index "Titans" (TTAN) via the LIVE PortfolioFactory.
/// @dev TTAN is a **zero-fee, rules-based auto-rebalancing Index** (`createIndex`) holding a fixed
///      NVIDIA + SpaceX basket quoted in USDT. Target weights are enforced by a `FixedWeightStrategy`; the
///      portfolio's rebalancer trades back toward them within the no-trade tolerance band. Index portfolios
///      charge no management fee (fees are a Vault-only feature here) — hence no fee params.
///
///      Default weights **NVDAB 40% / SPCXB 60%** lean into SPCXB's deep USDT pool so mints don't choke on
///      NVDAB's thin pool.
///
///      Every component must already pass the factory allow-list (PoC healthy + isTradingSafe) — i.e. it
///      must have been onboarded (`OnboardAssets`) and the Chainlink-only depeg monitor wired
///      (`ConfigureProtocol` with DEPLOY_CHAINLINK_ONLY_DEPEG=true) BEFORE this runs.
///
///      Required env:
///        PRIVATE_KEY        admin EOA (becomes the strategy owner + portfolio admin/rebalancer)
///        STABLE_TOKEN       quote asset (USDT on BNB)
///      Optional env:
///        INDEX_COMPONENTS   comma-separated token addresses (default: NVDAB,SPCXB)
///        INDEX_WEIGHTS      comma-separated bps, same order, sum 10000 (default: 4000,6000)
///        PORTFOLIO_FACTORY (default mainnet)  ADMIN (default: sender)
///        INDEX_NAME=Titans  INDEX_SYMBOL=TTAN
///        MAX_SLIPPAGE_BPS=500  REBALANCE_TOLERANCE_BPS=100  MAX_TRADE_BPS=5000
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
        uint16 maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(500)));
        uint16 toleranceBps = uint16(vm.envOr("REBALANCE_TOLERANCE_BPS", uint256(100)));
        uint16 maxTradeBps = uint16(vm.envOr("MAX_TRADE_BPS", uint256(5000)));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Rules-based target weights (owner = admin, who is also the broadcaster here).
        FixedWeightStrategy strategy = new FixedWeightStrategy(admin);
        strategy.setWeights(tokens, weights);

        portfolio = factory.createIndex(
            name, symbol, stable, comps, maxSlippageBps, admin, address(strategy), toleranceBps, maxTradeBps
        );
        vm.stopBroadcast();

        console2.log("Titans (TTAN) Index deployed:", portfolio);
        console2.log("  strategy (FixedWeight):", address(strategy));
        console2.log("  quote (USDT):", stable);
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
        w[0] = 4000; // NVDAB 40%
        w[1] = 6000; // SPCXB 60%
    }
}
