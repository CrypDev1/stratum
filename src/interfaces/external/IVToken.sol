// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVToken
/// @notice Minimal Venus vToken (Compound-fork VBep20) surface used by the Venus yield adapter.
/// @dev Venus markets are Compound forks: `mint`/`redeemUnderlying` return a 0 error code on success.
///      `exchangeRateStored` is the view accessor (no accrual); `supplyRatePerBlock` is a 1e18-mantissa
///      per-block rate.
interface IVToken {
    /// @notice The underlying BEP-20 asset of this market.
    function underlying() external view returns (address);

    /// @notice Supply `mintAmount` of underlying; returns 0 on success.
    function mint(uint256 mintAmount) external returns (uint256);

    /// @notice Redeem `redeemAmount` of underlying; returns 0 on success.
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    /// @notice vToken balance of `owner` (view).
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Stored exchange rate (underlying per vToken, scaled by 1e18·10^(uDec-8)) — view, no accrual.
    function exchangeRateStored() external view returns (uint256);

    /// @notice Underlying balance of `owner` including accrued interest — NON-view (accrues).
    function balanceOfUnderlying(address owner) external returns (uint256);

    /// @notice Per-block supply rate, 1e18 mantissa.
    function supplyRatePerBlock() external view returns (uint256);
}
