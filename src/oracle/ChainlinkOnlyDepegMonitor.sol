// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";

/// @title ChainlinkOnlyDepegMonitor
/// @notice Drop-in `IDepegMonitor` for RWA/bStock assets whose only trustworthy price is their Chainlink
///         feed — i.e. assets with no usable on-chain DEX pool (empty or observation-cardinality-1 pools,
///         where a DEX/TWAP cross-check cannot function and would only produce a manipulable or zero read).
/// @dev ADDITIVE. Deploys alongside the live core and is wired in via `PortfolioFactory.setWiring`
///      (FACTORY_ADMIN) — it does NOT modify or redeploy any core contract. Portfolios created after the
///      re-wire capture this monitor at init; portfolios created before it keep the original DepegMonitor.
///
///      Safety model (Chainlink-only, fail-safe preserved):
///        - `isTradingSafe(asset)` is true ONLY when the asset is not manually halted AND the NAVOracle
///          reports a fresh (`!isStale`), non-zero price. NAVOracle's own per-asset staleness/close guards
///          are the single source of truth: **a stale Chainlink feed pauses the asset**, exactly as the
///          original breaker would on stale data.
///        - There is deliberately NO DEX/TWAP failover: if Chainlink is stale, trading stops rather than
///          silently falling back to a thin DEX price.
///        - GUARDIAN can still trip a manual halt (forces unsafe regardless of price), matching the core
///          DepegMonitor's guardian surface.
///
///      `depegBps` returns 0: there is no DEX market price to measure a depeg against. The value exists only
///      to satisfy the interface; consumers gate on `isTradingSafe`, not `depegBps`.
contract ChainlinkOnlyDepegMonitor is IDepegMonitor, AccessControl {
    /// @notice Role allowed to trip / reset the manual circuit breaker.
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    /// @notice NAV fair-value oracle (L0) — the sole price/staleness authority.
    INAVOracle public immutable nav;

    mapping(address asset => bool) private _halted;

    /// @notice Emitted when the manual breaker is tripped/reset.
    event HaltSet(address indexed asset, bool halted);

    error InvalidParam();

    /// @param admin Address granted DEFAULT_ADMIN_ROLE and GUARDIAN.
    /// @param _nav The NAV oracle whose freshness gates trading.
    constructor(address admin, INAVOracle _nav) {
        if (address(_nav) == address(0) || admin == address(0)) revert InvalidParam();
        nav = _nav;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN, admin);
    }

    /// @notice Trip or reset the manual circuit breaker for `asset`.
    /// @dev SECURITY: only GUARDIAN. A halt forces `isTradingSafe` false regardless of price.
    function setHalted(address asset, bool halted_) external onlyRole(GUARDIAN) {
        _halted[asset] = halted_;
        emit HaltSet(asset, halted_);
    }

    /// @notice Whether `asset` is manually halted.
    function isHalted(address asset) external view returns (bool) {
        return _halted[asset];
    }

    /// @inheritdoc IDepegMonitor
    /// @dev No DEX source in a Chainlink-only world, so there is nothing to measure a depeg against.
    ///      Always 0; `isTradingSafe` is the meaningful gate.
    function depegBps(address) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IDepegMonitor
    /// @dev Conservative: false on manual halt, or if the NAV price is stale or zero. Never reverts on an
    ///      unconfigured asset (a missing config makes NAVOracle.getPrice revert, so we guard by catching it
    ///      as unsafe rather than bubbling the revert into the mint path).
    function isTradingSafe(address asset) external view returns (bool safe) {
        if (_halted[asset]) return false;
        try nav.getPrice(asset) returns (uint256 price, uint256, bool isStale) {
            return !isStale && price != 0;
        } catch {
            return false;
        }
    }
}
