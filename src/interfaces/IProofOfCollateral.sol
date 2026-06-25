// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IProofOfCollateral
/// @notice Tracks periodic attestations that a tokenized equity is fully backed by real shares.
/// @dev Higher layers MUST gate inclusion of an asset on `isHealthy`.
interface IProofOfCollateral {
    /// @notice An on-chain record of an off-chain backing attestation.
    struct Attestation {
        uint256 backingRatioBps; // 10_000 = 100% backed
        uint256 timestamp; // when the attestation was produced
        bytes32 sourceHash; // hash of the off-chain proof document
    }

    /// @notice Whether `asset` is sufficiently backed and the attestation is fresh.
    /// @param asset Token to check.
    /// @return healthy True if backing >= threshold AND attestation age <= max.
    function isHealthy(address asset) external view returns (bool healthy);

    /// @notice Latest backing ratio for `asset` in basis points.
    /// @param asset Token to query.
    /// @return ratioBps Backing ratio (10_000 = 100%).
    function collateralRatio(address asset) external view returns (uint256 ratioBps);
}
