// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IWeightStrategy
/// @notice Pluggable target-weight provider for index portfolios.
/// @dev Returned weights are basis points and MUST sum to 10_000 for the supplied asset set.
interface IWeightStrategy {
    /// @notice Target weights (bps) for `assets`, in the same order.
    /// @param assets The portfolio's component assets.
    /// @return weightsBps Target weight per asset; sums to 10_000.
    function targetWeights(address[] calldata assets) external view returns (uint256[] memory weightsBps);
}
