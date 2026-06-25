// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PortfolioBase } from "./PortfolioBase.sol";
import { IWeightStrategy } from "../interfaces/IWeightStrategy.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IndexPortfolio
/// @notice Rules-based portfolio that rebalances toward a pluggable IWeightStrategy's target weights.
/// @dev A REBALANCER (keeper) trades toward target within a tolerance band and a max-trade-size cap per
///      call, so a single rebalance can never churn the whole book. Sells overweight to quote, then
///      buys underweight from that quote. Every traded asset is gated on the depeg circuit-breaker.
contract IndexPortfolio is PortfolioBase {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to trigger rebalances.
    bytes32 public constant REBALANCER = keccak256("REBALANCER");

    /// @notice Target-weight provider.
    IWeightStrategy public strategy;
    /// @notice No-trade band: skip assets within this bps of target.
    uint16 public toleranceBps;
    /// @notice Max value (bps of NAV) that may be sold from any single asset per rebalance.
    uint16 public maxTradeBps;

    /// @notice Emitted after a rebalance completes.
    event Rebalanced(uint256 navBefore, uint256 navAfter);
    /// @notice Emitted when the strategy is changed.
    event StrategySet(address strategy);

    error InvalidParams();

    /// @notice Initialize a cloned IndexPortfolio.
    /// @param p Base init params.
    /// @param strategy_ Weight strategy.
    /// @param toleranceBps_ No-trade band (bps).
    /// @param maxTradeBps_ Per-asset max sell per rebalance (bps of NAV).
    function initialize(InitParams calldata p, address strategy_, uint16 toleranceBps_, uint16 maxTradeBps_)
        external
        initializer
    {
        if (strategy_ == address(0) || maxTradeBps_ == 0 || maxTradeBps_ > BPS) revert InvalidParams();
        __PortfolioBase_init(p);
        strategy = IWeightStrategy(strategy_);
        toleranceBps = toleranceBps_;
        maxTradeBps = maxTradeBps_;
        _grantRole(REBALANCER, p.admin);
    }

    /// @notice Update the weight strategy.
    /// @dev SECURITY: PORTFOLIO_ADMIN only.
    function setStrategy(address strategy_) external onlyRole(PORTFOLIO_ADMIN) {
        if (strategy_ == address(0)) revert InvalidParams();
        strategy = IWeightStrategy(strategy_);
        emit StrategySet(strategy_);
    }

    /// @notice Update rebalance guardrails.
    /// @dev SECURITY: PORTFOLIO_ADMIN only.
    function setRebalanceParams(uint16 toleranceBps_, uint16 maxTradeBps_) external onlyRole(PORTFOLIO_ADMIN) {
        if (maxTradeBps_ == 0 || maxTradeBps_ > BPS) revert InvalidParams();
        toleranceBps = toleranceBps_;
        maxTradeBps = maxTradeBps_;
    }

    /// @notice Trade the book toward the strategy's target weights.
    /// @dev SECURITY: REBALANCER + nonReentrant. Bounded turnover (maxTradeBps per asset) and tolerance
    ///      band prevent griefing/churn. All swaps slippage- and deadline-bounded and depeg-gated.
    /// @param deadline Unix deadline for the underlying swaps.
    function rebalance(uint256 deadline) external nonReentrant onlyRole(REBALANCER) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        uint256 len = _components.length;

        address[] memory assets = new address[](len);
        for (uint256 i; i < len; ++i) {
            assets[i] = _components[i].asset;
        }
        uint256[] memory targets = strategy.targetWeights(assets);

        uint256 navBefore = totalNAV();
        if (navBefore == 0) revert ZeroAmount();

        // Phase 1: sell overweight assets into quote.
        uint256[] memory deficitValue = new uint256[](len);
        uint256 totalDeficit;
        for (uint256 i; i < len; ++i) {
            address asset = assets[i];
            uint256 current = _assetValue(asset);
            uint256 target = (navBefore * targets[i]) / BPS;
            uint256 band = (target * toleranceBps) / BPS;

            if (current > target + band) {
                uint256 excess = current - target;
                uint256 cap = (navBefore * maxTradeBps) / BPS;
                if (excess > cap) excess = cap;
                _sellValue(asset, excess, deadline);
            } else if (current + band < target) {
                deficitValue[i] = target - current;
                totalDeficit += deficitValue[i];
            }
        }

        // Phase 2: deploy realized quote into underweight assets pro-rata to deficit.
        uint256 quoteAvail = quote.balanceOf(address(this));
        if (totalDeficit > 0 && quoteAvail > 0) {
            for (uint256 i; i < len; ++i) {
                if (deficitValue[i] == 0) continue;
                uint256 portion = (quoteAvail * deficitValue[i]) / totalDeficit;
                if (portion == 0) continue;
                address asset = assets[i];
                if (!depeg.isTradingSafe(asset)) revert TradingUnsafe(asset);
                uint256 expected = router.quote(address(quote), asset, portion);
                uint256 minOut = (expected * (BPS - maxSlippageBps)) / BPS;
                quote.forceApprove(address(router), portion);
                router.swapExactIn(address(quote), asset, portion, minOut, deadline, address(this));
            }
        }

        emit Rebalanced(navBefore, totalNAV());
    }

    /// @dev Sell `valueUsd` worth of `asset` into the quote token.
    function _sellValue(address asset, uint256 valueUsd, uint256 deadline) internal {
        if (valueUsd == 0) return;
        if (!depeg.isTradingSafe(asset)) revert TradingUnsafe(asset);
        (uint256 price,, bool stale) = nav.getPrice(asset);
        if (stale || price == 0) revert PriceUnusable(asset);
        uint8 dec = IERC20Metadata(asset).decimals();
        uint256 amountIn = (valueUsd * (10 ** dec)) / price;
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (amountIn > bal) amountIn = bal;
        if (amountIn == 0) return;

        uint256 expected = router.quote(asset, address(quote), amountIn);
        uint256 minOut = (expected * (BPS - maxSlippageBps)) / BPS;
        IERC20(asset).forceApprove(address(router), amountIn);
        router.swapExactIn(asset, address(quote), amountIn, minOut, deadline, address(this));
    }
}
