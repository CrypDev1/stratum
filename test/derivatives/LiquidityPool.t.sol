// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { LiquidityPool } from "../../src/derivatives/LiquidityPool.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityPoolTest is Test {
    LiquidityPool internal pool;
    MockERC20 internal usdc;
    address internal admin = address(this);
    address internal engine = address(0xE19E);
    address internal lp = address(0x11D);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        pool = new LiquidityPool(admin, IERC20(address(usdc)));
        pool.setEngine(engine);
        usdc.mint(lp, 1_000e18);
        vm.prank(lp);
        usdc.approve(address(pool), type(uint256).max);
    }

    function test_depositMintsShares() public {
        vm.prank(lp);
        uint256 shares = pool.deposit(1_000e18);
        assertEq(shares, 1_000e18);
        assertEq(pool.totalAssets(), 1_000e18);
    }

    function test_shareValueRisesWithProfit() public {
        vm.prank(lp);
        pool.deposit(1_000e18);
        // simulate trader loss arriving as a transfer into the pool
        usdc.mint(address(pool), 100e18);
        // withdraw all shares -> get 1100
        uint256 lpShares = pool.balanceOf(lp);
        vm.prank(lp);
        uint256 assets = pool.withdraw(lpShares);
        assertEq(assets, 1_100e18);
    }

    function test_onlyEnginePaysOut() public {
        vm.prank(lp);
        pool.deposit(1_000e18);
        vm.prank(address(0xBAD));
        vm.expectRevert(LiquidityPool.OnlyEngine.selector);
        pool.payOut(address(0xBAD), 1e18);
    }

    function test_engineCanPayOut() public {
        vm.prank(lp);
        pool.deposit(1_000e18);
        vm.prank(engine);
        pool.payOut(address(0x123), 100e18);
        assertEq(usdc.balanceOf(address(0x123)), 100e18);
    }

    function test_engineSetOnce() public {
        vm.expectRevert(LiquidityPool.EngineAlreadySet.selector);
        pool.setEngine(address(0x999));
    }
}
