// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";

/// @title MockOracleAdapter
/// @notice Settable 18-decimal price source for tests and local Anvil deployments.
/// @dev TODO(integration): replace with ChainlinkAdapter (or a DEX TWAP adapter) on testnet/mainnet.
contract MockOracleAdapter is IOracleAdapter {
    uint256 private _price;
    uint256 private _updatedAt;

    /// @param price_ Initial 18-decimal price.
    /// @param updatedAt_ Initial update timestamp.
    constructor(uint256 price_, uint256 updatedAt_) {
        _price = price_;
        _updatedAt = updatedAt_;
    }

    /// @notice Set the price and stamp it at the current block time.
    /// @param price_ New 18-decimal price.
    function setPrice(uint256 price_) external {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    /// @notice Set both price and explicit timestamp (to simulate staleness).
    /// @param price_ New 18-decimal price.
    /// @param updatedAt_ Timestamp to report.
    function setPriceAt(uint256 price_, uint256 updatedAt_) external {
        _price = price_;
        _updatedAt = updatedAt_;
    }

    /// @inheritdoc IOracleAdapter
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}
