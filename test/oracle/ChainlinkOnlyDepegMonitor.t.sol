// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ChainlinkOnlyDepegMonitor } from "../../src/oracle/ChainlinkOnlyDepegMonitor.sol";
import { NAVOracle } from "../../src/oracle/NAVOracle.sol";
import { ChainlinkAdapter } from "../../src/oracle/ChainlinkAdapter.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../../src/interfaces/IOracleAdapter.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { MockAggregatorV3 } from "../../src/mocks/MockAggregatorV3.sol";

/// @notice Unit tests for the additive Chainlink-only breaker: it trusts NAVOracle freshness only,
///         with no DEX dependency, and preserves the guardian halt fail-safe.
contract ChainlinkOnlyDepegMonitorTest is Test {
    address internal admin = address(0xA11CE);
    address internal asset = address(0xB57C);

    NAVOracle internal nav;
    MockAggregatorV3 internal feed;
    ChainlinkOnlyDepegMonitor internal monitor;

    uint64 internal constant MAX_STALENESS = 86_400;

    function setUp() public {
        vm.warp(1_782_900_000);
        vm.startPrank(admin);
        nav = new NAVOracle(admin);
        feed = new MockAggregatorV3(18, 195e18); // NVDAB-like, 18-dec, ~$195
        ChainlinkAdapter primary = new ChainlinkAdapter(IAggregatorV3(address(feed)));

        nav.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(primary)),
                secondary: IOracleAdapter(address(0)), // Chainlink-only: no DEX cross-check
                maxStaleness: MAX_STALENESS,
                maxClosedStaleness: 604_800,
                maxDeviationBps: 0,
                maxDriftBps: 1000,
                configured: false
            })
        );
        monitor = new ChainlinkOnlyDepegMonitor(admin, INAVOracle(address(nav)));
        vm.stopPrank();
    }

    function test_safeWhenFeedFresh() public view {
        assertTrue(monitor.isTradingSafe(asset), "fresh Chainlink feed -> safe");
        assertEq(monitor.depegBps(asset), 0, "no DEX -> depeg 0");
    }

    function test_unsafeWhenFeedStale() public {
        // Age the feed past maxStaleness without a new round.
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        assertFalse(monitor.isTradingSafe(asset), "stale Chainlink feed -> asset pauses");
    }

    function test_freshAgainAfterUpdate() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        assertFalse(monitor.isTradingSafe(asset));
        feed.setAnswer(196e18); // re-stamps updatedAt = now
        assertTrue(monitor.isTradingSafe(asset), "new round clears staleness");
    }

    function test_unsafeWhenZeroPrice() public {
        feed.setAnswer(0);
        assertFalse(monitor.isTradingSafe(asset), "zero price -> unsafe");
    }

    function test_guardianHaltForcesUnsafe() public {
        assertTrue(monitor.isTradingSafe(asset));
        vm.prank(admin);
        monitor.setHalted(asset, true);
        assertFalse(monitor.isTradingSafe(asset), "halt overrides a fresh price");
        vm.prank(admin);
        monitor.setHalted(asset, false);
        assertTrue(monitor.isTradingSafe(asset), "reset restores");
    }

    function test_unconfiguredAssetIsUnsafeNotRevert() public view {
        // NAVOracle.getPrice reverts on an unconfigured asset; the monitor must catch and return false.
        assertFalse(monitor.isTradingSafe(address(0xDEAD)), "unconfigured -> unsafe, no revert");
    }

    function test_onlyGuardianCanHalt() public {
        vm.expectRevert();
        vm.prank(address(0xBAD));
        monitor.setHalted(asset, true);
    }
}
