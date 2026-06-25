// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ChainlinkAdapter } from "../../src/oracle/ChainlinkAdapter.sol";
import { MockAggregatorV3 } from "../../src/mocks/MockAggregatorV3.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";

contract ChainlinkAdapterTest is Test {
    MockAggregatorV3 internal feed;
    ChainlinkAdapter internal adapter;

    function setUp() public {
        feed = new MockAggregatorV3(8, 100e8); // $100 at 8 decimals
        adapter = new ChainlinkAdapter(IAggregatorV3(address(feed)));
    }

    function test_scalesTo18() public view {
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, 100e18);
    }

    function test_revertsOnNonPositive() public {
        feed.setRound(0, block.timestamp, 2, 2);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.NonPositiveAnswer.selector, int256(0)));
        adapter.latestPrice();
    }

    function test_revertsOnStaleRound() public {
        // answeredInRound < roundId
        feed.setRound(100e8, block.timestamp, 5, 4);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.StaleRound.selector, uint80(5), uint80(4)));
        adapter.latestPrice();
    }

    function test_reportsUpdatedAt() public {
        vm.warp(1_000_000);
        feed.setAnswer(123e8);
        (uint256 price, uint256 updatedAt) = adapter.latestPrice();
        assertEq(price, 123e18);
        assertEq(updatedAt, 1_000_000);
    }

    function testFuzz_scaling(uint256 raw) public {
        raw = bound(raw, 1, 1e20);
        feed.setAnswer(int256(raw));
        (uint256 price,) = adapter.latestPrice();
        assertEq(price, raw * 1e10); // 8 -> 18 decimals
    }
}
