// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPancakeV3Pool
/// @notice Minimal PancakeSwap V3 pool surface used by the TWAP oracle adapter.
/// @dev PancakeSwap V3 shares Uniswap V3's pool oracle semantics: `observe` returns cumulative ticks
///      that, differenced over a window and divided by it, yield the time-weighted average tick.
interface IPancakeV3Pool {
    /// @notice token0 of the pool (the lower-sorted address).
    function token0() external view returns (address);

    /// @notice token1 of the pool (the higher-sorted address).
    function token1() external view returns (address);

    /// @notice The pool's fee tier in hundredths of a bip (e.g. 2500 = 0.25%).
    function fee() external view returns (uint24);

    /// @notice In-range liquidity currently available.
    function liquidity() external view returns (uint128);

    /// @notice Current slot0 (only the fields the adapter needs).
    /// @return sqrtPriceX96 Current sqrt price as a Q64.96.
    /// @return tick Current tick.
    /// @return observationIndex Index of the last written observation.
    /// @return observationCardinality Number of populated observations.
    /// @return observationCardinalityNext Next cardinality (post-grow).
    /// @return feeProtocol Protocol fee config.
    /// @return unlocked Whether the pool is unlocked.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice Returns cumulative tick and liquidity values as of each `secondsAgos[i]`.
    /// @dev Reverts with `OLD` if the requested window predates the oldest stored observation.
    /// @param secondsAgos From how long ago each cumulative value should be returned.
    /// @return tickCumulatives Cumulative tick values.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds-per-liquidity values.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
