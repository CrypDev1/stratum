// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVenusOracle
/// @notice Minimal view surface of Venus's ResilientOracle used to price an asset.
/// @dev `getPrice` returns the asset's USD price scaled to 1e18 and reverts if no valid (fresh) price is
///      available from Venus's configured sources.
interface IVenusOracle {
    /// @param asset The underlying token to price.
    /// @return price USD price of one whole token, scaled to 1e18.
    function getPrice(address asset) external view returns (uint256 price);
}
