// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";

/// @title MockAggregatorV3
/// @notice Settable Chainlink-style aggregator for tests.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    /// @notice Update the answer and stamp it now (round advances).
    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId += 1;
        answeredInRound = roundId;
    }

    /// @notice Fully control the returned round data (to simulate stale/incomplete rounds).
    function setRound(int256 _answer, uint256 _updatedAt, uint80 _roundId, uint80 _answeredInRound) external {
        answer = _answer;
        updatedAt = _updatedAt;
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
