// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NAVOracle } from "../../src/oracle/NAVOracle.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../../src/interfaces/IOracleAdapter.sol";
import { MockOracleAdapter } from "../../src/mocks/MockOracleAdapter.sol";

contract NAVOracleTest is Test {
    NAVOracle internal oracle;
    MockOracleAdapter internal primary;
    MockOracleAdapter internal secondary;

    address internal admin = address(0xA11CE);
    address internal asset = address(0xBEEF);
    address internal keeper = address(0xC0FFEE);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new NAVOracle(admin);
        primary = new MockOracleAdapter(100e18, block.timestamp);
        secondary = new MockOracleAdapter(100e18, block.timestamp);

        vm.startPrank(admin);
        oracle.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(primary)),
                secondary: IOracleAdapter(address(secondary)),
                maxStaleness: 3600,
                maxClosedStaleness: 4 days,
                maxDeviationBps: 200,
                maxDriftBps: 1000,
                configured: false
            })
        );
        oracle.grantRole(oracle.MARKET_KEEPER(), keeper);
        vm.stopPrank();
    }

    function test_configuredDefaultsOpen() public view {
        assertTrue(oracle.marketOpen(asset));
    }

    function test_openReturnsPrimary() public view {
        (uint256 price, uint256 updatedAt, bool stale) = oracle.getPrice(asset);
        assertEq(price, 100e18);
        assertEq(updatedAt, block.timestamp);
        assertFalse(stale);
    }

    function test_openStaleWhenPrimaryOld() public {
        skip(3601);
        (,, bool stale) = oracle.getPrice(asset);
        assertTrue(stale);
    }

    function test_deviationFlagsStale() public {
        secondary.setPrice(105e18); // 5% deviation > 2% guard
        (,, bool stale) = oracle.getPrice(asset);
        assertTrue(stale);
    }

    function test_deviationWithinGuardNotStale() public {
        secondary.setPrice(101e18); // 1% < 2%
        (,, bool stale) = oracle.getPrice(asset);
        assertFalse(stale);
    }

    function test_closeCapturesPriceAndFlagsAfterHours() public {
        vm.prank(keeper);
        oracle.setMarketStatus(asset, false);

        INAVOracle.PriceData memory d = oracle.getPriceData(asset);
        assertEq(d.price, 100e18);
        assertTrue(d.afterHours);
        assertFalse(d.isStale);
        assertFalse(oracle.marketOpen(asset));
    }

    function test_afterHoursDriftApplied() public {
        vm.startPrank(keeper);
        oracle.setMarketStatus(asset, false);
        oracle.setImpliedDrift(asset, 500); // +5%
        vm.stopPrank();

        INAVOracle.PriceData memory d = oracle.getPriceData(asset);
        assertEq(d.price, 105e18);
        assertTrue(d.afterHours);
    }

    function test_afterHoursDriftClampedToBound() public {
        vm.startPrank(keeper);
        oracle.setMarketStatus(asset, false);
        oracle.setImpliedDrift(asset, 9999); // way over 10% bound
        vm.stopPrank();

        INAVOracle.PriceData memory d = oracle.getPriceData(asset);
        assertEq(d.price, 110e18); // clamped to +10%
    }

    function test_closedStaleAfterWindow() public {
        vm.prank(keeper);
        oracle.setMarketStatus(asset, false);
        skip(4 days + 1);
        (,, bool stale) = oracle.getPrice(asset);
        assertTrue(stale);
    }

    function test_reopenClearsDrift() public {
        vm.startPrank(keeper);
        oracle.setMarketStatus(asset, false);
        oracle.setImpliedDrift(asset, 500);
        oracle.setMarketStatus(asset, true);
        vm.stopPrank();

        // back to live primary
        (uint256 price,, bool stale) = oracle.getPrice(asset);
        assertEq(price, 100e18);
        assertFalse(stale);
        NAVOracle.MarketState memory m = oracle.marketState(asset);
        assertEq(m.driftBps, 0);
    }

    function test_recordCloseFallback() public {
        vm.prank(keeper);
        oracle.recordClose(asset, 99e18);
        // still open, but record stored
        NAVOracle.MarketState memory m = oracle.marketState(asset);
        assertEq(m.lastClosePrice, 99e18);
    }

    function test_revertUnconfigured() public {
        vm.expectRevert(abi.encodeWithSelector(NAVOracle.AssetNotConfigured.selector, address(0x1234)));
        oracle.getPrice(address(0x1234));
    }

    function test_revertNoClosePrice() public {
        // configure a fresh asset whose close was never captured, then mark closed via recordClose=0 path
        address a2 = address(0x2222);
        MockOracleAdapter p2 = new MockOracleAdapter(0, block.timestamp); // zero price
        vm.startPrank(admin);
        oracle.configureAsset(
            a2,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(p2)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 3600,
                maxClosedStaleness: 4 days,
                maxDeviationBps: 200,
                maxDriftBps: 1000,
                configured: false
            })
        );
        vm.stopPrank();
        vm.prank(keeper);
        oracle.setMarketStatus(a2, false); // captures 0 close price
        vm.expectRevert(abi.encodeWithSelector(NAVOracle.NoClosePrice.selector, a2));
        oracle.getPrice(a2);
    }

    function test_onlyAdminConfigures() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(primary)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 1,
                maxClosedStaleness: 1,
                maxDeviationBps: 1,
                maxDriftBps: 1,
                configured: false
            })
        );
    }

    function test_onlyKeeperSetsStatus() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setMarketStatus(asset, false);
    }

    function test_invalidConfigReverts() public {
        vm.prank(admin);
        vm.expectRevert(NAVOracle.InvalidConfig.selector);
        oracle.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(0)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 1,
                maxClosedStaleness: 1,
                maxDeviationBps: 1,
                maxDriftBps: 1,
                configured: false
            })
        );
    }

    function testFuzz_driftNeverEscapesBound(int256 drift) public {
        drift = bound(drift, -1e9, 1e9);
        vm.startPrank(keeper);
        oracle.setMarketStatus(asset, false);
        oracle.setImpliedDrift(asset, drift);
        vm.stopPrank();

        INAVOracle.PriceData memory d = oracle.getPriceData(asset);
        // base 100e18, bound 10% => [90e18, 110e18]
        assertLe(d.price, 110e18);
        assertGe(d.price, 90e18);
    }
}
