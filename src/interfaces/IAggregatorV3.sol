// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAggregatorV3
/// @notice Minimal Chainlink AggregatorV3 surface used by ChainlinkAdapter.
interface IAggregatorV3 {
    /// @notice Decimals of the answer returned by the feed.
    function decimals() external view returns (uint8);

    /// @notice Latest round data.
    /// @return roundId The round identifier.
    /// @return answer The price answer (signed, `decimals()` precision).
    /// @return startedAt Round start timestamp.
    /// @return updatedAt Round update timestamp.
    /// @return answeredInRound Round the answer was computed in.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
