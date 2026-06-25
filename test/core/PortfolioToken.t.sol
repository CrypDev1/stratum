// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";

contract PortfolioTokenTest is Test {
    PortfolioToken internal token;
    address internal manager = address(this);

    function setUp() public {
        token = new PortfolioToken("Share", "SHR", manager);
    }

    function test_managerCanMintBurn() public {
        token.mint(address(0xA11), 100e18);
        assertEq(token.balanceOf(address(0xA11)), 100e18);
        token.burn(address(0xA11), 40e18);
        assertEq(token.balanceOf(address(0xA11)), 60e18);
    }

    function test_nonManagerCannotMint() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(PortfolioToken.OnlyManager.selector);
        token.mint(address(0xBEEF), 1e18);
    }

    function test_nonManagerCannotBurn() public {
        token.mint(address(0xA11), 100e18);
        vm.prank(address(0xBEEF));
        vm.expectRevert(PortfolioToken.OnlyManager.selector);
        token.burn(address(0xA11), 1e18);
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }
}
