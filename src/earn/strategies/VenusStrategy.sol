// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IStrategy } from "./IStrategy.sol";
import { IVToken } from "../../interfaces/external/IVToken.sol";

/// @title VenusStrategy
/// @notice Real Venus money-market strategy for {EarnVault}: supplies the vault's underlying into its
///         Venus vToken (a Compound-fork VBep20) and earns the live Venus supply APY.
/// @dev Owned by exactly one EarnVault (`vault`), the sole caller. Holds no idle underlying — everything is
///      supplied to the vToken and redeemed on withdraw. `totalAssets` uses the view exchange rate (no
///      accrual write), so it may lag the true balance by at most one accrual; acceptable for NAV reads.
///      `supplyAprBps` is derived LIVE from Venus's on-chain `supplyRatePerBlock` — never hardcoded.
///      SECURITY: checks Venus's Compound-style 0-success return codes and reverts otherwise.
contract VenusStrategy is IStrategy {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice The EarnVault that owns this strategy (sole depositor/withdrawer).
    address public immutable vault;
    /// @notice The Venus vToken this strategy supplies into.
    IVToken public immutable vToken;
    /// @notice The underlying BEP-20 asset.
    IERC20 public immutable underlying;
    /// @notice Blocks per year on the target chain (BSC), used to annualize the per-block supply rate.
    /// @dev Configurable because BSC block time has changed over time; the operator sets the correct value
    ///      at deploy (≈ 365d / blockTime). Affects only `supplyAprBps` (the estimate), not accounting.
    uint256 public immutable blocksPerYear;

    error OnlyVault();
    error VenusMintFailed(uint256 code);
    error VenusRedeemFailed(uint256 code);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @param vault_ The EarnVault that owns this strategy.
    /// @param vToken_ The Venus vToken market.
    /// @param blocksPerYear_ Blocks per year on the chain (operator-supplied; e.g. ~10_512_000 at 3s blocks).
    constructor(address vault_, IVToken vToken_, uint256 blocksPerYear_) {
        vault = vault_;
        vToken = vToken_;
        underlying = IERC20(vToken_.underlying());
        blocksPerYear = blocksPerYear_;
    }

    /// @inheritdoc IStrategy
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @inheritdoc IStrategy
    /// @dev Underlying = vTokenBalance · exchangeRateStored / 1e18. View; uses the stored (non-accruing) rate.
    function totalAssets() public view returns (uint256) {
        uint256 vBal = vToken.balanceOf(address(this));
        if (vBal == 0) return 0;
        return (vBal * vToken.exchangeRateStored()) / WAD;
    }

    /// @inheritdoc IStrategy
    /// @dev APR = supplyRatePerBlock · blocksPerYear, converted from 1e18 mantissa to bps. LIVE on-chain read.
    function supplyAprBps() external view returns (uint256) {
        return (vToken.supplyRatePerBlock() * blocksPerYear * BPS) / WAD;
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Pulls `assets`, approves the vToken, supplies via `mint`. CEI; reverts on
    ///      a non-zero Venus error code.
    function deposit(uint256 assets) external onlyVault {
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        underlying.forceApprove(address(vToken), assets);
        uint256 code = vToken.mint(assets);
        if (code != 0) revert VenusMintFailed(code);
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Caps to available, redeems exactly `assets` of underlying, sends to vault.
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        return _redeemTo(assets, vault);
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Redeems the whole position back to the vault.
    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        return _redeemTo(totalAssets(), vault);
    }

    /// @dev Redeem `assets` (capped to available) of underlying and forward to `to`. Reverts on a non-zero
    ///      Venus error code.
    function _redeemTo(uint256 assets, address to) internal returns (uint256) {
        uint256 avail = totalAssets();
        if (assets > avail) assets = avail;
        if (assets == 0) return 0;
        uint256 code = vToken.redeemUnderlying(assets);
        if (code != 0) revert VenusRedeemFailed(code);
        underlying.safeTransfer(to, assets);
        return assets;
    }
}
