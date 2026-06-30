// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PancakeV3SwapAdapter } from "../../src/periphery/PancakeV3SwapAdapter.sol";
import { MockPancakeV3Router } from "../../src/mocks/MockPancakeV3Router.sol";
import { MockPriceOracle } from "../../src/mocks/MockPriceOracle.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PancakeV3SwapAdapterTest is Test {
    MockPancakeV3Router internal router;
    MockPriceOracle internal oracle;
    PancakeV3SwapAdapter internal adapter;

    MockERC20 internal usdt;
    MockERC20 internal aapl;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA11);

    uint256 internal constant AAPL = 200e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new MockERC20("Tether", "USDT", 18);
        aapl = new MockERC20("bAAPL", "bAAPL", 18);

        router = new MockPancakeV3Router();
        router.setPrice(address(usdt), 1e18);
        router.setPrice(address(aapl), AAPL);

        oracle = new MockPriceOracle();
        oracle.set(address(aapl), AAPL);

        adapter = new PancakeV3SwapAdapter(admin, address(router), address(oracle), address(usdt));
    }

    function test_quoteStableToAsset() public view {
        // 100 USDT @ $1 → 0.5 bAAPL @ $200.
        assertEq(adapter.quote(address(usdt), address(aapl), 100e18), 0.5e18);
    }

    function test_quoteAssetToStable() public view {
        // 1 bAAPL @ $200 → 200 USDT.
        assertEq(adapter.quote(address(aapl), address(usdt), 1e18), 200e18);
    }

    function test_swapRoutesThroughRouter() public {
        uint256 amountIn = 100e18;
        uint256 expected = adapter.quote(address(usdt), address(aapl), amountIn);
        uint256 minOut = (expected * 99) / 100;

        usdt.mint(alice, amountIn);
        vm.startPrank(alice);
        usdt.approve(address(adapter), amountIn);
        uint256 out = adapter.swapExactIn(
            address(usdt), address(aapl), amountIn, minOut, block.timestamp + 1, alice
        );
        vm.stopPrank();

        assertEq(out, expected, "out at parity");
        assertEq(aapl.balanceOf(alice), expected, "recipient funded");
        assertEq(usdt.balanceOf(alice), 0, "input pulled");
    }

    function test_swapHonorsSlippageFromRouter() public {
        router.setSlippageBps(200); // 2% execution slippage
        uint256 amountIn = 100e18;
        uint256 expected = adapter.quote(address(usdt), address(aapl), amountIn);

        usdt.mint(alice, amountIn);
        vm.startPrank(alice);
        usdt.approve(address(adapter), amountIn);
        // minOut equal to full fair value should revert (router only returns 98%).
        vm.expectRevert();
        adapter.swapExactIn(address(usdt), address(aapl), amountIn, expected, block.timestamp + 1, alice);
        vm.stopPrank();
    }

    function test_swapRevertsAfterDeadline() public {
        usdt.mint(alice, 1e18);
        vm.startPrank(alice);
        usdt.approve(address(adapter), 1e18);
        vm.expectRevert(PancakeV3SwapAdapter.Expired.selector);
        adapter.swapExactIn(address(usdt), address(aapl), 1e18, 0, block.timestamp - 1, alice);
        vm.stopPrank();
    }

    function test_quoteRevertsOnUnknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PancakeV3SwapAdapter.NoPrice.selector, address(0xdead)));
        adapter.quote(address(usdt), address(0xdead), 1e18);
    }

    function test_feeTierOverride() public {
        assertEq(adapter.poolFee(address(usdt), address(aapl)), 2500, "default");
        vm.prank(admin);
        adapter.setPoolFee(address(usdt), address(aapl), 500);
        assertEq(adapter.poolFee(address(usdt), address(aapl)), 500, "override");
        assertEq(adapter.poolFee(address(aapl), address(usdt)), 500, "both directions");
    }

    function test_setFeeRequiresRole() public {
        vm.expectRevert();
        adapter.setDefaultFee(100);
    }
}
