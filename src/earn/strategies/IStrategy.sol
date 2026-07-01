// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IStrategy
/// @notice Pluggable yield-source adapter for a single {EarnVault}. Wraps one REAL, external, audited
///         on-chain venue (Venus, Lista, …) that pays yield on a single underlying asset.
/// @dev Ownership model: the strategy is owned by exactly ONE EarnVault (`vault()`), which is the sole
///      caller of `deposit`/`withdraw`/`withdrawAll`. The vault reads `totalAssets()` into its ERC-4626
///      NAV and surfaces `supplyAprBps()` as an ESTIMATED, VARIABLE, NOT-GUARANTEED headline rate.
///      SECURITY: `supplyAprBps()` MUST be derived from the venue's actual on-chain state — never a
///      hardcoded or off-chain-fed constant.
interface IStrategy {
    /// @notice The underlying asset this strategy deploys (must equal the vault's asset).
    function asset() external view returns (address);

    /// @notice The EarnVault that owns this strategy and is its sole depositor/withdrawer.
    function vault() external view returns (address);

    /// @notice Total redeemable underlying held by the strategy (principal + accrued yield), in asset units.
    /// @dev View. May lag the true balance by at most one venue accrual (rounding), never overstates.
    function totalAssets() external view returns (uint256);

    /// @notice Current supply APR at the venue, in basis points, derived LIVE from on-chain state.
    /// @dev Estimated, variable, NOT guaranteed. Never hardcoded.
    function supplyAprBps() external view returns (uint256);

    /// @notice Supply `assets` of underlying into the venue.
    /// @dev SECURITY: vault-only. Pulls `assets` from the vault via transferFrom.
    function deposit(uint256 assets) external;

    /// @notice Redeem up to `assets` of underlying from the venue and send it to the vault.
    /// @dev SECURITY: vault-only. Caps to available; returns the amount actually delivered.
    /// @return withdrawn Underlying actually sent back to the vault.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Redeem the strategy's entire position back to the vault (used on migration).
    /// @dev SECURITY: vault-only.
    /// @return withdrawn Underlying actually sent back to the vault.
    function withdrawAll() external returns (uint256 withdrawn);
}
