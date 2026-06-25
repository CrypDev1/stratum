// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PriceLib
/// @notice Safe decimal-scaling and deviation helpers for 18-decimal (WAD) USD prices.
/// @dev All Stratum oracle values are normalized to 18 decimals. This library centralizes
///      the scaling math so adapters and consumers never hand-roll error-prone exponents.
library PriceLib {
    /// @notice Number of decimals every Stratum price is normalized to.
    uint8 internal constant WAD_DECIMALS = 18;
    /// @notice 1.0 expressed in WAD.
    uint256 internal constant WAD = 1e18;
    /// @notice Full-scale basis points (100%).
    uint256 internal constant BPS = 10_000;

    /// @notice Thrown when a decimal count would overflow the scaling exponent.
    error DecimalsTooLarge(uint8 decimals);

    /// @notice Scale a raw price with `fromDecimals` precision up/down to 18 decimals.
    /// @dev SECURITY: pure integer math; downscaling truncates (rounds toward zero) which is
    ///      acceptable because it never inflates a price. Bounds `fromDecimals` to avoid 10**n overflow.
    /// @param price Raw price value.
    /// @param fromDecimals Decimals of `price`.
    /// @return The price expressed with 18 decimals.
    function scaleTo18(uint256 price, uint8 fromDecimals) internal pure returns (uint256) {
        if (fromDecimals == WAD_DECIMALS) return price;
        if (fromDecimals > 77) revert DecimalsTooLarge(fromDecimals);
        if (fromDecimals < WAD_DECIMALS) {
            return price * (10 ** uint256(WAD_DECIMALS - fromDecimals));
        }
        return price / (10 ** uint256(fromDecimals - WAD_DECIMALS));
    }

    /// @notice Absolute deviation between two WAD prices expressed in basis points of `reference`.
    /// @dev SECURITY: returns BPS-scaled deviation; guards against zero reference by returning max.
    /// @param value The observed price.
    /// @param baseline The baseline price to measure deviation against.
    /// @return Deviation in basis points (e.g. 100 = 1%).
    function deviationBps(uint256 value, uint256 baseline) internal pure returns (uint256) {
        if (baseline == 0) return type(uint256).max;
        uint256 diff = value > baseline ? value - baseline : baseline - value;
        return (diff * BPS) / baseline;
    }

    /// @notice Apply a signed basis-point drift to a base price, clamped to ±`maxBps`.
    /// @dev SECURITY: clamps drift so an over-eager keeper input can never move price beyond the
    ///      governance-set bound; floors result at zero. Used for after-hours fair-value adjustment.
    /// @param base The reference (last close) price in WAD.
    /// @param driftBps Signed drift in basis points.
    /// @param maxBps Maximum absolute drift permitted in basis points.
    /// @return The drift-adjusted price in WAD.
    function applyDriftBps(uint256 base, int256 driftBps, uint256 maxBps) internal pure returns (uint256) {
        int256 maxB = int256(maxBps);
        int256 d = driftBps;
        if (d > maxB) d = maxB;
        if (d < -maxB) d = -maxB;
        int256 adjusted = int256(BPS) + d;
        if (adjusted <= 0) return 0;
        return (base * uint256(adjusted)) / BPS;
    }
}
