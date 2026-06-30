// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPriceOracle } from "../interfaces/IPriceOracle.sol";

/// @title MockPriceOracle
/// @notice Settable 18-decimal USD price oracle implementing IPriceOracle, for tests.
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public price;
    mapping(address => bool) public stale;

    function set(address asset, uint256 price18) external {
        price[asset] = price18;
    }

    function setStale(address asset, bool stale_) external {
        stale[asset] = stale_;
    }

    function getPrice(address asset) external view returns (uint256, uint256, bool) {
        return (price[asset], block.timestamp, stale[asset]);
    }
}
