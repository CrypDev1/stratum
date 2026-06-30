// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPancakeV3SwapRouter } from "../interfaces/external/IPancakeV3SwapRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @title MockPancakeV3Router
/// @notice Test double for the PancakeSwap V3 SwapRouter: swaps at settable 18-dec USD prices (with an
///         optional execution-slippage haircut), minting the output (infinite liquidity).
/// @dev TODO(integration): the real router is used on testnet/mainnet; this exists only for unit tests.
contract MockPancakeV3Router is IPancakeV3SwapRouter {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public priceUsd18;
    uint256 public slippageBps;

    error NoPrice(address token);
    error Expired();
    error InsufficientOut();

    function setPrice(address token, uint256 price18) external {
        priceUsd18[token] = price18;
    }

    function setSlippageBps(uint256 bps) external {
        slippageBps = bps;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert Expired();
        uint256 pIn = priceUsd18[p.tokenIn];
        uint256 pOut = priceUsd18[p.tokenOut];
        if (pIn == 0) revert NoPrice(p.tokenIn);
        if (pOut == 0) revert NoPrice(p.tokenOut);

        uint8 decIn = IERC20Metadata(p.tokenIn).decimals();
        uint8 decOut = IERC20Metadata(p.tokenOut).decimals();
        uint256 valueUsd = (p.amountIn * pIn) / (10 ** decIn);
        amountOut = (valueUsd * (10 ** decOut)) / pOut;
        amountOut = (amountOut * (10_000 - slippageBps)) / 10_000;
        if (amountOut < p.amountOutMinimum) revert InsufficientOut();

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
