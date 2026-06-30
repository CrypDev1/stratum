// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PancakeV3TwapAdapter } from "../../src/oracle/PancakeV3TwapAdapter.sol";
import { MockPancakeV3Pool } from "../../src/mocks/MockPancakeV3Pool.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract PancakeV3TwapAdapterTest is Test {
    MockERC20 internal bstock;
    MockERC20 internal usdt;
    address internal token0; // lower-sorted (used as base so price = 1.0001^tick)
    address internal token1;

    uint32 internal constant WINDOW = 1800;

    function setUp() public {
        vm.warp(1_700_000_000);
        bstock = new MockERC20("bAAPL", "bAAPL", 18);
        usdt = new MockERC20("Tether", "USDT", 18);
        (token0, token1) = address(bstock) < address(usdt)
            ? (address(bstock), address(usdt))
            : (address(usdt), address(bstock));
    }

    function _adapter(int24 tick, uint128 liquidity, address base) internal returns (PancakeV3TwapAdapter a) {
        MockPancakeV3Pool pool = new MockPancakeV3Pool(token0, token1, tick, liquidity);
        a = new PancakeV3TwapAdapter(address(pool), base, WINDOW);
    }

    function test_priceIsOneAtTickZero() public {
        PancakeV3TwapAdapter a = _adapter(0, 1e18, token0);
        (uint256 price, uint256 updatedAt) = a.latestPrice();
        assertEq(price, 1e18, "1:1 at tick 0");
        assertEq(updatedAt, block.timestamp, "stamped now");
    }

    function test_baseIsToken0_positiveTickPricesAbovePar() public {
        // tick 10000 => 1.0001^10000 ≈ 2.71815 (e^~1).
        PancakeV3TwapAdapter a = _adapter(10_000, 1e18, token0);
        (uint256 price,) = a.latestPrice();
        assertApproxEqRel(price, 2.71815e18, 0.005e18, "~e at tick 10000");
    }

    function test_baseIsToken0_negativeTickPricesBelowPar() public {
        PancakeV3TwapAdapter a = _adapter(-10_000, 1e18, token0);
        (uint256 price,) = a.latestPrice();
        // 1/2.71815 ≈ 0.36788.
        assertApproxEqRel(price, 0.36788e18, 0.005e18, "~1/e at tick -10000");
    }

    function test_inversionWhenBaseIsToken1() public {
        // Same tick, but pricing the higher-sorted token: price should be the reciprocal.
        PancakeV3TwapAdapter a0 = _adapter(10_000, 1e18, token0);
        PancakeV3TwapAdapter a1 = _adapter(10_000, 1e18, token1);
        (uint256 p0,) = a0.latestPrice();
        (uint256 p1,) = a1.latestPrice();
        assertApproxEqRel((p0 * p1) / 1e18, 1e18, 0.001e18, "reciprocal prices multiply to ~1");
    }

    function test_zeroLiquidityReturnsZero() public {
        PancakeV3TwapAdapter a = _adapter(10_000, 0, token0);
        (uint256 price, uint256 updatedAt) = a.latestPrice();
        assertEq(price, 0, "zero on no liquidity");
        assertEq(updatedAt, 0, "no timestamp");
    }

    function test_staleObservationsReturnZero() public {
        MockPancakeV3Pool pool = new MockPancakeV3Pool(token0, token1, 10_000, 1e18);
        PancakeV3TwapAdapter a = new PancakeV3TwapAdapter(address(pool), token0, WINDOW);
        pool.setObserveReverts(true); // simulate OLD (window predates oldest observation)
        (uint256 price, uint256 updatedAt) = a.latestPrice();
        assertEq(price, 0, "zero when observe reverts");
        assertEq(updatedAt, 0, "no timestamp");
    }

    function test_constructorRejectsZeroWindow() public {
        MockPancakeV3Pool pool = new MockPancakeV3Pool(token0, token1, 0, 1e18);
        vm.expectRevert(PancakeV3TwapAdapter.InvalidWindow.selector);
        new PancakeV3TwapAdapter(address(pool), token0, 0);
    }

    function test_constructorRejectsTokenNotInPool() public {
        MockPancakeV3Pool pool = new MockPancakeV3Pool(token0, token1, 0, 1e18);
        vm.expectRevert(PancakeV3TwapAdapter.TokenNotInPool.selector);
        new PancakeV3TwapAdapter(address(pool), address(0xdead), WINDOW);
    }

    function test_quoteTokenAssignment() public {
        PancakeV3TwapAdapter a = _adapter(0, 1e18, token0);
        assertEq(a.baseToken(), token0);
        assertEq(a.quoteToken(), token1);
    }
}
