// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { PriceLib } from "../libraries/PriceLib.sol";

/// @title NAVOracle
/// @notice Fair-value NAV oracle for tokenized equities, live 24/7.
/// @dev When the underlying US market is open it returns the primary feed (cross-checked against an
///      optional secondary). When closed it returns the recorded close adjusted by a bounded, keeper-
///      signed implied drift and flags `afterHours = true`. Enforces staleness and deviation guards.
contract NAVOracle is INAVOracle, AccessControl {
    using PriceLib for uint256;

    /// @notice Role allowed to register/configure assets.
    bytes32 public constant ORACLE_ADMIN = keccak256("ORACLE_ADMIN");
    /// @notice Role allowed to flip market open/closed and post implied drift.
    bytes32 public constant MARKET_KEEPER = keccak256("MARKET_KEEPER");

    /// @notice Per-asset source + guard configuration.
    struct AssetConfig {
        IOracleAdapter primary; // primary 18-dec source
        IOracleAdapter secondary; // optional cross-check source (address(0) = none)
        uint64 maxStaleness; // max age (s) of primary while market open
        uint64 maxClosedStaleness; // max age (s) of last close while market closed (covers weekends)
        uint32 maxDeviationBps; // max primary/secondary deviation before flagging stale
        uint32 maxDriftBps; // bound on after-hours implied drift
        bool configured;
    }

    /// @notice Per-asset live market state.
    struct MarketState {
        bool open;
        uint256 lastClosePrice; // 18-dec price captured when market last closed
        uint256 lastCloseAt; // timestamp of that capture
        int256 driftBps; // signed implied drift applied while closed
        uint256 driftUpdatedAt; // timestamp drift was last posted
    }

    mapping(address asset => AssetConfig) private _config;
    mapping(address asset => MarketState) private _market;

    /// @notice Emitted when an asset is registered or reconfigured.
    event AssetConfigured(address indexed asset, address primary, address secondary);
    /// @notice Emitted when market status flips; on close, carries the captured close price.
    event MarketStatusSet(address indexed asset, bool open, uint256 closePrice, uint256 at);
    /// @notice Emitted when a keeper posts an implied after-hours drift.
    event ImpliedDriftSet(address indexed asset, int256 driftBps, uint256 at);

    error AssetNotConfigured(address asset);
    error InvalidConfig();
    error NoClosePrice(address asset);

    /// @param admin Address granted DEFAULT_ADMIN_ROLE, ORACLE_ADMIN and MARKET_KEEPER.
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN, admin);
        _grantRole(MARKET_KEEPER, admin);
    }

    // --------------------------------------------------------------------- //
    //                              Configuration                            //
    // --------------------------------------------------------------------- //

    /// @notice Register or update an asset's price sources and guards.
    /// @dev SECURITY: only ORACLE_ADMIN. Requires a primary source and non-zero staleness windows so
    ///      a misconfiguration cannot silently disable the staleness guard. Markets default to open.
    /// @param asset Token to configure.
    /// @param cfg The source + guard configuration.
    function configureAsset(address asset, AssetConfig calldata cfg) external onlyRole(ORACLE_ADMIN) {
        if (
            asset == address(0) || address(cfg.primary) == address(0) || cfg.maxStaleness == 0
                || cfg.maxClosedStaleness == 0
        ) {
            revert InvalidConfig();
        }
        AssetConfig storage c = _config[asset];
        c.primary = cfg.primary;
        c.secondary = cfg.secondary;
        c.maxStaleness = cfg.maxStaleness;
        c.maxClosedStaleness = cfg.maxClosedStaleness;
        c.maxDeviationBps = cfg.maxDeviationBps;
        c.maxDriftBps = cfg.maxDriftBps;
        if (!c.configured) {
            c.configured = true;
            _market[asset].open = true;
        }
        emit AssetConfigured(asset, address(cfg.primary), address(cfg.secondary));
    }

    /// @notice Flip the market open/closed flag for `asset`.
    /// @dev SECURITY: only MARKET_KEEPER. On an open->closed transition the current primary price is
    ///      snapshotted as the close reference and any stale drift is reset. On close->open, drift clears.
    /// @param asset Token whose market status changes.
    /// @param open True to mark regular trading hours active.
    function setMarketStatus(address asset, bool open) external onlyRole(MARKET_KEEPER) {
        AssetConfig storage c = _config[asset];
        if (!c.configured) revert AssetNotConfigured(asset);
        MarketState storage m = _market[asset];

        if (!open && m.open) {
            // Capture the close from the primary feed.
            (uint256 p,) = c.primary.latestPrice();
            m.lastClosePrice = p;
            m.lastCloseAt = block.timestamp;
            m.driftBps = 0;
            m.driftUpdatedAt = block.timestamp;
            emit MarketStatusSet(asset, false, p, block.timestamp);
        } else if (open && !m.open) {
            m.driftBps = 0;
            emit MarketStatusSet(asset, true, 0, block.timestamp);
        }
        m.open = open;
    }

    /// @notice Manually record a close price (fallback when the primary feed is unavailable at close).
    /// @dev SECURITY: only MARKET_KEEPER; price must be non-zero. Does not change market status.
    /// @param asset Token to record a close for.
    /// @param closePrice 18-decimal close price.
    function recordClose(address asset, uint256 closePrice) external onlyRole(MARKET_KEEPER) {
        if (!_config[asset].configured) revert AssetNotConfigured(asset);
        if (closePrice == 0) revert InvalidConfig();
        MarketState storage m = _market[asset];
        m.lastClosePrice = closePrice;
        m.lastCloseAt = block.timestamp;
        emit MarketStatusSet(asset, m.open, closePrice, block.timestamp);
    }

    /// @notice Post the keeper-signed implied drift used while the market is closed.
    /// @dev SECURITY: only MARKET_KEEPER. The drift is *clamped* to ±maxDriftBps at read time, so even
    ///      a faulty input cannot move the fair value beyond the governance bound.
    /// @param asset Token to drift.
    /// @param driftBps Signed drift in basis points.
    function setImpliedDrift(address asset, int256 driftBps) external onlyRole(MARKET_KEEPER) {
        if (!_config[asset].configured) revert AssetNotConfigured(asset);
        MarketState storage m = _market[asset];
        m.driftBps = driftBps;
        m.driftUpdatedAt = block.timestamp;
        emit ImpliedDriftSet(asset, driftBps, block.timestamp);
    }

    // --------------------------------------------------------------------- //
    //                                Reads                                   //
    // --------------------------------------------------------------------- //

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt, bool isStale) {
        PriceData memory d = _priceData(asset);
        return (d.price, d.updatedAt, d.isStale);
    }

    /// @inheritdoc INAVOracle
    function getPriceData(address asset) external view returns (PriceData memory data) {
        return _priceData(asset);
    }

    /// @inheritdoc INAVOracle
    function marketOpen(address asset) external view returns (bool open) {
        if (!_config[asset].configured) revert AssetNotConfigured(asset);
        return _market[asset].open;
    }

    /// @notice View the stored configuration for `asset`.
    function assetConfig(address asset) external view returns (AssetConfig memory) {
        return _config[asset];
    }

    /// @notice View the stored market state for `asset`.
    function marketState(address asset) external view returns (MarketState memory) {
        return _market[asset];
    }

    /// @dev Core pricing logic shared by getPrice/getPriceData.
    ///      SECURITY: never reverts on stale/deviating data — it returns `isStale = true` so consumers
    ///      decide. Reverts only when the asset is unconfigured (a genuine integration error).
    function _priceData(address asset) internal view returns (PriceData memory data) {
        AssetConfig storage c = _config[asset];
        if (!c.configured) revert AssetNotConfigured(asset);
        MarketState storage m = _market[asset];

        if (m.open) {
            (uint256 p, uint256 ts) = c.primary.latestPrice();
            bool stale = p == 0 || block.timestamp > ts + c.maxStaleness;

            if (address(c.secondary) != address(0)) {
                (uint256 p2,) = c.secondary.latestPrice();
                if (p2 == 0 || p.deviationBps(p2) > c.maxDeviationBps) {
                    stale = true;
                }
            }
            return PriceData({ price: p, updatedAt: ts, isStale: stale, afterHours: false });
        }

        // Market closed: last close + bounded drift.
        uint256 base = m.lastClosePrice;
        if (base == 0) revert NoClosePrice(asset);
        uint256 adjusted = base.applyDriftBps(m.driftBps, c.maxDriftBps);
        bool closedStale = block.timestamp > m.lastCloseAt + c.maxClosedStaleness;
        uint256 ref = m.driftUpdatedAt > m.lastCloseAt ? m.driftUpdatedAt : m.lastCloseAt;
        return PriceData({ price: adjusted, updatedAt: ref, isStale: closedStale, afterHours: true });
    }
}
