// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMoneyMarket
/// @notice Minimal Venus/Lista-style lending market surface used by the yield adapters.
interface IMoneyMarket {
    /// @notice The underlying asset of this market.
    function underlying() external view returns (address);

    /// @notice Supply `amount` of underlying (pulled from msg.sender).
    function supply(uint256 amount) external;

    /// @notice Redeem `amount` of underlying back to msg.sender.
    function redeemUnderlying(uint256 amount) external;

    /// @notice Underlying balance of `account` including accrued interest.
    function balanceOfUnderlying(address account) external view returns (uint256);

    /// @notice Current supply rate per year in basis points.
    function supplyRatePerYearBps() external view returns (uint256);
}
