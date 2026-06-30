// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPancakeV3SwapRouter
/// @notice Minimal PancakeSwap V3 SwapRouter surface used by the swap adapter.
/// @dev PancakeSwap's V3 SwapRouter keeps `deadline` inside the params struct (unlike Uniswap's
///      SwapRouter02 which removed it). Single-hop exact-input is sufficient for the adapter.
interface IPancakeV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another single pool.
    /// @param params The swap parameters (tokens, fee tier, recipient, deadline, bounds).
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
