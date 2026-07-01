// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { veSTRAT } from "../../src/token/veSTRAT.sol";
import { FeeDistributor } from "../../src/token/FeeDistributor.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeDistributorTest is Test {
    STRAT internal strat;
    veSTRAT internal ve;
    FeeDistributor internal dist;
    MockERC20 internal usdc;
    address internal admin = address(this);
    address internal alice = address(0xA11);
    address internal bob = address(0xB0B);
    address internal feeSource = address(0xFEE);

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 1_000_000e18);
        ve = new veSTRAT(IERC20(address(strat)));
        usdc = new MockERC20("USDC", "USDC", 18);
        dist = new FeeDistributor(ve, IERC20(address(usdc)));

        strat.transfer(alice, 10_000e18);
        strat.transfer(bob, 10_000e18);
        vm.prank(alice);
        strat.approve(address(ve), type(uint256).max);
        vm.prank(bob);
        strat.approve(address(ve), type(uint256).max);
        uint256 mt = ve.MAXTIME();
        // alice locks 1000, bob locks 3000 -> 1:3 power
        vm.prank(alice);
        ve.createLock(1_000e18, block.timestamp + mt);
        vm.prank(bob);
        ve.createLock(3_000e18, block.timestamp + mt);

        usdc.mint(feeSource, 1_000_000e18);
        vm.prank(feeSource);
        usdc.approve(address(dist), type(uint256).max);
    }

    function test_proRataDistribution() public {
        // checkpoint both, notify fees this epoch
        vm.prank(alice);
        dist.checkpoint();
        vm.prank(bob);
        dist.checkpoint();
        uint256 epoch = dist.currentEpoch();
        vm.prank(feeSource);
        dist.notifyReward(4_000e18);

        // advance to next epoch to finalize
        skip(7 days);

        uint256 aClaim = dist.claimable(alice, epoch);
        uint256 bClaim = dist.claimable(bob, epoch);
        // alice 1/4, bob 3/4
        assertApproxEqRel(aClaim, 1_000e18, 0.01e18);
        assertApproxEqRel(bClaim, 3_000e18, 0.01e18);

        vm.prank(alice);
        dist.claim(epoch);
        vm.prank(bob);
        dist.claim(epoch);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000e18, 0.01e18);
        assertApproxEqRel(usdc.balanceOf(bob), 3_000e18, 0.01e18);
    }

    function test_noDoubleClaim() public {
        vm.prank(alice);
        dist.checkpoint();
        uint256 epoch = dist.currentEpoch();
        vm.prank(feeSource);
        dist.notifyReward(1_000e18);
        skip(7 days);

        vm.prank(alice);
        dist.claim(epoch);
        vm.prank(alice);
        vm.expectRevert(FeeDistributor.AlreadyClaimed.selector);
        dist.claim(epoch);
    }

    function test_cannotClaimUnfinalizedEpoch() public {
        vm.prank(alice);
        dist.checkpoint();
        uint256 epoch = dist.currentEpoch();
        vm.prank(feeSource);
        dist.notifyReward(1_000e18);
        vm.prank(alice);
        vm.expectRevert(FeeDistributor.NotFinalized.selector);
        dist.claim(epoch);
    }

    /// @dev Invariant: total claimed for an epoch never exceeds rewards notified (no fees created).
    function test_noFeesLostOrCreated() public {
        vm.prank(alice);
        dist.checkpoint();
        vm.prank(bob);
        dist.checkpoint();
        uint256 epoch = dist.currentEpoch();
        vm.prank(feeSource);
        dist.notifyReward(4_000e18);
        skip(7 days);

        vm.prank(alice);
        dist.claim(epoch);
        vm.prank(bob);
        dist.claim(epoch);
        // total claimed == notified (within rounding), never more
        assertLe(dist.epochClaimed(epoch), dist.epochReward(epoch));
        assertApproxEqAbs(dist.epochClaimed(epoch), 4_000e18, 2);
    }

    function testFuzz_claimsNeverExceedRewards(uint256 r, uint256 aLock, uint256 bLock) public {
        r = bound(r, 1e18, 1_000_000e18);
        aLock = bound(aLock, 1e18, 5_000e18);
        bLock = bound(bLock, 1e18, 5_000e18);
        // fresh locks already set in setUp; just checkpoint and distribute r
        vm.prank(alice);
        dist.checkpoint();
        vm.prank(bob);
        dist.checkpoint();
        uint256 epoch = dist.currentEpoch();
        vm.prank(feeSource);
        dist.notifyReward(r);
        skip(7 days);

        uint256 total;
        if (dist.claimable(alice, epoch) > 0) {
            vm.prank(alice);
            total += dist.claim(epoch);
        }
        if (dist.claimable(bob, epoch) > 0) {
            vm.prank(bob);
            total += dist.claim(epoch);
        }
        assertLe(total, r); // never distribute more than notified
    }
}
