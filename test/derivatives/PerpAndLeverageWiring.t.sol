// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../../src/interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../../src/interfaces/ISwapRouter.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { LiquidityPool } from "../../src/derivatives/LiquidityPool.sol";
import { PerpEngine } from "../../src/derivatives/PerpEngine.sol";
import { LeverageModule } from "../../src/leverage/LeverageModule.sol";

/// @notice Proves the additive derivatives + leverage modules read the LIVE NAV oracle (by construction)
///         and function end-to-end against a seeded counterparty — the wiring ConfigureProtocol/SeedPerp
///         perform on mainnet, exercised locally over the shared L0/L1 fixture.
contract PerpAndLeverageWiringTest is Fixtures {
    LiquidityPool internal pool;
    PerpEngine internal engine;
    LeverageModule internal module;
    address internal portfolio;

    function setUp() public {
        _deployL0();
        _deployFactory();

        // ── Perp market on bAAPL, priced off the live oracle ──
        vm.startPrank(admin);
        pool = new LiquidityPool(admin, usdc);
        engine = new PerpEngine(
            admin, usdc, INAVOracle(address(oracle)), IDepegMonitor(address(monitor)), pool, address(aapl)
        );
        pool.setEngine(address(engine));
        vm.stopPrank();

        // ── Index + leverage module reading the live oracle ──
        portfolio = _createIndex();
        vm.prank(admin);
        module = new LeverageModule(
            admin,
            IPortfolio(portfolio),
            INAVOracle(address(oracle)),
            IDepegMonitor(address(monitor)),
            ISwapRouter(address(router))
        );
    }

    function _createIndex() internal returns (address) {
        FixedWeightStrategy strat = new FixedWeightStrategy(admin);
        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(goog);
        uint256[] memory w = new uint256[](2);
        w[0] = 5000;
        w[1] = 5000;
        vm.prank(admin);
        strat.setWeights(assets, w);
        return factory.createIndex(
            "AG Index", "AGI", address(usdc), _equalComponents(), 100, admin, address(strat), 100, 5000
        );
    }

    // ── PerpEngine ───────────────────────────────────────────────────────────

    function test_perpMarkPriceReadsLiveOracle() public view {
        assertEq(address(engine.nav()), address(oracle), "engine wired to live NAVOracle");
        (uint256 price, bool afterHours) = engine.markPrice();
        assertEq(price, AAPL_PRICE, "mark = live NAV fair value");
        assertFalse(afterHours);
    }

    function test_perpMarkFollowsOracle() public {
        _setAaplPrice(250e18);
        (uint256 price,) = engine.markPrice();
        assertEq(price, 250e18, "mark tracks oracle update");
    }

    function test_perpOpensAgainstSeededPool() public {
        // Seed the LP counterparty (mirrors SeedPerp).
        _fundUSDC(alice, 1_000_000e18);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000_000e18);
        pool.deposit(1_000_000e18);
        vm.stopPrank();
        assertGt(pool.totalAssets(), 0, "counterparty seeded");

        _fundUSDC(bob, 1_000e18);
        vm.startPrank(bob);
        usdc.approve(address(engine), 1_000e18);
        uint256 id = engine.open(100e18, 1e18, true, block.timestamp + 1); // 1 bAAPL long, $100 margin
        vm.stopPrank();

        (address owner,,,,,,) = engine.positions(id);
        assertEq(owner, bob, "position opened");
        assertGt(engine.healthFactor(id), 0, "health computed off live mark");
    }

    // ── LeverageModule ────────────────────────────────────────────────────────

    function test_leverageHealthReadsLiveOracle() public view {
        assertEq(address(module.nav()), address(oracle), "module wired to live NAVOracle");
        assertEq(address(module.depeg()), address(monitor), "module wired to live depeg breaker");
    }

    function test_leverageOpenLoopsThroughLiveOracle() public {
        // Fund the borrow reserve (mirrors LeverageModule.fundReserve seeding).
        _fundUSDC(address(this), 500_000e18);
        usdc.approve(address(module), type(uint256).max);
        module.fundReserve(500_000e18);

        _fundUSDC(bob, 1_000e18);
        vm.startPrank(bob);
        usdc.approve(address(module), 1_000e18);
        uint256 id = module.open(1_000e18, 2e18, 0, block.timestamp + 1); // 2x leverage
        vm.stopPrank();

        (address owner,, uint256 debt,) = module.positions(id);
        assertEq(owner, bob, "leveraged position opened");
        assertApproxEqAbs(debt, 1_000e18, 1, "borrowed 1x margin from reserve");
        // Health factor uses navPerShare off the live oracle and must clear the minimum.
        assertGe(module.healthFactor(id), module.minHealthFactor(), "healthy off live oracle");
    }
}
