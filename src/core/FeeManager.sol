// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IFeeManager } from "../interfaces/IFeeManager.sol";

/// @title FeeManager
/// @notice Pure fee math: streaming management fee + high-water-mark performance fee.
/// @dev Stateless by design — portfolios own the fee state (last accrual, HWM) and mint the shares
///      this returns. Reused by L3 structured products for origination fees. Fees are paid via share
///      dilution: minting `feeShares` to recipients dilutes holders by exactly the fee fraction.
contract FeeManager is IFeeManager {
    /// @notice Seconds in a (365-day) year used to annualize the streaming fee.
    uint256 public constant YEAR = 365 days;
    /// @notice Basis-points denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Hard cap on management fee (20%/yr) to protect depositors.
    uint256 public constant MAX_MGMT_BPS = 2_000;
    /// @notice Hard cap on performance fee (50%).
    uint256 public constant MAX_PERF_BPS = 5_000;

    error FeeTooHigh();

    /// @inheritdoc IFeeManager
    /// @dev SECURITY: dilution-based. feeShares = totalShares * feeBps/BPS * elapsed/YEAR. The fee is
    ///      taken on the post-mint supply (target fee fraction `f`): to dilute holders by exactly `f`,
    ///      mint `f/(1-f) * totalShares`. Caps the rate to MAX_MGMT_BPS.
    function managementFeeShares(uint256 totalShares, uint256 managementFeeBps, uint256 elapsed)
        external
        pure
        returns (uint256 feeShares)
    {
        if (managementFeeBps > MAX_MGMT_BPS) revert FeeTooHigh();
        if (totalShares == 0 || managementFeeBps == 0 || elapsed == 0) return 0;
        // fee fraction numerator/denominator in (BPS*YEAR) units
        uint256 num = managementFeeBps * elapsed; // f = num / (BPS*YEAR)
        uint256 den = BPS * YEAR;
        if (num >= den) num = den - 1; // guard: never dilute >= 100%
        // feeShares = totalShares * num / (den - num)
        feeShares = (totalShares * num) / (den - num);
    }

    /// @inheritdoc IFeeManager
    /// @dev SECURITY: only charges on profit above the high-water mark. profitPerShare = navPS - HWM;
    ///      feeValueFraction f = profitPerShare/navPS * perfBps/BPS; mint f/(1-f)*totalShares (dilution).
    ///      Caps the rate to MAX_PERF_BPS. Returns 0 when at/below HWM.
    function performanceFeeShares(
        uint256 totalShares,
        uint256 navPerShareNow,
        uint256 highWaterMark,
        uint256 performanceFeeBps
    ) external pure returns (uint256 feeShares) {
        if (performanceFeeBps > MAX_PERF_BPS) revert FeeTooHigh();
        if (totalShares == 0 || navPerShareNow == 0 || navPerShareNow <= highWaterMark || performanceFeeBps == 0) {
            return 0;
        }
        uint256 profit = navPerShareNow - highWaterMark; // per-share profit (18-dec)
        // f = (profit / navPS) * (perfBps / BPS)
        uint256 num = profit * performanceFeeBps; // / (navPS * BPS)
        uint256 den = navPerShareNow * BPS;
        if (num >= den) num = den - 1;
        feeShares = (totalShares * num) / (den - num);
    }
}
