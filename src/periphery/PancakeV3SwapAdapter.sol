// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISwapRouter } from "../interfaces/ISwapRouter.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IPancakeV3SwapRouter } from "../interfaces/external/IPancakeV3SwapRouter.sol";

/// @title PancakeV3SwapAdapter
/// @notice Adapts PancakeSwap V3's SwapRouter to the protocol's `ISwapRouter`, so portfolio
///         mint/redeem/rebalance and leverage deleverage can swap on-chain.
/// @dev `quote` must be `view` (the ISwapRouter contract), but V3 quoters are state-mutating; so `quote`
///      values the swap off the live NAV oracle (the same fair value the protocol trades against), while
///      `swapExactIn` executes on-chain and is protected by the caller-supplied `minAmountOut` + `deadline`.
///      The stable token is treated as the $1 USD numéraire. Fee tiers are configurable per pair.
contract PancakeV3SwapAdapter is ISwapRouter, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to set fee tiers.
    bytes32 public constant ROUTER_ADMIN = keccak256("ROUTER_ADMIN");

    /// @notice The underlying PancakeSwap V3 SwapRouter.
    IPancakeV3SwapRouter public immutable router;
    /// @notice Live price oracle used to value swaps for `quote` (the NAVOracle).
    IPriceOracle public immutable oracle;
    /// @notice The USD numéraire token (USDT/USDC), priced at $1.
    address public immutable stable;

    /// @notice Default V3 fee tier (hundredths of a bip) when no per-pair override is set.
    uint24 public defaultFee = 2500; // 0.25%
    /// @notice Per-pair fee tier override (direction-independent).
    mapping(address => mapping(address => uint24)) public feeOverride;

    event DefaultFeeSet(uint24 fee);
    event PoolFeeSet(address indexed tokenA, address indexed tokenB, uint24 fee);

    error ZeroAddress();
    error NoPrice(address token);
    error Expired();
    error InsufficientOut();

    /// @param admin Router admin (fee-tier governance).
    /// @param router_ The PancakeSwap V3 SwapRouter.
    /// @param oracle_ The live NAV oracle (quote pricing).
    /// @param stable_ The USD numéraire token (USDT/USDC).
    constructor(address admin, address router_, address oracle_, address stable_) {
        if (router_ == address(0) || oracle_ == address(0) || stable_ == address(0)) revert ZeroAddress();
        router = IPancakeV3SwapRouter(router_);
        oracle = IPriceOracle(oracle_);
        stable = stable_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROUTER_ADMIN, admin);
    }

    /// @notice Set the default fee tier used when a pair has no override.
    /// @dev SECURITY: ROUTER_ADMIN only.
    function setDefaultFee(uint24 fee) external onlyRole(ROUTER_ADMIN) {
        defaultFee = fee;
        emit DefaultFeeSet(fee);
    }

    /// @notice Set the V3 fee tier for a token pair (applies to both directions).
    /// @dev SECURITY: ROUTER_ADMIN only.
    function setPoolFee(address tokenA, address tokenB, uint24 fee) external onlyRole(ROUTER_ADMIN) {
        feeOverride[tokenA][tokenB] = fee;
        feeOverride[tokenB][tokenA] = fee;
        emit PoolFeeSet(tokenA, tokenB, fee);
    }

    /// @notice Effective fee tier for a pair.
    function poolFee(address tokenIn, address tokenOut) public view returns (uint24) {
        uint24 f = feeOverride[tokenIn][tokenOut];
        return f == 0 ? defaultFee : f;
    }

    /// @inheritdoc ISwapRouter
    /// @dev Fair-value quote off the oracle: out = in · priceIn / priceOut, decimal-adjusted. View-only.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256 amountOut) {
        (uint256 pIn, uint8 decIn) = _usd(tokenIn);
        (uint256 pOut, uint8 decOut) = _usd(tokenOut);
        uint256 valueUsd = (amountIn * pIn) / (10 ** decIn); // 18-dec USD
        amountOut = (valueUsd * (10 ** decOut)) / pOut;
    }

    /// @inheritdoc ISwapRouter
    /// @dev SECURITY: pulls `amountIn`, approves the V3 router, and executes a single-pool exact-input swap
    ///      with the caller's `minAmountOut`/`deadline` enforced on-chain by the router. CEI: external pull,
    ///      approve, swap; no callbacks into this adapter.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address to
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee(tokenIn, tokenOut),
                recipient: to,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut < minAmountOut) revert InsufficientOut();
    }

    /// @dev USD price (18-dec) and decimals of `token`. The stable is the $1 numéraire; everything else is
    ///      priced off the live oracle and must be non-zero (a configured, fresh-enough asset).
    function _usd(address token) internal view returns (uint256 price18, uint8 decimals) {
        if (token == stable) return (1e18, IERC20Metadata(stable).decimals());
        (uint256 p,,) = oracle.getPrice(token);
        if (p == 0) revert NoPrice(token);
        return (p, IERC20Metadata(token).decimals());
    }
}
