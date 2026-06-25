// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IOracleAdapter } from "../interfaces/IOracleAdapter.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { PriceLib } from "../libraries/PriceLib.sol";

/// @title ChainlinkAdapter
/// @notice Wraps a Chainlink-style AggregatorV3 feed and exposes it as an 18-decimal IOracleAdapter.
/// @dev One adapter wraps one feed. Validates sign/round integrity before scaling.
contract ChainlinkAdapter is IOracleAdapter {
    using PriceLib for uint256;

    /// @notice The wrapped Chainlink aggregator.
    IAggregatorV3 public immutable feed;
    /// @notice Cached decimals of the feed answer.
    uint8 public immutable feedDecimals;

    /// @notice Thrown when the feed reports a non-positive price.
    error NonPositiveAnswer(int256 answer);
    /// @notice Thrown when the feed round is incomplete or stale-by-round.
    error StaleRound(uint80 roundId, uint80 answeredInRound);

    /// @param _feed The Chainlink aggregator to wrap.
    constructor(IAggregatorV3 _feed) {
        feed = _feed;
        feedDecimals = _feed.decimals();
    }

    /// @inheritdoc IOracleAdapter
    /// @dev SECURITY: rejects non-positive answers and rounds where `answeredInRound < roundId`
    ///      (carried-over / incomplete rounds), then scales to 18 decimals. View-only; no state.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 _updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert NonPositiveAnswer(answer);
        if (answeredInRound < roundId) revert StaleRound(roundId, answeredInRound);
        price = uint256(answer).scaleTo18(feedDecimals);
        updatedAt = _updatedAt;
    }
}
