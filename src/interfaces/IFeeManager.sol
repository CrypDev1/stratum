// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IFeeManager
/// @notice Computes streaming (management), performance (high-water-mark) and protocol fees.
/// @dev Stateless-per-call accounting helper: portfolios store the fee state and call in to compute
///      newly-owed fees, then mint the corresponding shares to recipients.
interface IFeeManager {
    /// @notice Fee configuration for a portfolio.
    struct FeeConfig {
        uint16 managementFeeBps; // annualized streaming fee
        uint16 performanceFeeBps; // on profit above high-water mark
        uint16 protocolCutBps; // protocol's share of all fees
        address manager; // receives manager portion
        address protocol; // receives protocol portion
    }

    /// @notice Compute management fee shares owed since `lastAccrual`.
    /// @param totalShares Current share supply.
    /// @param managementFeeBps Annualized management fee.
    /// @param elapsed Seconds since last accrual.
    /// @return feeShares Shares to mint as the management fee.
    function managementFeeShares(uint256 totalShares, uint256 managementFeeBps, uint256 elapsed)
        external
        pure
        returns (uint256 feeShares);

    /// @notice Compute performance fee shares owed when NAV/share exceeds the high-water mark.
    /// @param totalShares Current share supply.
    /// @param navPerShareNow Current NAV per share (18-dec).
    /// @param highWaterMark Previous high-water NAV per share (18-dec).
    /// @param performanceFeeBps Performance fee on profit.
    /// @return feeShares Shares to mint as the performance fee.
    function performanceFeeShares(
        uint256 totalShares,
        uint256 navPerShareNow,
        uint256 highWaterMark,
        uint256 performanceFeeBps
    ) external pure returns (uint256 feeShares);
}
