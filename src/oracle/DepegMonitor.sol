// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { PriceLib } from "../libraries/PriceLib.sol";

/// @title DepegMonitor
/// @notice Circuit breaker: compares each asset's DEX market price to NAV fair value.
/// @dev `isTradingSafe` is the single gate higher layers consult before minting/redeeming/liquidating.
///      Returns false when manually halted, the NAV oracle is stale, no DEX source exists, or the
///      depeg exceeds the configured threshold.
contract DepegMonitor is IDepegMonitor, AccessControl {
    using PriceLib for uint256;

    /// @notice Role allowed to wire DEX sources and thresholds.
    bytes32 public constant DEPEG_ADMIN = keccak256("DEPEG_ADMIN");
    /// @notice Role allowed to trip / reset the manual circuit breaker.
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    /// @notice NAV fair-value oracle (L0).
    INAVOracle public immutable nav;

    /// @notice Default max tolerated depeg before trading is unsafe (basis points).
    uint256 public maxDepegBps = 500; // 5%

    mapping(address asset => IOracleAdapter) private _dexSource;
    mapping(address asset => uint256) private _maxDepegOverrideBps; // 0 = use default
    mapping(address asset => bool) private _halted;

    /// @notice Emitted when a DEX price source is set for an asset.
    event DexSourceSet(address indexed asset, address source);
    /// @notice Emitted when the manual breaker is tripped/reset.
    event HaltSet(address indexed asset, bool halted);
    /// @notice Emitted when a depeg beyond threshold is observed at query time.
    event DepegObserved(address indexed asset, uint256 depegBps, uint256 thresholdBps);
    /// @notice Emitted on threshold updates.
    event ThresholdUpdated(address indexed asset, uint256 bps, bool isDefault);

    error NoDexSource(address asset);
    error InvalidParam();

    /// @param admin Address granted DEFAULT_ADMIN_ROLE, DEPEG_ADMIN and GUARDIAN.
    /// @param _nav The NAV oracle to compare against.
    constructor(address admin, INAVOracle _nav) {
        if (address(_nav) == address(0)) revert InvalidParam();
        nav = _nav;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPEG_ADMIN, admin);
        _grantRole(GUARDIAN, admin);
    }

    /// @notice Wire the DEX spot price source for `asset` (18-decimal adapter).
    /// @dev SECURITY: only DEPEG_ADMIN.
    function setDexSource(address asset, IOracleAdapter source) external onlyRole(DEPEG_ADMIN) {
        _dexSource[asset] = source;
        emit DexSourceSet(asset, address(source));
    }

    /// @notice Set the default depeg threshold.
    /// @dev SECURITY: only DEPEG_ADMIN; must be non-zero.
    function setMaxDepegBps(uint256 bps) external onlyRole(DEPEG_ADMIN) {
        if (bps == 0) revert InvalidParam();
        maxDepegBps = bps;
        emit ThresholdUpdated(address(0), bps, true);
    }

    /// @notice Set or clear a per-asset depeg threshold override (0 clears).
    /// @dev SECURITY: only DEPEG_ADMIN.
    function setMaxDepegOverrideBps(address asset, uint256 bps) external onlyRole(DEPEG_ADMIN) {
        _maxDepegOverrideBps[asset] = bps;
        emit ThresholdUpdated(asset, bps, false);
    }

    /// @notice Trip or reset the manual circuit breaker for `asset`.
    /// @dev SECURITY: only GUARDIAN. A halt forces `isTradingSafe` false regardless of price.
    function setHalted(address asset, bool halted_) external onlyRole(GUARDIAN) {
        _halted[asset] = halted_;
        emit HaltSet(asset, halted_);
    }

    /// @inheritdoc IDepegMonitor
    function depegBps(address asset) public view returns (uint256 bps) {
        IOracleAdapter src = _dexSource[asset];
        if (address(src) == address(0)) revert NoDexSource(asset);
        (uint256 dexPrice,) = src.latestPrice();
        (uint256 fair,,) = nav.getPrice(asset);
        return dexPrice.deviationBps(fair);
    }

    /// @inheritdoc IDepegMonitor
    /// @dev SECURITY: the canonical pre-trade gate. Conservative: any missing data, staleness, halt or
    ///      depeg-over-threshold yields `false`. Never reverts (missing DEX source => unsafe, not revert).
    function isTradingSafe(address asset) external view returns (bool safe) {
        if (_halted[asset]) return false;

        IOracleAdapter src = _dexSource[asset];
        if (address(src) == address(0)) return false;

        (uint256 fair,, bool isStale) = nav.getPrice(asset);
        if (isStale || fair == 0) return false;

        (uint256 dexPrice,) = src.latestPrice();
        if (dexPrice == 0) return false;

        uint256 dep = dexPrice.deviationBps(fair);
        return dep <= _maxDepeg(asset);
    }

    /// @notice Effective depeg threshold for `asset`.
    function maxDepegOf(address asset) external view returns (uint256) {
        return _maxDepeg(asset);
    }

    /// @notice Whether `asset` is manually halted.
    function isHalted(address asset) external view returns (bool) {
        return _halted[asset];
    }

    /// @notice The DEX source wired for `asset`.
    function dexSource(address asset) external view returns (IOracleAdapter) {
        return _dexSource[asset];
    }

    function _maxDepeg(address asset) internal view returns (uint256) {
        uint256 o = _maxDepegOverrideBps[asset];
        return o == 0 ? maxDepegBps : o;
    }
}
