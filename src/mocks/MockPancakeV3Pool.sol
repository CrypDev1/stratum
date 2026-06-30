// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPancakeV3Pool } from "../interfaces/external/IPancakeV3Pool.sol";

/// @title MockPancakeV3Pool
/// @notice Test double for a PancakeSwap V3 pool oracle. Returns cumulative ticks consistent with a
///         settable constant TWAP tick, and can simulate zero liquidity or an `observe` revert (OLD).
/// @dev `observe` models cumulative(secondsAgo) = -tick · secondsAgo, so the mean tick over any window
///      equals `tick`. TODO(integration): real pools are read directly; this exists only for unit tests.
contract MockPancakeV3Pool is IPancakeV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public fee = 2500;

    int24 public tick;
    uint128 public liquidity;
    bool public observeReverts;

    error OLD();

    constructor(address token0_, address token1_, int24 tick_, uint128 liquidity_) {
        // V3 invariant: token0 < token1.
        (token0, token1) = token0_ < token1_ ? (token0_, token1_) : (token1_, token0_);
        tick = tick_;
        liquidity = liquidity_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function setObserveReverts(bool reverts_) external {
        observeReverts = reverts_;
    }

    function slot0()
        external
        view
        returns (uint160, int24 tick_, uint16, uint16, uint16, uint32, bool)
    {
        return (0, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeReverts) revert OLD();
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            // cumulative(secondsAgo) = -tick * secondsAgo  ⇒  mean over [a,b] = tick.
            tickCumulatives[i] = int56(tick) * -int56(int256(uint256(secondsAgos[i])));
        }
    }
}
