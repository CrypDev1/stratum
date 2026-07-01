// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { veSTRAT } from "../../src/token/veSTRAT.sol";
import { GaugeController } from "../../src/token/GaugeController.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GaugeControllerTest is Test {
    STRAT internal strat;
    veSTRAT internal ve;
    GaugeController internal gc;
    address internal admin = address(this);
    address internal alice = address(0xA11);
    address internal bob = address(0xB0B);
    address internal gaugeA = address(0xA1);
    address internal gaugeB = address(0xB2);

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 1_000_000e18);
        ve = new veSTRAT(IERC20(address(strat)));
        gc = new GaugeController(admin, ve);
        gc.addGauge(gaugeA);
        gc.addGauge(gaugeB);

        strat.transfer(alice, 10_000e18);
        strat.transfer(bob, 10_000e18);
        vm.prank(alice);
        strat.approve(address(ve), type(uint256).max);
        vm.prank(bob);
        strat.approve(address(ve), type(uint256).max);
        uint256 mt = ve.MAXTIME();
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + mt);
        vm.prank(bob);
        ve.createLock(1_000e18, block.timestamp + mt);
    }

    function test_voteDirectsWeight() public {
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000); // 100% to A
        assertEq(gc.relativeWeight(gaugeA), 1e18);
        assertEq(gc.relativeWeight(gaugeB), 0);
    }

    function test_weightsNormalizeAcrossGauges() public {
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000); // all alice to A
        vm.prank(bob);
        gc.voteForGauge(gaugeB, 10_000); // all bob to B
        // equal ve power => 50/50
        assertApproxEqRel(gc.relativeWeight(gaugeA), 0.5e18, 0.02e18);
        assertApproxEqRel(gc.relativeWeight(gaugeB), 0.5e18, 0.02e18);
        // sum to 1e18
        assertApproxEqAbs(gc.relativeWeight(gaugeA) + gc.relativeWeight(gaugeB), 1e18, 2);
    }

    function test_splitVote() public {
        vm.startPrank(alice);
        gc.voteForGauge(gaugeA, 6_000);
        gc.voteForGauge(gaugeB, 4_000);
        vm.stopPrank();
        assertApproxEqRel(gc.relativeWeight(gaugeA), 0.6e18, 0.01e18);
        assertApproxEqRel(gc.relativeWeight(gaugeB), 0.4e18, 0.01e18);
    }

    function test_revoteReplaces() public {
        vm.startPrank(alice);
        gc.voteForGauge(gaugeA, 10_000);
        gc.voteForGauge(gaugeA, 5_000); // reduce
        vm.stopPrank();
        assertEq(gc.userGaugeBps(alice, gaugeA), 5_000);
        assertEq(gc.userUsedBps(alice), 5_000);
    }

    function test_overAllocationReverts() public {
        vm.startPrank(alice);
        gc.voteForGauge(gaugeA, 7_000);
        vm.expectRevert(GaugeController.OverAllocated.selector);
        gc.voteForGauge(gaugeB, 4_000); // 7000+4000 > 10000
        vm.stopPrank();
    }

    function test_voteOnNonGaugeReverts() public {
        vm.prank(alice);
        vm.expectRevert(GaugeController.NotGauge.selector);
        gc.voteForGauge(address(0xDEAD), 1_000);
    }
}
