// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISwapRouter
/// @notice Adapter over a DEX (PancakeSwap on BNB Chain) used by portfolios to rebalance/allocate.
/// @dev SECURITY: every swap carries explicit slippage (`minAmountOut`) and `deadline` params.
interface ISwapRouter {
    /// @notice Swap an exact `amountIn` of `tokenIn` for at least `minAmountOut` of `tokenOut`.
    /// @param tokenIn Input token.
    /// @param tokenOut Output token.
    /// @param amountIn Exact input amount (pulled from msg.sender).
    /// @param minAmountOut Minimum acceptable output (slippage bound).
    /// @param deadline Unix timestamp after which the swap reverts.
    /// @param to Recipient of the output.
    /// @return amountOut Amount of `tokenOut` sent to `to`.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address to
    ) external returns (uint256 amountOut);

    /// @notice Quote the output of a swap without executing it.
    /// @param tokenIn Input token.
    /// @param tokenOut Output token.
    /// @param amountIn Input amount.
    /// @return amountOut Expected output amount.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
