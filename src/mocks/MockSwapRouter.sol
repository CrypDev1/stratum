// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ISwapRouter } from "../interfaces/ISwapRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @title MockSwapRouter
/// @notice Test DEX router that swaps at oracle-parity USD prices (no spread), minting the output.
/// @dev TODO(integration): replace with a PancakeSwap V2/V3 adapter on BNB Chain. Prices are settable
///      per token (18-dec USD) and should mirror the NAVOracle adapters in tests so accounting is exact.
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public priceUsd18; // token => 18-dec USD price
    uint256 public slippageBps; // simulated execution slippage applied to output

    error NoPrice(address token);
    error Expired();
    error InsufficientOut();

    /// @notice Set the USD price (18-dec) used to value `token` in swaps.
    function setPrice(address token, uint256 price18) external {
        priceUsd18[token] = price18;
    }

    /// @notice Simulate execution slippage (bps) applied to every swap output.
    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    /// @inheritdoc ISwapRouter
    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 amountOut) {
        uint256 pIn = priceUsd18[tokenIn];
        uint256 pOut = priceUsd18[tokenOut];
        if (pIn == 0) revert NoPrice(tokenIn);
        if (pOut == 0) revert NoPrice(tokenOut);
        uint8 decIn = IERC20Metadata(tokenIn).decimals();
        uint8 decOut = IERC20Metadata(tokenOut).decimals();
        uint256 valueUsd = (amountIn * pIn) / (10 ** decIn); // 18-dec USD
        amountOut = (valueUsd * (10 ** decOut)) / pOut;
        amountOut = (amountOut * (10_000 - slippageBps)) / 10_000;
    }

    /// @inheritdoc ISwapRouter
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address to
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        amountOut = quote(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOut();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Mint output (mock has infinite liquidity).
        MockERC20(tokenOut).mint(to, amountOut);
    }
}
