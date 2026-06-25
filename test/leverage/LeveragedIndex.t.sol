// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { LeverageModule } from "../../src/leverage/LeverageModule.sol";
import { LeveragedIndex } from "../../src/leverage/LeveragedIndex.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../../src/interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../../src/interfaces/ISwapRouter.sol";

contract LeveragedIndexTest is Fixtures {
    IndexPortfolio internal index;
    LeverageModule internal module;
    LeveragedIndex internal lev;
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
        module = new LeverageModule(
            admin,
            IPortfolio(address(index)),
            INAVOracle(address(oracle)),
            IDepegMonitor(address(monitor)),
            ISwapRouter(address(router))
        );
        _fundUSDC(lp, 5_000_000e18);
        vm.startPrank(lp);
        usdc.approve(address(module), type(uint256).max);
        module.fundReserve(5_000_000e18);
        vm.stopPrank();

        lev = new LeveragedIndex("Lev AI 2x", "LAI2", admin, module, 2e18);
        // The LeveragedIndex must be able to open positions on the module (it's the position owner).
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        _fundUSDC(user, amount);
        vm.startPrank(user);
        usdc.approve(address(lev), amount);
        shares = lev.deposit(amount, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_firstDepositEquityPerShareOne() public {
        uint256 shares = _deposit(alice, 1_000e18);
        // equity ~ margin (1000), shares ~ 1000
        assertApproxEqRel(shares, 1_000e18, 0.02e18);
        assertApproxEqRel(lev.equityPerShare(), 1e18, 0.02e18);
        // leverage ~2x
        assertApproxEqRel(module.leverage(lev.positionId()), 2e18, 0.02e18);
    }

    function test_secondDepositFairShares() public {
        _deposit(alice, 1_000e18);
        uint256 bobShares = _deposit(bob, 500e18);
        assertApproxEqRel(bobShares, 500e18, 0.03e18);
    }

    function test_gainIncreasesEquityPerShare() public {
        _deposit(alice, 1_000e18);
        // +10% price -> 2x leverage => ~+20% equity
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        assertApproxEqRel(lev.equityPerShare(), 1.2e18, 0.03e18);
    }

    function test_withdrawReturnsStable() public {
        _deposit(alice, 1_000e18);
        uint256 shares = lev.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        lev.withdraw(shares / 2, block.timestamp + 1);
        assertGt(usdc.balanceOf(alice) - balBefore, 0);
        assertApproxEqRel(lev.balanceOf(alice), shares / 2, 0.001e18);
    }

    function test_rebalanceLeverageBackToTarget() public {
        _deposit(alice, 1_000e18);
        // price rises -> leverage falls below target (equity grows faster than debt)
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);
        uint256 levBefore = module.leverage(lev.positionId());
        assertLt(levBefore, 2e18); // drifted below target

        vm.prank(admin);
        lev.rebalanceLeverage(block.timestamp + 1);
        assertApproxEqRel(module.leverage(lev.positionId()), 2e18, 0.03e18);
    }

    function test_onlyKeeperRebalances() public {
        _deposit(alice, 1_000e18);
        vm.prank(bob);
        vm.expectRevert();
        lev.rebalanceLeverage(block.timestamp + 1);
    }
}
