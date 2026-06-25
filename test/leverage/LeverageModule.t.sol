// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { LeverageModule } from "../../src/leverage/LeverageModule.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../../src/interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../../src/interfaces/ISwapRouter.sol";

contract LeverageModuleTest is Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
    LeverageModule internal module;
    address internal lp = address(0x11D);

    function setUp() public {
        _deployL0();
        _deployFactory();

        FixedWeightStrategy strat = new FixedWeightStrategy(admin);
        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(goog);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 5000;
        ws[1] = 5000;
        vm.prank(admin);
        strat.setWeights(assets, ws);

        index = IndexPortfolio(
            factory.createIndex("AI", "AI", address(usdc), _equalComponents(), 100, admin, address(strat), 200, 2000)
        );
        shareToken = PortfolioToken(index.shareToken());

        module = new LeverageModule(
            admin,
            IPortfolio(address(index)),
            INAVOracle(address(oracle)),
            IDepegMonitor(address(monitor)),
            ISwapRouter(address(router))
        );

        // fund the borrow reserve
        _fundUSDC(lp, 1_000_000e18);
        vm.startPrank(lp);
        usdc.approve(address(module), type(uint256).max);
        module.fundReserve(1_000_000e18);
        vm.stopPrank();
    }

    function _open(address user, uint256 margin, uint256 lev) internal returns (uint256 id) {
        _fundUSDC(user, margin);
        vm.startPrank(user);
        usdc.approve(address(module), margin);
        id = module.open(margin, lev, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_openLeverage() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        (address owner, uint256 coll, uint256 debt,) = module.positions(id);
        assertEq(owner, alice);
        assertEq(debt, 2_000e18); // 3x on 1000 => borrow 2000
        // collateral ~ 3000 worth of shares => 3000 shares (navPerShare ~1)
        assertApproxEqRel(coll, 3_000e18, 0.01e18);
        // leverage ~3x
        assertApproxEqRel(module.leverage(id), 3e18, 0.02e18);
    }

    function test_openRespectsMaxLeverage() public {
        _fundUSDC(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(module), 1_000e18);
        vm.expectRevert(LeverageModule.LeverageTooHigh.selector);
        module.open(1_000e18, 6e18, 0, block.timestamp + 1); // > 5x cap
        vm.stopPrank();
    }

    function test_healthFactorAboveOneWhenHealthy() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        // coll 3000 * 80% threshold / debt 2000 = 1.2
        assertApproxEqRel(module.healthFactor(id), 1.2e18, 0.02e18);
    }

    function test_priceDropReducesHealth() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        // drop prices 25% -> coll value 2250; HF = 2250*0.8/2000 = 0.9 -> liquidatable
        _setAaplPrice(AAPL_PRICE * 75 / 100);
        _setGoogPrice(GOOG_PRICE * 75 / 100);
        assertLt(module.healthFactor(id), 1e18);
    }

    function test_liquidateOnlyWhenUnhealthy() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        _fundUSDC(bob, 2_000e18);
        vm.startPrank(bob);
        usdc.approve(address(module), 2_000e18);
        vm.expectRevert(LeverageModule.NotLiquidatable.selector);
        module.liquidate(id, 1_000e18); // still healthy
        vm.stopPrank();
    }

    function test_liquidateWhenUnhealthyAndSafe() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        _setAaplPrice(AAPL_PRICE * 75 / 100);
        _setGoogPrice(GOOG_PRICE * 75 / 100);

        _fundUSDC(bob, 2_000e18);
        vm.startPrank(bob);
        usdc.approve(address(module), 2_000e18);
        module.liquidate(id, 1_000e18);
        vm.stopPrank();

        // liquidator received discounted shares
        assertGt(shareToken.balanceOf(bob), 0);
        (, uint256 coll, uint256 debt,) = module.positions(id);
        assertEq(debt, 1_000e18); // half repaid
        assertLt(coll, 3_000e18);
    }

    function test_noLiquidationWhenHalted() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        _setAaplPrice(AAPL_PRICE * 75 / 100);
        _setGoogPrice(GOOG_PRICE * 75 / 100);
        // trip circuit breaker
        vm.prank(admin);
        monitor.setHalted(address(aapl), true);

        _fundUSDC(bob, 2_000e18);
        vm.startPrank(bob);
        usdc.approve(address(module), 2_000e18);
        vm.expectRevert(LeverageModule.TradingHalted.selector);
        module.liquidate(id, 1_000e18);
        vm.stopPrank();
    }

    function test_repayRaisesHealth() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        uint256 hfBefore = module.healthFactor(id);
        _fundUSDC(alice, 500e18);
        vm.startPrank(alice);
        usdc.approve(address(module), 500e18);
        module.repay(id, 500e18);
        vm.stopPrank();
        assertGt(module.healthFactor(id), hfBefore);
    }

    function test_closeReturnsCollateral() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        (, uint256 coll, uint256 debt,) = module.positions(id);
        _fundUSDC(alice, debt);
        vm.startPrank(alice);
        usdc.approve(address(module), debt);
        module.close(id);
        vm.stopPrank();
        assertEq(shareToken.balanceOf(alice), coll);
        (address owner,,,) = module.positions(id);
        assertEq(owner, address(0));
    }

    function test_deleverageReducesLeverage() public {
        uint256 id = _open(alice, 1_000e18, 3e18);
        uint256 levBefore = module.leverage(id);
        (, uint256 coll,,) = module.positions(id);
        vm.prank(alice);
        module.deleverage(id, coll / 3, 0, block.timestamp + 1);
        assertLt(module.leverage(id), levBefore);
    }

    function test_openRevertsNoReserve() public {
        // drain reserve by opening a huge position is bounded; instead deploy fresh module w/o reserve
        LeverageModule m2 = new LeverageModule(
            admin,
            IPortfolio(address(index)),
            INAVOracle(address(oracle)),
            IDepegMonitor(address(monitor)),
            ISwapRouter(address(router))
        );
        _fundUSDC(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(m2), 1_000e18);
        vm.expectRevert(LeverageModule.NoReserve.selector);
        m2.open(1_000e18, 3e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }
}
