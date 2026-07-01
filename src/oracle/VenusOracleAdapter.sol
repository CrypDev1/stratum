// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { IVenusOracle } from "../interfaces/external/IVenusOracle.sol";

/// @title VenusOracleAdapter
/// @notice `IOracleAdapter` that prices a bStock through Venus's ResilientOracle.
/// @dev WHY THIS EXISTS: the bStock Chainlink "SingleFeed" aggregators are access-controlled — they only
///      serve on-chain reads to authorized consumers (Venus's ResilientOracle is one), and revert with
///      `OnlyAuthorizedCallerAllowed()` for any other contract. So we cannot read the raw feed directly
///      from a fresh `ChainlinkAdapter`. Instead we read the price through Venus's ResilientOracle, whose
///      *main* source for these assets IS that same Chainlink SingleFeed (oracles[0] = ChainlinkOracle) —
///      i.e. this is still Chainlink-primary fair value, just accessed via the authorized reader.
///
///      Venus's ResilientOracle enforces its own per-asset staleness and reverts when the underlying
///      Chainlink price is stale/invalid. This adapter therefore treats a successful read as "fresh as of
///      now" (`updatedAt = block.timestamp`) and, being an `IOracleAdapter` (which must not revert so the
///      NAVOracle can flag rather than blow up), CATCHES a Venus revert and returns `(0, 0)`. The NAVOracle
///      then marks the price stale (`price == 0`), the ChainlinkOnlyDepegMonitor reports the asset unsafe,
///      and trading pauses — exactly the required fail-safe: **a stale Chainlink feed pauses the asset.**
///
///      ADDITIVE: one instance per asset, wired as the NAVOracle primary via `configureAsset`. Touches no
///      core contract.
contract VenusOracleAdapter is IOracleAdapter {
    /// @notice Venus ResilientOracle (BNB mainnet: 0x6592b5DE802159F3E74B2486b091D11a8256ab8A).
    IVenusOracle public immutable venusOracle;
    /// @notice The asset this adapter prices.
    address public immutable asset;

    error ZeroAddress();

    constructor(IVenusOracle venusOracle_, address asset_) {
        if (address(venusOracle_) == address(0) || asset_ == address(0)) revert ZeroAddress();
        venusOracle = venusOracle_;
        asset = asset_;
    }

    /// @inheritdoc IOracleAdapter
    /// @dev Returns Venus's 1e18-scaled price with `updatedAt = now` on success; `(0, 0)` if Venus reverts
    ///      (stale/invalid), so the NAVOracle flags the asset stale instead of reverting the read.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        try venusOracle.getPrice(asset) returns (uint256 p) {
            if (p == 0) return (0, 0);
            return (p, block.timestamp);
        } catch {
            return (0, 0);
        }
    }
}
