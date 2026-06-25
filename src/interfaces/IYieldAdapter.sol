// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IYieldAdapter
/// @notice Uniform interface over a money-market position (Venus, Lista, …) for one underlying asset.
/// @dev Owned by the YieldRouter, which is the sole depositor. `totalAssets` includes accrued yield.
interface IYieldAdapter {
    /// @notice The underlying asset this adapter deploys.
    function asset() external view returns (address);

    /// @notice Total redeemable underlying held by this adapter (principal + accrued yield).
    function totalAssets() external view returns (uint256);

    /// @notice Current supply APR in basis points (used by the router to rank adapters).
    function aprBps() external view returns (uint256);

    /// @notice Deposit `amount` of underlying (pulled from msg.sender) into the money market.
    /// @param amount Underlying amount to supply.
    function deposit(uint256 amount) external;

    /// @notice Withdraw `amount` of underlying to `to`.
    /// @param amount Underlying amount to redeem.
    /// @param to Recipient.
    /// @return withdrawn Actual amount sent.
    function withdraw(uint256 amount, address to) external returns (uint256 withdrawn);
}
