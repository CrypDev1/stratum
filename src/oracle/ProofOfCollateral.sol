// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IProofOfCollateral } from "../interfaces/IProofOfCollateral.sol";

/// @title ProofOfCollateral
/// @notice Stores periodic attestations that each tokenized equity is fully backed by real shares.
/// @dev Attestors (custodian/auditor keepers) post a backing ratio + source hash. Higher layers gate
///      asset inclusion on `isHealthy`. Emits on every update and on any breach of the health threshold.
contract ProofOfCollateral is IProofOfCollateral, AccessControl {
    /// @notice Role allowed to post attestations.
    bytes32 public constant ATTESTOR = keccak256("ATTESTOR");
    /// @notice Role allowed to tune thresholds and freshness windows.
    bytes32 public constant POC_ADMIN = keccak256("POC_ADMIN");

    /// @notice Default minimum healthy backing ratio (basis points) when no per-asset override is set.
    uint256 public globalThresholdBps = 9_900; // 99%
    /// @notice Maximum age (seconds) an attestation may have to count as fresh.
    uint256 public maxAttestationAge = 7 days;

    mapping(address asset => Attestation) private _attestations;
    mapping(address asset => uint256) private _thresholdOverrideBps; // 0 = use global

    /// @notice Emitted on every attestation update.
    event Attested(address indexed asset, uint256 backingRatioBps, uint256 timestamp, bytes32 sourceHash);
    /// @notice Emitted when a posted attestation is below the asset's threshold.
    event CollateralBreach(address indexed asset, uint256 backingRatioBps, uint256 thresholdBps);
    /// @notice Emitted when governance updates global params.
    event ParamsUpdated(uint256 globalThresholdBps, uint256 maxAttestationAge);
    /// @notice Emitted when a per-asset threshold override changes.
    event ThresholdOverrideSet(address indexed asset, uint256 thresholdBps);

    error InvalidParam();

    /// @param admin Address granted DEFAULT_ADMIN_ROLE, POC_ADMIN and ATTESTOR.
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POC_ADMIN, admin);
        _grantRole(ATTESTOR, admin);
    }

    /// @notice Post a fresh attestation for `asset`.
    /// @dev SECURITY: only ATTESTOR. Emits CollateralBreach (not revert) when below threshold so the
    ///      breach is recorded on-chain even as data continues to update; staleness is enforced on read.
    /// @param asset Token being attested.
    /// @param backingRatioBps Backing ratio in basis points (10_000 = 100%).
    /// @param sourceHash Hash of the off-chain proof document.
    function attest(address asset, uint256 backingRatioBps, bytes32 sourceHash) external onlyRole(ATTESTOR) {
        if (asset == address(0)) revert InvalidParam();
        _attestations[asset] =
            Attestation({ backingRatioBps: backingRatioBps, timestamp: block.timestamp, sourceHash: sourceHash });
        emit Attested(asset, backingRatioBps, block.timestamp, sourceHash);

        uint256 threshold = _threshold(asset);
        if (backingRatioBps < threshold) {
            emit CollateralBreach(asset, backingRatioBps, threshold);
        }
    }

    /// @notice Update global threshold and freshness window.
    /// @dev SECURITY: only POC_ADMIN. Threshold capped at 100% sanity bound is not enforced (over-
    ///      collateralization is valid); age must be non-zero so freshness is always enforced.
    function setParams(uint256 _globalThresholdBps, uint256 _maxAttestationAge) external onlyRole(POC_ADMIN) {
        if (_maxAttestationAge == 0 || _globalThresholdBps == 0) revert InvalidParam();
        globalThresholdBps = _globalThresholdBps;
        maxAttestationAge = _maxAttestationAge;
        emit ParamsUpdated(_globalThresholdBps, _maxAttestationAge);
    }

    /// @notice Set or clear a per-asset threshold override (0 clears, falling back to global).
    /// @dev SECURITY: only POC_ADMIN.
    function setThresholdOverride(address asset, uint256 thresholdBps) external onlyRole(POC_ADMIN) {
        _thresholdOverrideBps[asset] = thresholdBps;
        emit ThresholdOverrideSet(asset, thresholdBps);
    }

    /// @inheritdoc IProofOfCollateral
    function isHealthy(address asset) external view returns (bool healthy) {
        Attestation storage a = _attestations[asset];
        if (a.timestamp == 0) return false;
        bool fresh = block.timestamp <= a.timestamp + maxAttestationAge;
        return fresh && a.backingRatioBps >= _threshold(asset);
    }

    /// @inheritdoc IProofOfCollateral
    function collateralRatio(address asset) external view returns (uint256 ratioBps) {
        return _attestations[asset].backingRatioBps;
    }

    /// @notice Full attestation record for `asset`.
    function attestation(address asset) external view returns (Attestation memory) {
        return _attestations[asset];
    }

    /// @notice Effective health threshold for `asset` (override if set, else global).
    function thresholdOf(address asset) external view returns (uint256) {
        return _threshold(asset);
    }

    function _threshold(address asset) internal view returns (uint256) {
        uint256 o = _thresholdOverrideBps[asset];
        return o == 0 ? globalThresholdBps : o;
    }
}
