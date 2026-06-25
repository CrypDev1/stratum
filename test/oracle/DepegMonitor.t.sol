// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NAVOracle } from "../../src/oracle/NAVOracle.sol";
import { DepegMonitor } from "../../src/oracle/DepegMonitor.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../../src/interfaces/IOracleAdapter.sol";
import { MockOracleAdapter } from "../../src/mocks/MockOracleAdapter.sol";

contract DepegMonitorTest is Test {
    NAVOracle internal nav;
    DepegMonitor internal monitor;
    MockOracleAdapter internal primary;
    MockOracleAdapter internal dex;

    address internal admin = address(0xA11CE);
    address internal asset = address(0xBEEF);
    address internal guardian = address(0x6A47D);

    function setUp() public {
        vm.warp(1_700_000_000);
        nav = new NAVOracle(admin);
        primary = new MockOracleAdapter(100e18, block.timestamp);
        dex = new MockOracleAdapter(100e18, block.timestamp);

        vm.startPrank(admin);
        nav.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(primary)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 3600,
                maxClosedStaleness: 4 days,
                maxDeviationBps: 200,
                maxDriftBps: 1000,
                configured: false
            })
        );
        monitor = new DepegMonitor(admin, INAVOracle(address(nav)));
        monitor.setDexSource(asset, IOracleAdapter(address(dex)));
        monitor.grantRole(monitor.GUARDIAN(), guardian);
        vm.stopPrank();
    }

    function test_noDepegSafe() public view {
        assertEq(monitor.depegBps(asset), 0);
        assertTrue(monitor.isTradingSafe(asset));
    }

    function test_depegMeasured() public {
        dex.setPrice(103e18); // 3% vs fair 100
        assertEq(monitor.depegBps(asset), 300);
    }

    function test_depegBeyondThresholdUnsafe() public {
        dex.setPrice(106e18); // 6% > 5% default
        assertFalse(monitor.isTradingSafe(asset));
    }

    function test_manualHaltUnsafe() public {
        vm.prank(guardian);
        monitor.setHalted(asset, true);
        assertFalse(monitor.isTradingSafe(asset));
    }

    function test_staleOracleUnsafe() public {
        skip(3601); // primary now stale
        assertFalse(monitor.isTradingSafe(asset));
    }

    function test_noDexSourceUnsafeNoRevert() public view {
        // an asset with no dex source configured
        assertFalse(monitor.isTradingSafe(address(0x9999)));
    }

    function test_depegBpsRevertsWithoutSource() public {
        vm.expectRevert(abi.encodeWithSelector(DepegMonitor.NoDexSource.selector, address(0x9999)));
        monitor.depegBps(address(0x9999));
    }

    function test_perAssetThresholdOverride() public {
        vm.prank(admin);
        monitor.setMaxDepegOverrideBps(asset, 200); // tighten to 2%
        dex.setPrice(103e18); // 3% > 2%
        assertFalse(monitor.isTradingSafe(asset));
    }

    function test_onlyGuardianHalts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        monitor.setHalted(asset, true);
    }

    function testFuzz_safetyThreshold(uint256 dexPrice) public {
        dexPrice = bound(dexPrice, 1e18, 200e18);
        dex.setPrice(dexPrice);
        uint256 dep = dexPrice > 100e18 ? dexPrice - 100e18 : 100e18 - dexPrice;
        dep = (dep * 10_000) / 100e18;
        assertEq(monitor.isTradingSafe(asset), dep <= 500);
    }
}
