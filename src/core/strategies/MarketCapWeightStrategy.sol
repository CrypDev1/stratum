// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IWeightStrategy } from "../../interfaces/IWeightStrategy.sol";
import { INAVOracle } from "../../interfaces/INAVOracle.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MarketCapWeightStrategy
/// @notice Target weights proportional to market cap (price × shares outstanding) of each asset.
/// @dev Price comes from the L0 NAV oracle; shares-outstanding (the real-world float of each tokenized
///      equity) is admin-configured. Rounding dust is assigned to the last asset so weights sum to 10_000.
contract MarketCapWeightStrategy is IWeightStrategy, Ownable {
    /// @notice L0 fair-value oracle.
    INAVOracle public immutable nav;
    /// @notice Real-world shares outstanding per asset (used as the market-cap multiplier).
    mapping(address => uint256) public sharesOutstanding;

    error NoSupply(address asset);
    error StalePrice(address asset);
    error ZeroCap();

    constructor(address owner_, INAVOracle _nav) Ownable(owner_) {
        nav = _nav;
    }

    /// @notice Set the shares-outstanding multiplier for `asset`.
    /// @dev SECURITY: owner only.
    function setSharesOutstanding(address asset, uint256 shares) external onlyOwner {
        sharesOutstanding[asset] = shares;
    }

    /// @inheritdoc IWeightStrategy
    /// @dev SECURITY: reverts on stale price or missing supply so weights are never derived from bad data.
    function targetWeights(address[] calldata assets) external view returns (uint256[] memory weightsBps) {
        uint256 n = assets.length;
        uint256[] memory caps = new uint256[](n);
        uint256 totalCap;
        for (uint256 i; i < n; ++i) {
            uint256 supply = sharesOutstanding[assets[i]];
            if (supply == 0) revert NoSupply(assets[i]);
            (uint256 price,, bool isStale) = nav.getPrice(assets[i]);
            if (isStale || price == 0) revert StalePrice(assets[i]);
            caps[i] = price * supply;
            totalCap += caps[i];
        }
        if (totalCap == 0) revert ZeroCap();

        weightsBps = new uint256[](n);
        uint256 acc;
        for (uint256 i; i < n - 1; ++i) {
            uint256 w = (caps[i] * 10_000) / totalCap;
            weightsBps[i] = w;
            acc += w;
        }
        weightsBps[n - 1] = 10_000 - acc; // remainder absorbs rounding dust
    }
}
