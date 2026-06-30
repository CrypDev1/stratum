// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { veSTRAT } from "../../src/token/veSTRAT.sol";
import { GaugeController } from "../../src/token/GaugeController.sol";
import { GaugeDistributor } from "../../src/token/GaugeDistributor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GaugeDistributorTest is Test {
    STRAT internal strat;
    veSTRAT internal ve;
    GaugeController internal gc;
    GaugeDistributor internal dist;

    address internal admin = address(this);
    address internal alice = address(0xA11);
    address internal bob = address(0xB0B);
    address internal gaugeA = address(0xA1);
    address internal gaugeB = address(0xB2);
    address internal receiverA = address(0xCAFE);

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 10_000_000e18);
        ve = new veSTRAT(IERC20(address(strat)));
        gc = new GaugeController(admin, ve);
        dist = new GaugeDistributor(admin, IERC20(address(strat)), gc);

        gc.addGauge(gaugeA);
        gc.addGauge(gaugeB);

        // Equal ve power for alice and bob.
        strat.transfer(alice, 10_000e18);
        strat.transfer(bob, 10_000e18);
        uint256 mt = ve.MAXTIME();
        vm.startPrank(alice);
        strat.approve(address(ve), type(uint256).max);
        ve.createLock(1_000e18, block.timestamp + mt);
        vm.stopPrank();
        vm.startPrank(bob);
        strat.approve(address(ve), type(uint256).max);
        ve.createLock(1_000e18, block.timestamp + mt);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        strat.transfer(address(dist), amount); // simulate EmissionsMinter.emitTo(dist)
    }

    function test_splitsByRelativeWeight() public {
        // alice -> A, bob -> B : 50/50.
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000);
        vm.prank(bob);
        gc.voteForGauge(gaugeB, 10_000);

        _fund(1_000e18);
        dist.distribute();

        assertApproxEqRel(dist.gaugeAccrued(gaugeA), 500e18, 0.02e18, "A ~50%");
        assertApproxEqRel(dist.gaugeAccrued(gaugeB), 500e18, 0.02e18, "B ~50%");
        // Conservation: allocated <= funded; remainder is undistributed dust.
        assertLe(dist.totalAccrued(), 1_000e18);
        assertEq(dist.totalAccrued() + dist.undistributed(), 1_000e18, "funds conserved");
    }

    function test_claimToConfiguredReceiver() public {
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000); // 100% to A
        _fund(1_000e18);
        dist.distribute();

        dist.setRewardReceiver(gaugeA, receiverA);
        assertEq(dist.receiverOf(gaugeA), receiverA);

        uint256 accrued = dist.gaugeAccrued(gaugeA);
        assertGt(accrued, 0);
        uint256 claimed = dist.claim(gaugeA);

        assertEq(claimed, accrued);
        assertEq(strat.balanceOf(receiverA), accrued, "paid to receiver");
        assertEq(dist.gaugeAccrued(gaugeA), 0, "zeroed");
        assertEq(dist.totalAccrued(), 0, "total cleared");
    }

    function test_claimDefaultsToGaugeAddress() public {
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000);
        _fund(1_000e18);
        dist.distribute();

        uint256 accrued = dist.gaugeAccrued(gaugeA);
        dist.claim(gaugeA);
        assertEq(strat.balanceOf(gaugeA), accrued, "default receiver is the gauge");
    }

    function test_noVotesAllocatesNothingAndConserves() public {
        _fund(1_000e18);
        uint256 distributed = dist.distribute();
        assertEq(distributed, 0, "nothing allocated without votes");
        assertEq(dist.undistributed(), 1_000e18, "balance retained for later");
    }

    function test_distributeIsIncremental() public {
        vm.prank(alice);
        gc.voteForGauge(gaugeA, 10_000); // 100% A

        _fund(400e18);
        dist.distribute();
        assertApproxEqRel(dist.gaugeAccrued(gaugeA), 400e18, 0.001e18);

        _fund(600e18);
        dist.distribute(); // only the new 600 is allocated
        assertApproxEqRel(dist.gaugeAccrued(gaugeA), 1_000e18, 0.001e18);
    }

    function test_setReceiverRequiresAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        dist.setRewardReceiver(gaugeA, receiverA);
    }
}
