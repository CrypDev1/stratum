// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPriceOracle
/// @notice Minimal price interface consumed by every higher Stratum layer.
/// @dev Prices are 18-decimal USD. Consumers MUST honour `isStale` and refuse to act on stale data.
interface IPriceOracle {
    /// @notice Returns the current fair-value USD price of `asset`.
    /// @param asset The token whose price is requested.
    /// @return price 18-decimal USD price.
    /// @return updatedAt Unix timestamp the price reflects.
    /// @return isStale True if the price breaches the staleness/deviation guards and must not be trusted.
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt, bool isStale);
}
