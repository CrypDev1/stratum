// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { NAVOracle } from "../../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../../src/oracle/ProofOfCollateral.sol";
import { DepegMonitor } from "../../src/oracle/DepegMonitor.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../../src/interfaces/IOracleAdapter.sol";

import { FeeManager } from "../../src/core/FeeManager.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { VaultPortfolio } from "../../src/core/VaultPortfolio.sol";
import { PortfolioFactory } from "../../src/core/PortfolioFactory.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";

import { PancakeV3TwapAdapter } from "../../src/oracle/PancakeV3TwapAdapter.sol";
import { PancakeV3SwapAdapter } from "../../src/periphery/PancakeV3SwapAdapter.sol";
import { MockPancakeV3Pool } from "../../src/mocks/MockPancakeV3Pool.sol";
import { MockPancakeV3Router } from "../../src/mocks/MockPancakeV3Router.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

/// @notice End-to-end proof that the OnboardAssets flow makes a bStock usable: it passes the factory
///         allow-list, prices sanely off the TWAP adapter, reports trading-safe, and can be minted through
///         the PancakeV3 swap adapter. Mirrors `script/OnboardAssets.s.sol` against the real L0 + factory.
contract OnboardingTest is Test {
    NAVOracle internal oracle;
    ProofOfCollateral internal poc;
    DepegMonitor internal monitor;
    FeeManager internal feeManager;
    PortfolioFactory internal factory;

    MockPancakeV3Router internal v3Router; // stands in for the real PancakeSwap V3 SwapRouter
    PancakeV3SwapAdapter internal swapAdapter; // protocol ISwapRouter adapter wired into the factory

    MockERC20 internal usdt; // quote / stable, 18 dec
    MockERC20 internal aapl; // onboarded bStock, 18 dec

    PancakeV3TwapAdapter internal twap;
    MockPancakeV3Pool internal pool;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7EE5);
    address internal alice = address(0xA11);

    uint32 internal constant WINDOW = 1800;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new MockERC20("Tether", "USDT", 18);
        aapl = new MockERC20("bAAPL", "bAAPL", 18);

        // ── Live L0 stack ──
        oracle = new NAVOracle(admin);
        poc = new ProofOfCollateral(admin);
        monitor = new DepegMonitor(admin, INAVOracle(address(oracle)));
        feeManager = new FeeManager();

        // ── Swap adapter (priced off the live NAV oracle, executing on the V3 router) ──
        v3Router = new MockPancakeV3Router();
        swapAdapter = new PancakeV3SwapAdapter(admin, address(v3Router), address(oracle), address(usdt));

        // ── Factory wired with the swap adapter as the protocol router ──
        address indexImpl = address(new IndexPortfolio());
        address vaultImpl = address(new VaultPortfolio());
        factory = new PortfolioFactory(
            admin,
            PortfolioFactory.Wiring({
                navOracle: address(oracle),
                proofOfCollateral: address(poc),
                depegMonitor: address(monitor),
                swapRouter: address(swapAdapter),
                feeManager: address(feeManager),
                indexImplementation: indexImpl,
                vaultImplementation: vaultImpl,
                protocolTreasury: treasury,
                protocolCutBps: 1000
            })
        );

        // ── TWAP source over the bStock/USDT V3 pool (tick 0 ⇒ $1 fair value) ──
        pool = new MockPancakeV3Pool(address(aapl), address(usdt), 0, 1e18);
        twap = new PancakeV3TwapAdapter(address(pool), address(aapl), WINDOW);

        _onboard();
    }

    /// @dev The exact OnboardAssets steps, executed as admin.
    function _onboard() internal {
        vm.startPrank(admin);
        oracle.configureAsset(
            address(aapl),
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(twap)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 86_400,
                maxClosedStaleness: 604_800,
                maxDeviationBps: 500,
                maxDriftBps: 1000,
                configured: false
            })
        );
        monitor.setDexSource(address(aapl), IOracleAdapter(address(twap)));
        poc.attest(address(aapl), 10_000, keccak256("manual-100pct"));
        vm.stopPrank();

        // Mirror the on-chain pool price into the execution router so swaps clear at NAV parity.
        (uint256 price,,) = oracle.getPrice(address(aapl));
        v3Router.setPrice(address(usdt), 1e18);
        v3Router.setPrice(address(aapl), price);
    }

    function test_onboardedAssetIsHealthyAndSafe() public view {
        assertTrue(poc.isHealthy(address(aapl)), "healthy");
        assertTrue(monitor.isTradingSafe(address(aapl)), "trading safe");
    }

    function test_onboardedAssetReturnsSanePrice() public view {
        (uint256 price, uint256 updatedAt, bool isStale) = oracle.getPrice(address(aapl));
        assertEq(price, 1e18, "TWAP fair value at tick 0");
        assertEq(updatedAt, block.timestamp, "fresh");
        assertFalse(isStale, "not stale");
    }

    /// @dev A single-asset FixedWeightStrategy targeting 100% bAAPL.
    function _strategy() internal returns (address) {
        FixedWeightStrategy s = new FixedWeightStrategy(admin);
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        s.setWeights(assets, weights);
        return address(s);
    }

    function test_onboardedAssetPassesFactoryAllowList() public {
        IPortfolio.Component[] memory comps = new IPortfolio.Component[](1);
        comps[0] = IPortfolio.Component({ asset: address(aapl), weightBps: 10_000 });

        address portfolio = factory.createIndex(
            "bAAPL Index", "iAAPL", address(usdt), comps, 100, admin, _strategy(), 100, 5000
        );
        assertTrue(factory.isPortfolio(portfolio), "registered");
    }

    function test_unonboardedAssetIsRejectedByFactory() public {
        MockERC20 tsla = new MockERC20("bTSLA", "bTSLA", 18);
        IPortfolio.Component[] memory comps = new IPortfolio.Component[](1);
        comps[0] = IPortfolio.Component({ asset: address(tsla), weightBps: 10_000 });

        vm.expectRevert(abi.encodeWithSelector(PortfolioFactory.UnhealthyAsset.selector, address(tsla)));
        factory.createIndex("x", "x", address(usdt), comps, 100, admin, address(0), 100, 5000);
    }

    function test_mintRoutesThroughSwapAdapterEndToEnd() public {
        IPortfolio.Component[] memory comps = new IPortfolio.Component[](1);
        comps[0] = IPortfolio.Component({ asset: address(aapl), weightBps: 10_000 });
        address portfolio = factory.createIndex(
            "bAAPL Index", "iAAPL", address(usdt), comps, 100, admin, _strategy(), 100, 5000
        );

        uint256 deposit = 1_000e18;
        usdt.mint(alice, deposit);
        vm.startPrank(alice);
        usdt.approve(portfolio, deposit);
        uint256 shares = IPortfolio(portfolio).mint(deposit, 0, block.timestamp + 1);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        // 100% allocated into bAAPL @ $1 ⇒ portfolio holds ~1000 bAAPL and NAV ~ $1000.
        assertApproxEqRel(aapl.balanceOf(portfolio), deposit, 0.001e18, "allocated into bStock");
        assertApproxEqRel(IPortfolio(portfolio).totalNAV(), deposit, 0.001e18, "NAV reflects deposit");
        assertApproxEqRel(IPortfolio(portfolio).navPerShare(), 1e18, 0.001e18, "navPerShare ~ 1");
    }
}
