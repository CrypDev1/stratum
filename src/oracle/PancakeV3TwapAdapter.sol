// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { IPancakeV3Pool } from "../interfaces/external/IPancakeV3Pool.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { PriceLib } from "../libraries/PriceLib.sol";
import { TwapMath } from "../libraries/TwapMath.sol";

/// @title PancakeV3TwapAdapter
/// @notice Derives a bStock's USD price from its bStock/USDT PancakeSwap V3 pool via a configurable-window
///         TWAP, normalized to 18 decimals.
/// @dev Implements `IOracleAdapter`, the source interface the NAVOracle and DepegMonitor consume (one
///      adapter wraps one pool for one asset). SECURITY: defensive by construction — returns
///      `(0, 0)` (which upstream treats as stale/unsafe) on zero in-range liquidity or when the pool lacks
///      observations spanning the window, rather than reverting, so the `isTradingSafe`/`getPrice` gates
///      stay non-reverting. The quote token is treated as the USD numéraire (USDT/USDC ≈ $1 on BNB).
contract PancakeV3TwapAdapter is IOracleAdapter {
    using PriceLib for uint256;

    /// @notice The PancakeSwap V3 pool (bStock/USDT) this adapter reads.
    IPancakeV3Pool public immutable pool;
    /// @notice The asset being priced (the bStock).
    address public immutable baseToken;
    /// @notice The USD numéraire token (the pool's other side, e.g. USDT).
    address public immutable quoteToken;
    /// @notice Decimals of the base token (for the 1-unit quote amount).
    uint8 public immutable baseDecimals;
    /// @notice Decimals of the quote token (to scale the result to 18 decimals).
    uint8 public immutable quoteDecimals;
    /// @notice TWAP averaging window in seconds.
    uint32 public immutable window;

    error InvalidWindow();
    error TokenNotInPool();

    /// @param pool_ The bStock/USDT PancakeSwap V3 pool.
    /// @param baseToken_ The bStock token (must be one side of the pool).
    /// @param window_ TWAP window in seconds (e.g. 1800 for 30 minutes). Must be > 0.
    constructor(address pool_, address baseToken_, uint32 window_) {
        if (window_ == 0) revert InvalidWindow();
        IPancakeV3Pool p = IPancakeV3Pool(pool_);
        address t0 = p.token0();
        address t1 = p.token1();
        if (baseToken_ != t0 && baseToken_ != t1) revert TokenNotInPool();

        pool = p;
        baseToken = baseToken_;
        quoteToken = baseToken_ == t0 ? t1 : t0;
        baseDecimals = IERC20Metadata(baseToken_).decimals();
        quoteDecimals = IERC20Metadata(quoteToken).decimals();
        window = window_;
    }

    /// @inheritdoc IOracleAdapter
    /// @dev SECURITY: view-only. Guards: (1) zero in-range liquidity ⇒ `(0,0)`; (2) `observe` reverting
    ///      because the window predates the oldest observation ⇒ `(0,0)` (caught). The TWAP endpoint is the
    ///      current block, so a healthy read stamps `updatedAt = block.timestamp` (never stale by age).
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        if (pool.liquidity() == 0) return (0, 0);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window; // start of window
        secondsAgos[1] = 0; // now

        try pool.observe(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory /* secondsPerLiquidity */
        ) {
            int24 tick = TwapMath.meanTick(tickCumulatives[0], tickCumulatives[1], window);
            // Quote 1 whole base token into quote-token units, then normalize to 18 decimals.
            uint256 q = TwapMath.getQuoteAtTick(tick, 10 ** uint256(baseDecimals), baseToken, quoteToken);
            price = q.scaleTo18(quoteDecimals);
            updatedAt = block.timestamp;
        } catch {
            return (0, 0);
        }
    }
}
