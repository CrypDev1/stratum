// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { VenusOracleAdapter } from "../../src/oracle/VenusOracleAdapter.sol";
import { IVenusOracle } from "../../src/interfaces/external/IVenusOracle.sol";

/// @dev Settable stand-in for Venus's ResilientOracle: returns a price, zero, or reverts (its stale path).
contract MockVenusOracle is IVenusOracle {
    uint256 public price;
    bool public shouldRevert;

    function set(uint256 p, bool rev) external {
        price = p;
        shouldRevert = rev;
    }

    function getPrice(address) external view returns (uint256) {
        require(!shouldRevert, "chainlink price expired");
        return price;
    }
}

contract VenusOracleAdapterTest is Test {
    MockVenusOracle internal venus;
    VenusOracleAdapter internal adapter;
    address internal asset = address(0xB57C);

    function setUp() public {
        vm.warp(1_782_900_000);
        venus = new MockVenusOracle();
        adapter = new VenusOracleAdapter(IVenusOracle(address(venus)), asset);
    }

    function test_freshPriceStampedNow() public {
        venus.set(195e18, false);
        (uint256 p, uint256 ts) = adapter.latestPrice();
        assertEq(p, 195e18, "passes Venus price through");
        assertEq(ts, block.timestamp, "stamped now on success");
    }

    function test_venusRevertReturnsZero() public {
        venus.set(195e18, true); // Venus reverts (stale/invalid)
        (uint256 p, uint256 ts) = adapter.latestPrice();
        assertEq(p, 0, "revert -> price 0 (NAVOracle will flag stale)");
        assertEq(ts, 0, "revert -> updatedAt 0");
    }

    function test_zeroPriceReturnsZero() public {
        venus.set(0, false);
        (uint256 p, uint256 ts) = adapter.latestPrice();
        assertEq(p, 0);
        assertEq(ts, 0);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(VenusOracleAdapter.ZeroAddress.selector);
        new VenusOracleAdapter(IVenusOracle(address(0)), asset);
        vm.expectRevert(VenusOracleAdapter.ZeroAddress.selector);
        new VenusOracleAdapter(IVenusOracle(address(venus)), address(0));
    }
}
