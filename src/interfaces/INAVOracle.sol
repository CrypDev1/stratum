// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPriceOracle } from "./IPriceOracle.sol";

/// @title INAVOracle
/// @notice Fair-value NAV oracle that stays live through the ~17h/day + weekends the US market is closed.
/// @dev Extends IPriceOracle with after-hours awareness and market-status introspection.
interface INAVOracle is IPriceOracle {
    /// @notice Full price record including the after-hours flag.
    struct PriceData {
        uint256 price; // 18-decimal USD fair value
        uint256 updatedAt; // timestamp the value reflects
        bool isStale; // breaches staleness/deviation guards
        bool afterHours; // true when derived from last close + bounded drift
    }

    /// @notice Returns the full price record for `asset`.
    /// @param asset Token to price.
    /// @return data The price, timestamp, staleness and after-hours flags.
    function getPriceData(address asset) external view returns (PriceData memory data);

    /// @notice Whether the underlying market for `asset` is currently flagged open.
    /// @param asset Token to query.
    /// @return open True if regular trading hours are active.
    function marketOpen(address asset) external view returns (bool open);
}
