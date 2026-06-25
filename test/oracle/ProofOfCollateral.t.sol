// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ProofOfCollateral } from "../../src/oracle/ProofOfCollateral.sol";

contract ProofOfCollateralTest is Test {
    ProofOfCollateral internal poc;
    address internal admin = address(0xA11CE);
    address internal asset = address(0xBEEF);
    address internal stranger = address(0xDEAD);

    event Attested(address indexed asset, uint256 backingRatioBps, uint256 timestamp, bytes32 sourceHash);
    event CollateralBreach(address indexed asset, uint256 backingRatioBps, uint256 thresholdBps);

    function setUp() public {
        vm.warp(1_700_000_000);
        poc = new ProofOfCollateral(admin);
    }

    function test_attestAndHealthy() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit Attested(asset, 10_000, block.timestamp, bytes32("proof"));
        poc.attest(asset, 10_000, bytes32("proof"));

        assertTrue(poc.isHealthy(asset));
        assertEq(poc.collateralRatio(asset), 10_000);
    }

    function test_breachEmitsAndUnhealthy() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit CollateralBreach(asset, 9_000, 9_900);
        poc.attest(asset, 9_000, bytes32("proof")); // below 99% default

        assertFalse(poc.isHealthy(asset));
    }

    function test_staleAttestationUnhealthy() public {
        vm.prank(admin);
        poc.attest(asset, 10_000, bytes32("proof"));
        skip(7 days + 1);
        assertFalse(poc.isHealthy(asset));
    }

    function test_neverAttestedUnhealthy() public view {
        assertFalse(poc.isHealthy(asset));
    }

    function test_perAssetThresholdOverride() public {
        vm.startPrank(admin);
        poc.setThresholdOverride(asset, 9_500); // 95%
        poc.attest(asset, 9_600, bytes32("proof"));
        vm.stopPrank();
        assertTrue(poc.isHealthy(asset)); // 96% >= 95%
    }

    function test_onlyAttestor() public {
        vm.prank(stranger);
        vm.expectRevert();
        poc.attest(asset, 10_000, bytes32("proof"));
    }

    function test_setParams() public {
        vm.prank(admin);
        poc.setParams(9_500, 1 days);
        assertEq(poc.globalThresholdBps(), 9_500);
        assertEq(poc.maxAttestationAge(), 1 days);
    }

    function test_setParamsRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(ProofOfCollateral.InvalidParam.selector);
        poc.setParams(0, 1 days);
    }

    function testFuzz_healthThreshold(uint256 ratio) public {
        ratio = bound(ratio, 0, 20_000);
        vm.prank(admin);
        poc.attest(asset, ratio, bytes32("p"));
        assertEq(poc.isHealthy(asset), ratio >= 9_900);
    }
}
