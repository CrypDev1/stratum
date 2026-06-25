// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PriceLib } from "../../src/libraries/PriceLib.sol";

contract PriceLibTest is Test {
    using PriceLib for uint256;

    function test_scaleTo18_sameDecimals() public pure {
        assertEq(uint256(123e18).scaleTo18(18), 123e18);
    }

    function test_scaleTo18_up() public pure {
        // 8-decimal $100 -> 100e18
        assertEq(uint256(100e8).scaleTo18(8), 100e18);
    }

    function test_scaleTo18_down() public pure {
        // 24-decimal value -> 18 decimals
        assertEq(uint256(5e24).scaleTo18(24), 5e18);
    }

    function test_scaleTo18_revertsTooLarge() public {
        vm.expectRevert(abi.encodeWithSelector(PriceLib.DecimalsTooLarge.selector, uint8(78)));
        this.scaleExternal(1, 78);
    }

    function scaleExternal(uint256 p, uint8 d) external pure returns (uint256) {
        return p.scaleTo18(d);
    }

    /// @dev Upscaling then conceptually downscaling preserves magnitude for decimals <= 18.
    function testFuzz_scaleTo18_upMonotonic(uint256 price, uint8 decimals) public pure {
        decimals = uint8(bound(decimals, 0, 18));
        price = bound(price, 0, 1e30);
        uint256 scaled = price.scaleTo18(decimals);
        assertEq(scaled, price * (10 ** (18 - uint256(decimals))));
    }

    function test_deviationBps_zero() public pure {
        assertEq(uint256(100e18).deviationBps(100e18), 0);
    }

    function test_deviationBps_tenPct() public pure {
        assertEq(uint256(110e18).deviationBps(100e18), 1000);
        assertEq(uint256(90e18).deviationBps(100e18), 1000);
    }

    function test_deviationBps_zeroBaseline() public pure {
        assertEq(uint256(1).deviationBps(0), type(uint256).max);
    }

    function testFuzz_deviationBps_symmetricBounds(uint256 a, uint256 b) public pure {
        a = bound(a, 1, 1e30);
        b = bound(b, 1, 1e30);
        uint256 dev = a.deviationBps(b);
        // deviation is non-negative and equals |a-b|*1e4/b
        uint256 diff = a > b ? a - b : b - a;
        assertEq(dev, (diff * 10_000) / b);
    }

    function test_applyDriftBps_clampUp() public pure {
        // drift 5000bps requested but max is 1000bps -> +10%
        assertEq(uint256(100e18).applyDriftBps(5000, 1000), 110e18);
    }

    function test_applyDriftBps_clampDown() public pure {
        assertEq(uint256(100e18).applyDriftBps(-5000, 1000), 90e18);
    }

    function test_applyDriftBps_withinBound() public pure {
        assertEq(uint256(100e18).applyDriftBps(250, 1000), 1025e17); // +2.5% = 102.5e18
    }

    function test_applyDriftBps_floorsAtZero() public pure {
        // Even an absurd negative clamp cannot go below the bound; with max 20000 (200%) result floors at 0.
        assertEq(uint256(100e18).applyDriftBps(-20000, 20000), 0);
    }

    function testFuzz_applyDriftBps_neverExceedsBound(uint256 base, int256 drift, uint256 maxBps) public pure {
        base = bound(base, 0, 1e30);
        maxBps = bound(maxBps, 0, 9000); // < 100% so result stays in [0, ~2x]
        drift = bound(drift, -1e6, 1e6);
        uint256 out = base.applyDriftBps(drift, maxBps);
        uint256 maxOut = (base * (10_000 + maxBps)) / 10_000;
        uint256 minOut = (base * (10_000 - maxBps)) / 10_000;
        assertLe(out, maxOut);
        assertGe(out, minOut);
    }
}
