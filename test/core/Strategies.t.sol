// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { MarketCapWeightStrategy } from "../../src/core/strategies/MarketCapWeightStrategy.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";

contract StrategiesTest is Fixtures {
    function setUp() public {
        _deployL0();
    }

    function _assets() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(aapl);
        a[1] = address(goog);
    }

    function test_fixedWeights() public {
        FixedWeightStrategy s = new FixedWeightStrategy(admin);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 6000;
        ws[1] = 4000;
        vm.prank(admin);
        s.setWeights(_assets(), ws);
        uint256[] memory got = s.targetWeights(_assets());
        assertEq(got[0], 6000);
        assertEq(got[1], 4000);
    }

    function test_fixedWeightsBadSumReverts() public {
        FixedWeightStrategy s = new FixedWeightStrategy(admin);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 6000;
        ws[1] = 5000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FixedWeightStrategy.BadSum.selector, uint256(11000)));
        s.setWeights(_assets(), ws);
    }

    function test_marketCapWeights() public {
        MarketCapWeightStrategy s = new MarketCapWeightStrategy(admin, INAVOracle(address(oracle)));
        // AAPL: $200 * 100 = 20000 cap; GOOG: $150 * 100 = 15000 cap; total 35000
        vm.startPrank(admin);
        s.setSharesOutstanding(address(aapl), 100);
        s.setSharesOutstanding(address(goog), 100);
        vm.stopPrank();

        uint256[] memory got = s.targetWeights(_assets());
        // AAPL 20000/35000 = 5714 bps; GOOG remainder
        assertApproxEqAbs(got[0], 5714, 1);
        assertEq(got[0] + got[1], 10_000);
    }

    function test_marketCapNoSupplyReverts() public {
        MarketCapWeightStrategy s = new MarketCapWeightStrategy(admin, INAVOracle(address(oracle)));
        vm.expectRevert(abi.encodeWithSelector(MarketCapWeightStrategy.NoSupply.selector, address(aapl)));
        s.targetWeights(_assets());
    }

    function testFuzz_marketCapSumsTo10000(uint256 sa, uint256 sg) public {
        sa = bound(sa, 1, 1e12);
        sg = bound(sg, 1, 1e12);
        MarketCapWeightStrategy s = new MarketCapWeightStrategy(admin, INAVOracle(address(oracle)));
        vm.startPrank(admin);
        s.setSharesOutstanding(address(aapl), sa);
        s.setSharesOutstanding(address(goog), sg);
        vm.stopPrank();
        uint256[] memory got = s.targetWeights(_assets());
        assertEq(got[0] + got[1], 10_000);
    }
}
