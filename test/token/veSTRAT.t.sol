// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { veSTRAT } from "../../src/token/veSTRAT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract veSTRATTest is Test {
    STRAT internal strat;
    veSTRAT internal ve;
    address internal admin = address(this);
    address internal alice = address(0xA11);
    address internal bob = address(0xB0B);

    uint256 internal MAXTIME;

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 1_000_000e18);
        ve = new veSTRAT(IERC20(address(strat)));
        MAXTIME = ve.MAXTIME();
        strat.transfer(alice, 100_000e18);
        strat.transfer(bob, 100_000e18);
        vm.prank(alice);
        strat.approve(address(ve), type(uint256).max);
        vm.prank(bob);
        strat.approve(address(ve), type(uint256).max);
    }

    function test_lockGivesVotingPower() public {
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        // ~max lock => power ~ amount (minus week rounding)
        assertApproxEqRel(ve.balanceOf(alice), 1_000e18, 0.02e18);
    }

    function test_powerDecaysToZero() public {
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        uint256 start = ve.balanceOf(alice);
        skip(MAXTIME / 2);
        // ~half decayed
        assertApproxEqRel(ve.balanceOf(alice), start / 2, 0.05e18);
        skip(MAXTIME);
        assertEq(ve.balanceOf(alice), 0);
    }

    function test_totalSupplyTracksLocks() public {
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        vm.prank(bob);
        ve.createLock(2_000e18, block.timestamp + MAXTIME);
        // total ~ alice + bob
        assertApproxEqRel(ve.totalSupply(), ve.balanceOf(alice) + ve.balanceOf(bob), 0.02e18);
    }

    function test_increaseAmount() public {
        vm.startPrank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        uint256 before = ve.balanceOf(alice);
        ve.increaseAmount(1_000e18);
        vm.stopPrank();
        assertApproxEqRel(ve.balanceOf(alice), before * 2, 0.02e18);
    }

    function test_increaseUnlockTime() public {
        vm.startPrank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME / 2);
        uint256 before = ve.balanceOf(alice);
        ve.increaseUnlockTime(block.timestamp + MAXTIME);
        vm.stopPrank();
        assertGt(ve.balanceOf(alice), before); // longer lock => more power
    }

    function test_withdrawAfterExpiry() public {
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + 2 * 7 days);
        skip(3 * 7 days);
        uint256 balBefore = strat.balanceOf(alice);
        vm.prank(alice);
        ve.withdraw();
        assertEq(strat.balanceOf(alice) - balBefore, 1_000e18);
        assertEq(ve.balanceOf(alice), 0);
    }

    function test_cannotWithdrawBeforeExpiry() public {
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        vm.prank(alice);
        vm.expectRevert(veSTRAT.NotExpired.selector);
        ve.withdraw();
    }

    function test_cannotDoubleLock() public {
        vm.startPrank(alice);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        vm.expectRevert(veSTRAT.LockExists.selector);
        ve.createLock(1_000e18, block.timestamp + MAXTIME);
        vm.stopPrank();
    }

    function testFuzz_powerProportionalToTimeAndAmount(uint256 amount, uint256 lockWeeks) public {
        amount = bound(amount, 1e18, 50_000e18);
        lockWeeks = bound(lockWeeks, 1, 208); // up to ~4y
        uint256 end = block.timestamp + lockWeeks * 7 days;
        if (end > block.timestamp + MAXTIME) end = block.timestamp + MAXTIME;
        vm.prank(alice);
        ve.createLock(amount, end);
        uint256 expected = (amount * ((end / 7 days) * 7 days - block.timestamp)) / MAXTIME;
        assertApproxEqAbs(ve.balanceOf(alice), expected, 1e18);
    }
}
