// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IWeightStrategy } from "../../interfaces/IWeightStrategy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FixedWeightStrategy
/// @notice Static target weights configured per asset. Sums to 10_000 across the configured set.
/// @dev SECURITY: owner-settable weights; validates the supplied asset set matches the configuration.
contract FixedWeightStrategy is IWeightStrategy, Ownable {
    mapping(address => uint256) public weightOf;

    error WeightsNotSet();
    error BadSum(uint256 sum);

    constructor(address owner_) Ownable(owner_) { }

    /// @notice Set target weights for `assets`. Must sum to 10_000.
    /// @dev SECURITY: owner only.
    function setWeights(address[] calldata assets, uint256[] calldata weightsBps) external onlyOwner {
        if (assets.length != weightsBps.length || assets.length == 0) revert WeightsNotSet();
        uint256 sum;
        for (uint256 i; i < assets.length; ++i) {
            weightOf[assets[i]] = weightsBps[i];
            sum += weightsBps[i];
        }
        if (sum != 10_000) revert BadSum(sum);
    }

    /// @inheritdoc IWeightStrategy
    function targetWeights(address[] calldata assets) external view returns (uint256[] memory weightsBps) {
        weightsBps = new uint256[](assets.length);
        uint256 sum;
        for (uint256 i; i < assets.length; ++i) {
            uint256 w = weightOf[assets[i]];
            if (w == 0) revert WeightsNotSet();
            weightsBps[i] = w;
            sum += w;
        }
        if (sum != 10_000) revert BadSum(sum);
    }
}
