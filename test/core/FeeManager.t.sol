// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { FeeManager } from "../../src/core/FeeManager.sol";

contract FeeManagerTest is Test {
    FeeManager internal fm;

    function setUp() public {
        fm = new FeeManager();
    }

    function test_managementFeeZeroCases() public view {
        assertEq(fm.managementFeeShares(0, 100, 365 days), 0);
        assertEq(fm.managementFeeShares(1e18, 0, 365 days), 0);
        assertEq(fm.managementFeeShares(1e18, 100, 0), 0);
    }

    function test_managementFeeOneYearTwoPct() public view {
        // 2% annual on 1e18 supply over a full year -> dilute holders by ~2%.
        uint256 shares = fm.managementFeeShares(1e18, 200, 365 days);
        // feeShares / (supply + feeShares) ~= 0.02
        uint256 frac = (shares * 1e18) / (1e18 + shares);
        assertApproxEqAbs(frac, 0.02e18, 1e12);
    }

    function test_managementFeeTooHighReverts() public {
        vm.expectRevert(FeeManager.FeeTooHigh.selector);
        fm.managementFeeShares(1e18, 2001, 365 days);
    }

    function test_performanceFeeBelowHWMZero() public view {
        assertEq(fm.performanceFeeShares(1e18, 1e18, 1e18, 2000), 0);
        assertEq(fm.performanceFeeShares(1e18, 9e17, 1e18, 2000), 0);
    }

    function test_performanceFeeProfit() public view {
        // navPS 1.1e18, HWM 1.0e18 => profit/nav = 0.1/1.1 = 0.0909; * 20% perf = 0.01818 of NAV.
        uint256 shares = fm.performanceFeeShares(1e18, 11e17, 1e18, 2000);
        uint256 frac = (shares * 1e18) / (1e18 + shares);
        assertApproxEqAbs(frac, 0.018181e18, 1e15);
        assertGt(shares, 0);
    }

    function test_performanceFeeTooHighReverts() public {
        vm.expectRevert(FeeManager.FeeTooHigh.selector);
        fm.performanceFeeShares(1e18, 11e17, 1e18, 5001);
    }

    function testFuzz_managementFeeMonotonic(uint256 elapsed) public view {
        elapsed = bound(elapsed, 1, 365 days);
        uint256 shares = fm.managementFeeShares(1_000e18, 1000, elapsed);
        // fee never dilutes more than the cap fraction for the elapsed window
        uint256 frac = (shares * 1e18) / (1_000e18 + shares);
        uint256 maxFrac = (1000 * elapsed * 1e18) / (10_000 * 365 days) + 1e12;
        assertLe(frac, maxFrac);
    }

    function testFuzz_performanceNeverChargesAtOrBelowHWM(uint256 navPS, uint256 hwm) public view {
        navPS = bound(navPS, 1, 1e30);
        hwm = bound(hwm, navPS, 1e30); // hwm >= navPS
        assertEq(fm.performanceFeeShares(1e18, navPS, hwm, 2000), 0);
    }
}
