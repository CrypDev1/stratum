// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { STRAT } from "../../src/token/STRAT.sol";
import { EmissionsMinter } from "../../src/token/EmissionsMinter.sol";

contract EmissionsTest is Test {
    STRAT internal strat;
    EmissionsMinter internal minter;
    address internal admin = address(this);
    address internal gauge = address(0x6A06E);

    uint256 internal constant CAP = 1_000_000_000e18;
    uint256 internal constant RATE = 1e18; // 1 STRAT/sec

    function setUp() public {
        vm.warp(1_700_000_000);
        strat = new STRAT(admin, 100_000_000e18); // 100M initial
        minter = new EmissionsMinter(admin, strat, RATE, CAP); // generous max for the rate-mechanics tests
        strat.grantRole(strat.MINTER(), address(minter));
    }

    function test_capEnforced() public view {
        assertEq(strat.cap(), CAP);
        assertEq(strat.totalSupply(), 100_000_000e18);
    }

    function test_onlyMinterMints() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        strat.mint(address(0xBEEF), 1e18);
    }

    function test_emissionsLinear() public {
        skip(100);
        assertEq(minter.mintable(), 100e18);
        uint256 emitted = minter.emitTo(gauge);
        assertEq(emitted, 100e18);
        assertEq(strat.balanceOf(gauge), 100e18);
        assertEq(minter.mintable(), 0); // reset
    }

    function test_emissionsNeverExceedSchedule() public {
        skip(50);
        minter.emitTo(gauge);
        skip(50);
        // total emitted after 100s at 1/sec = 100, never more
        assertEq(strat.balanceOf(gauge), 50e18);
        minter.emitTo(gauge);
        assertEq(strat.balanceOf(gauge), 100e18);
        assertEq(minter.totalEmitted(), 100e18);
    }

    function test_rateChangeNotRetroactive() public {
        skip(10);
        // settle 10 at old rate then change rate
        minter.setRate(2e18, gauge);
        assertEq(strat.balanceOf(gauge), 10e18); // old rate settled
        skip(10);
        assertEq(minter.mintable(), 20e18); // new rate
    }

    function testFuzz_emissionsBounded(uint256 t) public {
        t = bound(t, 0, 365 days);
        skip(t);
        assertEq(minter.mintable(), RATE * t);
    }
}
