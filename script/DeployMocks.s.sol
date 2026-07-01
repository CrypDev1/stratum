// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { NAVOracle } from "../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../src/oracle/ProofOfCollateral.sol";
import { DepegMonitor } from "../src/oracle/DepegMonitor.sol";
import { INAVOracle } from "../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../src/interfaces/IOracleAdapter.sol";

import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockOracleAdapter } from "../src/mocks/MockOracleAdapter.sol";
import { MockSwapRouter } from "../src/mocks/MockSwapRouter.sol";

import { FeeManager } from "../src/core/FeeManager.sol";
import { IndexPortfolio } from "../src/core/IndexPortfolio.sol";
import { VaultPortfolio } from "../src/core/VaultPortfolio.sol";
import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";
import { FixedWeightStrategy } from "../src/core/strategies/FixedWeightStrategy.sol";
import { IPortfolio } from "../src/interfaces/IPortfolio.sol";

import { STRAT } from "../src/token/STRAT.sol";
import { EmissionsMinter } from "../src/token/EmissionsMinter.sol";
import { TeamVesting } from "../src/token/TeamVesting.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployMocks
/// @notice Stands up the full Stratum stack with mock bStocks + oracle + DEX so the system can be
///         exercised on a local Anvil fork without external dependencies.
/// @dev `forge script script/DeployMocks.s.sol --rpc-url http://localhost:8545 --broadcast`.
contract DeployMocks is Script {
    function run() external {
        address admin = msg.sender;
        vm.startBroadcast();

        // ── Mock tokens (USDC quote + two tokenized equities) ──
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 18);
        MockERC20 aapl = new MockERC20("bAAPL", "bAAPL", 18);
        MockERC20 goog = new MockERC20("bGOOG", "bGOOG", 18);

        // ── L0: oracle + PoC + depeg + DEX ──
        NAVOracle oracle = new NAVOracle(admin);
        ProofOfCollateral poc = new ProofOfCollateral(admin);
        DepegMonitor monitor = new DepegMonitor(admin, INAVOracle(address(oracle)));
        MockSwapRouter router = new MockSwapRouter();

        MockOracleAdapter aaplFeed = new MockOracleAdapter(200e18, block.timestamp);
        MockOracleAdapter googFeed = new MockOracleAdapter(150e18, block.timestamp);

        oracle.configureAsset(
            address(aapl),
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(aaplFeed)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 1 days,
                maxClosedStaleness: 7 days,
                maxDeviationBps: 500,
                maxDriftBps: 1000,
                configured: false
            })
        );
        oracle.configureAsset(
            address(goog),
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(googFeed)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 1 days,
                maxClosedStaleness: 7 days,
                maxDeviationBps: 500,
                maxDriftBps: 1000,
                configured: false
            })
        );
        monitor.setDexSource(address(aapl), IOracleAdapter(address(aaplFeed)));
        monitor.setDexSource(address(goog), IOracleAdapter(address(googFeed)));
        poc.attest(address(aapl), 10_000, bytes32("aapl-proof"));
        poc.attest(address(goog), 10_000, bytes32("goog-proof"));

        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(aapl), 200e18);
        router.setPrice(address(goog), 150e18);

        // ── L1: fee manager + factory ──
        FeeManager feeManager = new FeeManager();
        PortfolioFactory factory = new PortfolioFactory(
            admin,
            PortfolioFactory.Wiring({
                navOracle: address(oracle),
                proofOfCollateral: address(poc),
                depegMonitor: address(monitor),
                swapRouter: address(router),
                feeManager: address(feeManager),
                indexImplementation: address(new IndexPortfolio()),
                vaultImplementation: address(new VaultPortfolio()),
                protocolTreasury: admin,
                protocolCutBps: 1000
            })
        );

        // ── An example AI Index ──
        FixedWeightStrategy strategy = new FixedWeightStrategy(admin);
        address[] memory a = new address[](2);
        a[0] = address(aapl);
        a[1] = address(goog);
        uint256[] memory w = new uint256[](2);
        w[0] = 5000;
        w[1] = 5000;
        strategy.setWeights(a, w);

        IPortfolio.Component[] memory comps = new IPortfolio.Component[](2);
        comps[0] = IPortfolio.Component({ asset: address(aapl), weightBps: 5000 });
        comps[1] = IPortfolio.Component({ asset: address(goog), weightBps: 5000 });
        address aiIndex = factory.createIndex(
            "AI Tech Index", "AITECH", address(usdc), comps, 100, admin, address(strategy), 200, 2000
        );

        // ── ★ token flywheel: STRAT with the final 1B supply & 50/30/5/15 distribution ──
        // Local default: every distribution target is the deployer (admin).
        uint256 emissionsAlloc = 300_000_000e18; // 30%
        STRAT strat = new STRAT(admin, 0); // hard cap is a fixed 1B constant; no genesis mint
        EmissionsMinter emissions = new EmissionsMinter(admin, strat, emissionsAlloc / 365 days, emissionsAlloc);
        TeamVesting teamVesting = new TeamVesting(IERC20(address(strat)), admin, 90 days, 730 days);

        require(500_000_000e18 + emissionsAlloc + 50_000_000e18 + 150_000_000e18 == strat.cap(), "alloc sum != cap");

        strat.grantRole(strat.MINTER(), admin);
        strat.mint(admin, 500_000_000e18); // 50% → liquidityWallet (deployer locally)
        strat.mint(admin, 150_000_000e18); // 15% → treasuryWallet (deployer locally)
        strat.mint(address(teamVesting), 50_000_000e18); // 5% → team vesting
        strat.revokeRole(strat.MINTER(), admin);
        strat.grantRole(strat.MINTER(), address(emissions)); // 30% emitted over 12 months

        vm.stopBroadcast();

        console2.log("USDC          ", address(usdc));
        console2.log("NAVOracle     ", address(oracle));
        console2.log("ProofOfCollat ", address(poc));
        console2.log("DepegMonitor  ", address(monitor));
        console2.log("MockSwapRouter", address(router));
        console2.log("FeeManager    ", address(feeManager));
        console2.log("Factory       ", address(factory));
        console2.log("AI Index      ", aiIndex);
        console2.log("STRAT         ", address(strat));
        console2.log("EmissionsMinter", address(emissions));
        console2.log("TeamVesting   ", address(teamVesting));
    }
}
