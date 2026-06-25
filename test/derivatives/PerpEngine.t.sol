// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { LiquidityPool } from "../../src/derivatives/LiquidityPool.sol";
import { PerpEngine } from "../../src/derivatives/PerpEngine.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../../src/interfaces/IDepegMonitor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PerpEngineTest is Fixtures {
    LiquidityPool internal pool;
    PerpEngine internal perp;
    address internal lp = address(0x11D);
    address internal trader = address(0x713);

    function setUp() public {
        _deployL0();
        pool = new LiquidityPool(admin, IERC20(address(usdc)));
        perp = new PerpEngine(
            admin,
            IERC20(address(usdc)),
            INAVOracle(address(oracle)),
            IDepegMonitor(address(monitor)),
            pool,
            address(aapl) // market priced by NAV
        );
        vm.prank(admin);
        pool.setEngine(address(perp));

        // LP seeds the pool.
        _fundUSDC(lp, 1_000_000e18);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000e18);
        vm.stopPrank();

        // Seed insurance.
        _fundUSDC(admin, 10_000e18);
        vm.startPrank(admin);
        usdc.approve(address(perp), type(uint256).max);
        perp.fundInsurance(10_000e18);
        vm.stopPrank();
    }

    function _open(address user, uint256 margin, uint256 size, bool isLong) internal returns (uint256 id) {
        _fundUSDC(user, margin);
        vm.startPrank(user);
        usdc.approve(address(perp), margin);
        id = perp.open(margin, size, isLong, block.timestamp + 1);
        vm.stopPrank();
    }

    function _systemStable() internal view returns (uint256) {
        return
            usdc.balanceOf(address(perp)) + usdc.balanceOf(address(pool)) + usdc.balanceOf(trader) + usdc.balanceOf(lp);
    }

    function test_openLong() public {
        uint256 id = _open(trader, 1_000e18, 5e18, true); // 5 * $200 = $1000 notional, ~1x
        (address owner, bool isLong, uint256 size,,,,) = perp.positions(id);
        assertEq(owner, trader);
        assertTrue(isLong);
        assertEq(size, 5e18);
    }

    function test_openRevertsWhenHalted() public {
        vm.prank(admin);
        monitor.setHalted(address(aapl), true);
        _fundUSDC(trader, 1_000e18);
        vm.startPrank(trader);
        usdc.approve(address(perp), 1_000e18);
        vm.expectRevert(PerpEngine.OracleUnsafe.selector);
        perp.open(1_000e18, 5e18, true, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_openRevertsWhenOracleStale() public {
        skip(2 days); // feed now stale (maxStaleness 1 day)
        _fundUSDC(trader, 1_000e18);
        vm.startPrank(trader);
        usdc.approve(address(perp), 1_000e18);
        vm.expectRevert(PerpEngine.OracleUnsafe.selector);
        perp.open(1_000e18, 5e18, true, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_longProfit() public {
        _fundUSDC(trader, 1_000e18);
        uint256 before = _systemStable(); // snapshot after minting margin into the system
        vm.startPrank(trader);
        usdc.approve(address(perp), 1_000e18);
        uint256 id = perp.open(1_000e18, 5e18, true, block.timestamp + 1);
        vm.stopPrank();
        _setAaplPrice(220e18); // +10%
        vm.prank(trader);
        uint256 payout = perp.close(id);
        // pnl = 5*(220-200)=100; payout ~ 999 (after 1 fee) + 100 = 1099
        assertApproxEqAbs(payout, 1_099e18, 2e18);
        // conservation: total stable unchanged
        assertApproxEqAbs(_systemStable(), before, 1);
    }

    function test_shortProfit() public {
        uint256 id = _open(trader, 1_000e18, 5e18, false);
        _setAaplPrice(180e18); // -10%
        vm.prank(trader);
        uint256 payout = perp.close(id);
        assertApproxEqAbs(payout, 1_099e18, 2e18); // short gains when price falls
    }

    function test_longLossPaidToPool() public {
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 id = _open(trader, 1_000e18, 5e18, true);
        _setAaplPrice(180e18); // -10% => loss 100
        vm.prank(trader);
        uint256 payout = perp.close(id);
        assertApproxEqAbs(payout, 899e18, 2e18); // 999 - 100
        // pool gained the loss
        assertGt(usdc.balanceOf(address(pool)), poolBefore);
    }

    function test_liquidation() public {
        // ~9x leverage: margin 1000, size 45 ($9000 notional)
        uint256 id = _open(trader, 1_000e18, 45e18, true);
        // drop to $185: loss = 45*15 = 675; equity ~ 999-675=324; maintenance 5% of ~8325 = 416 -> liquidatable
        _setAaplPrice(185e18);
        assertLt(perp.healthFactor(id), 1e18);
        vm.prank(bob);
        perp.liquidate(id);
        (address owner,,,,,,) = perp.positions(id);
        assertEq(owner, address(0)); // closed
    }

    function test_noLiquidationWhenHealthy() public {
        uint256 id = _open(trader, 1_000e18, 5e18, true); // 1x, very safe
        vm.prank(bob);
        vm.expectRevert(PerpEngine.NotLiquidatable.selector);
        perp.liquidate(id);
    }

    function test_noLiquidationWhenHalted() public {
        uint256 id = _open(trader, 1_000e18, 45e18, true);
        _setAaplPrice(185e18);
        vm.prank(admin);
        monitor.setHalted(address(aapl), true);
        vm.prank(bob);
        vm.expectRevert(PerpEngine.OracleUnsafe.selector);
        perp.liquidate(id);
    }

    function test_leverageCapEnforced() public {
        // margin 1000, size 100 ($20000) => 20x > 10x cap
        _fundUSDC(trader, 1_000e18);
        vm.startPrank(trader);
        usdc.approve(address(perp), 1_000e18);
        vm.expectRevert(PerpEngine.LeverageTooHigh.selector);
        perp.open(1_000e18, 100e18, true, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_fundingAccruesWithSkew() public {
        _open(trader, 1_000e18, 5e18, true); // long-skewed
        int256 idxBefore = perp.fundingIndex();
        skip(30 days);
        _refreshFeeds();
        perp.accrueFunding();
        assertGt(perp.fundingIndex(), idxBefore); // longs pay (positive)
    }

    function test_insuranceFundSolvent() public {
        // a sequence of trades should never make insuranceFund underflow (it's uint, would revert)
        uint256 id1 = _open(trader, 1_000e18, 45e18, true);
        _setAaplPrice(190e18);
        vm.prank(trader);
        perp.close(id1);
        assertLe(perp.insuranceFund(), usdc.balanceOf(address(perp)) + 1); // insurance backed by real balance
    }

    function testFuzz_pnlConservation(uint256 priceMul, bool isLong) public {
        _fundUSDC(trader, 1_000e18);
        uint256 before = _systemStable(); // snapshot after minting margin
        vm.startPrank(trader);
        usdc.approve(address(perp), 1_000e18);
        uint256 id = perp.open(1_000e18, 20e18, isLong, block.timestamp + 1); // 4x
        vm.stopPrank();
        priceMul = bound(priceMul, 9_500, 10_500); // ±5% so position stays solvent-ish
        _setAaplPrice(AAPL_PRICE * priceMul / 10_000);
        vm.prank(trader);
        perp.close(id);
        // no stable created or destroyed across the whole system
        assertApproxEqAbs(_systemStable(), before, 2);
    }
}
