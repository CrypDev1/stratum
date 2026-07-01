// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { EmissionsMinter } from "../../src/token/EmissionsMinter.sol";
import { TeamVesting } from "../../src/token/TeamVesting.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Asserts the final STRAT supply (1,000,000,000) and the 50/30/5/15 distribution wired exactly as
///         the deploy script does it: liquidity + emissions + team-vesting + treasury == the hard cap.
contract DistributionTest is Test {
    // Fixed supply & allocation (mirrors script/Deploy.s.sol).
    uint256 internal constant CAP = 1_000_000_000e18;
    uint256 internal constant LIQUIDITY_ALLOC = 500_000_000e18; // 50%
    uint256 internal constant EMISSIONS_ALLOC = 300_000_000e18; // 30%
    uint256 internal constant TEAM_ALLOC = 50_000_000e18; //  5%
    uint256 internal constant TREASURY_ALLOC = 150_000_000e18; // 15%

    uint256 internal constant EMISSIONS_PERIOD = 365 days;
    uint256 internal constant TEAM_CLIFF = 90 days; // 3 months
    uint256 internal constant TEAM_VESTING = 730 days; // 24 months
    uint256 internal constant RATE = EMISSIONS_ALLOC / EMISSIONS_PERIOD;

    address internal admin = address(this);
    address internal liquidityWallet = address(0x11D);
    address internal treasuryWallet = address(0x7AEA);
    address internal teamBeneficiary = address(0x7EA1);
    address internal gauge = address(0x6A06E);

    STRAT internal strat;
    EmissionsMinter internal emissions;
    TeamVesting internal teamVesting;

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 0);
        emissions = new EmissionsMinter(admin, strat, RATE, EMISSIONS_ALLOC);
        teamVesting = new TeamVesting(IERC20(address(strat)), teamBeneficiary, TEAM_CLIFF, TEAM_VESTING);

        // The four allocations must sum to exactly the hard cap.
        assertEq(LIQUIDITY_ALLOC + EMISSIONS_ALLOC + TEAM_ALLOC + TREASURY_ALLOC, strat.cap());

        // Distribute the three up-front allocations, then hand the remaining 30% to the emissions minter.
        strat.grantRole(strat.MINTER(), admin);
        strat.mint(liquidityWallet, LIQUIDITY_ALLOC);
        strat.mint(treasuryWallet, TREASURY_ALLOC);
        strat.mint(address(teamVesting), TEAM_ALLOC);
        strat.revokeRole(strat.MINTER(), admin);
        strat.grantRole(strat.MINTER(), address(emissions));
    }

    // ── Supply & allocations ──

    function test_hardCapIsExactlyOneBillion() public view {
        assertEq(strat.cap(), CAP);
        assertEq(strat.MAX_SUPPLY(), CAP);
    }

    function test_upfrontSupplyIs700M() public view {
        // 50% + 15% + 5% minted at deploy; the 30% emissions stream is not yet minted.
        assertEq(strat.totalSupply(), LIQUIDITY_ALLOC + TREASURY_ALLOC + TEAM_ALLOC);
        assertEq(strat.totalSupply(), 700_000_000e18);
    }

    function test_eachAllocationLandsAtTheRightAddress() public view {
        assertEq(strat.balanceOf(liquidityWallet), LIQUIDITY_ALLOC);
        assertEq(strat.balanceOf(treasuryWallet), TREASURY_ALLOC);
        assertEq(strat.balanceOf(address(teamVesting)), TEAM_ALLOC);
    }

    function test_fullSupplyIsExactlyOneBillionAfterEmissions() public {
        // Run the full 12-month schedule (plus slack to settle integer-division dust) to completion.
        skip(EMISSIONS_PERIOD + 30 days);
        emissions.emitTo(gauge);
        assertEq(emissions.totalEmitted(), EMISSIONS_ALLOC);
        assertEq(strat.balanceOf(gauge), EMISSIONS_ALLOC);
        assertEq(strat.totalSupply(), CAP);
    }

    // ── Emissions: 300M cap, completes at ~365 days ──

    function test_emissionsCompleteAtAboutOneYear() public {
        skip(EMISSIONS_PERIOD);
        // After 365 days essentially the whole 300M has accrued (off only by integer-division dust).
        assertApproxEqAbs(emissions.mintable(), EMISSIONS_ALLOC, 1e18);
        uint256 emitted = emissions.emitTo(gauge);
        assertApproxEqAbs(emitted, EMISSIONS_ALLOC, 1e18);
        assertLe(emissions.totalEmitted(), EMISSIONS_ALLOC);
    }

    function test_emissionsNeverExceed300M() public {
        // Far past the schedule: emissions are clipped to exactly the 300M allocation, never more.
        skip(10 * 365 days);
        assertEq(emissions.mintable(), EMISSIONS_ALLOC);
        emissions.emitTo(gauge);
        assertEq(emissions.totalEmitted(), EMISSIONS_ALLOC);
        assertEq(strat.balanceOf(gauge), EMISSIONS_ALLOC);

        // Any further attempt accrues nothing and mints nothing.
        skip(365 days);
        assertEq(emissions.mintable(), 0);
        assertEq(emissions.emitTo(gauge), 0);
        assertEq(emissions.totalEmitted(), EMISSIONS_ALLOC);
        assertEq(strat.totalSupply(), CAP);
    }

    function test_emissionsCannotPushSupplyOverCap() public {
        skip(10 * 365 days);
        emissions.emitTo(gauge);
        // Cap reached — minting even 1 wei more must revert (ERC20Capped).
        vm.prank(address(emissions));
        vm.expectRevert();
        strat.mint(gauge, 1);
    }

    // ── Team vesting: 3-month cliff, then 24-month linear ──

    function test_teamLockedUntilCliff() public {
        assertEq(teamVesting.releasable(), 0);

        // Just before the cliff: still fully locked.
        skip(TEAM_CLIFF - 1);
        assertEq(teamVesting.vestedAmount(block.timestamp), 0);
        assertEq(teamVesting.releasable(), 0);
        vm.expectRevert(TeamVesting.NothingToRelease.selector);
        teamVesting.release();

        // Exactly at the cliff: linear vesting starts from zero.
        skip(1);
        assertEq(teamVesting.vestedAmount(block.timestamp), 0);
    }

    function test_teamVestsLinearlyAfterCliff() public {
        // Halfway through the 24-month linear period → ~half vested.
        skip(TEAM_CLIFF + TEAM_VESTING / 2);
        assertApproxEqAbs(teamVesting.releasable(), TEAM_ALLOC / 2, 1e18);

        uint256 firstClaim = teamVesting.release();
        assertApproxEqAbs(firstClaim, TEAM_ALLOC / 2, 1e18);
        assertApproxEqAbs(strat.balanceOf(teamBeneficiary), TEAM_ALLOC / 2, 1e18);
    }

    function test_teamFullyVestedAtCliffPlus24Months() public {
        skip(TEAM_CLIFF + TEAM_VESTING);
        assertEq(teamVesting.vestedAmount(block.timestamp), TEAM_ALLOC);
        assertEq(teamVesting.releasable(), TEAM_ALLOC);

        teamVesting.release();
        assertEq(strat.balanceOf(teamBeneficiary), TEAM_ALLOC);
        assertEq(strat.balanceOf(address(teamVesting)), 0);

        // Nothing left to release.
        vm.expectRevert(TeamVesting.NothingToRelease.selector);
        teamVesting.release();
    }

    function test_teamNeverOverVests() public {
        // Long after full vesting, the beneficiary still only ever receives the 50M allocation.
        skip(TEAM_CLIFF + TEAM_VESTING + 5 * 365 days);
        teamVesting.release();
        assertEq(strat.balanceOf(teamBeneficiary), TEAM_ALLOC);
    }
}
