// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IDepegMonitor
/// @notice Circuit-breaker comparing DEX market price vs NAV fair value.
/// @dev Every mint/redeem/liquidation path in higher layers MUST consult `isTradingSafe`.
interface IDepegMonitor {
    /// @notice Absolute depeg between DEX price and NAV fair value, in basis points.
    /// @param asset Token to query.
    /// @return bps Depeg magnitude (100 = 1%).
    function depegBps(address asset) external view returns (uint256 bps);

    /// @notice Whether trading `asset` is currently safe.
    /// @dev False if manually halted, oracle stale, or depeg exceeds the configured threshold.
    /// @param asset Token to query.
    /// @return safe True if higher layers may mint/redeem/liquidate.
    function isTradingSafe(address asset) external view returns (bool safe);
}
