// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IOracleAdapter
/// @notice Normalizes an external price source (Chainlink, DEX TWAP, mock) into an 18-decimal feed.
/// @dev One adapter instance wraps one price source for one asset. The NAVOracle composes adapters.
interface IOracleAdapter {
    /// @notice Latest price from the underlying source, already scaled to 18 decimals.
    /// @return price 18-decimal USD price.
    /// @return updatedAt Unix timestamp the source last updated.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}
