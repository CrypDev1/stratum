// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { EmissionsAutomation, IEmissionsMinterLike, IGaugeDistributorLike } from "../../src/token/EmissionsAutomation.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { EmissionsMinter } from "../../src/token/EmissionsMinter.sol";
import { GaugeDistributor } from "../../src/token/GaugeDistributor.sol";
import { GaugeController } from "../../src/token/GaugeController.sol";
import { veSTRAT } from "../../src/token/veSTRAT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Exercises the Chainlink-Automation emissions adapter against the real minter + distributor.
contract EmissionsAutomationTest is Test {
    address internal admin = address(0xA11CE);

    STRAT internal strat;
    EmissionsMinter internal minter;
    GaugeController internal controller;
    GaugeDistributor internal distributor;
    EmissionsAutomation internal auto_;

    uint256 internal constant RATE = 1e18; // 1 STRAT/sec
    uint256 internal constant MAX = 300_000_000e18;

    function setUp() public {
        vm.warp(1_782_900_000);
        vm.startPrank(admin);
        strat = new STRAT(admin, 0);
        minter = new EmissionsMinter(admin, strat, RATE, MAX);
        strat.grantRole(strat.MINTER(), address(minter));

        veSTRAT ve = new veSTRAT(IERC20(address(strat)));
        controller = new GaugeController(admin, ve);
        distributor = new GaugeDistributor(admin, IERC20(address(strat)), controller);

        auto_ = new EmissionsAutomation(
            admin, IEmissionsMinterLike(address(minter)), address(distributor), IGaugeDistributorLike(address(distributor)), 0
        );
        // The adapter must hold EMISSIONS_ADMIN to call emitTo.
        minter.grantRole(minter.EMISSIONS_ADMIN(), address(auto_));
        vm.stopPrank();
    }

    function test_checkUpkeepFalseWhenNothingAccrued() public view {
        // lastMint == now in setUp (no time elapsed).
        (bool needed,) = auto_.checkUpkeep("");
        assertFalse(needed, "no elapsed time -> nothing to do");
    }

    function test_checkUpkeepTrueAfterAccrual() public {
        vm.warp(block.timestamp + 100); // 100 STRAT accrued
        (bool needed,) = auto_.checkUpkeep("");
        assertTrue(needed);
    }

    function test_performMintsToDistributor() public {
        vm.warp(block.timestamp + 100);
        uint256 expected = minter.mintable();
        assertEq(expected, 100e18);

        auto_.performUpkeep("");
        assertEq(strat.balanceOf(address(distributor)), 100e18, "minted to distributor");
        assertEq(minter.mintable(), 0, "settled");
    }

    function test_performRespectsMinMintable() public {
        vm.prank(admin);
        auto_.setMinMintable(200e18);
        vm.warp(block.timestamp + 100); // only 100 accrued < 200 threshold
        (bool needed,) = auto_.checkUpkeep("");
        assertFalse(needed, "below threshold");
        auto_.performUpkeep(""); // no-op, must not revert
        assertEq(strat.balanceOf(address(distributor)), 0);
    }

    function test_forwarderGate() public {
        vm.prank(admin);
        auto_.setForwarder(address(0xF00D));
        vm.warp(block.timestamp + 100);
        vm.expectRevert(EmissionsAutomation.NotForwarder.selector);
        auto_.performUpkeep("");
        // The configured forwarder can call.
        vm.prank(address(0xF00D));
        auto_.performUpkeep("");
        assertEq(strat.balanceOf(address(distributor)), 100e18);
    }

    function test_onlyKeeperAdminTunes() public {
        vm.expectRevert();
        vm.prank(address(0xBAD));
        auto_.setMinMintable(1);
    }
}
