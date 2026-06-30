// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IYieldAdapter } from "../interfaces/IYieldAdapter.sol";
import { IVToken } from "../interfaces/external/IVToken.sol";

/// @title VenusVTokenAdapter
/// @notice Real Venus money-market adapter: supplies one underlying asset into its Venus vToken (a
///         Compound-fork VBep20) and exposes it through the protocol's `IYieldAdapter`.
/// @dev Owned by the YieldRouter (sole depositor). Holds no idle underlying — everything is supplied to
///      the vToken and redeemed on withdraw. `totalAssets` uses the view exchange rate (no accrual write),
///      so it may lag the true balance by at most one accrual; this is acceptable for router ranking and
///      NAV reads. SECURITY: checks Venus's Compound-style 0-success return codes and reverts otherwise.
contract VenusVTokenAdapter is IYieldAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice The Venus vToken this adapter supplies into.
    IVToken public immutable vToken;
    /// @notice The underlying BEP-20 asset.
    IERC20 public immutable underlying;
    /// @notice Blocks per year on the target chain (BSC), used to annualize the per-block supply rate.
    /// @dev Configurable because BSC block time has changed over time; the keeper/admin sets the correct
    ///      value at deploy (≈ 365d / blockTime). Only affects `aprBps` (adapter ranking), not accounting.
    uint256 public immutable blocksPerYear;

    error VenusMintFailed(uint256 code);
    error VenusRedeemFailed(uint256 code);

    /// @param owner_ The YieldRouter (sole depositor).
    /// @param vToken_ The Venus vToken market.
    /// @param blocksPerYear_ Blocks per year on the chain (e.g. ~10_512_000 at 3s blocks).
    constructor(address owner_, IVToken vToken_, uint256 blocksPerYear_) Ownable(owner_) {
        vToken = vToken_;
        underlying = IERC20(vToken_.underlying());
        blocksPerYear = blocksPerYear_;
    }

    /// @inheritdoc IYieldAdapter
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @inheritdoc IYieldAdapter
    /// @dev Underlying = vTokenBalance · exchangeRateStored / 1e18. View; uses the stored (non-accruing)
    ///      exchange rate.
    function totalAssets() public view returns (uint256) {
        uint256 vBal = vToken.balanceOf(address(this));
        if (vBal == 0) return 0;
        return (vBal * vToken.exchangeRateStored()) / WAD;
    }

    /// @inheritdoc IYieldAdapter
    /// @dev APR = supplyRatePerBlock · blocksPerYear, converted from 1e18 mantissa to bps.
    function aprBps() external view returns (uint256) {
        return (vToken.supplyRatePerBlock() * blocksPerYear * BPS) / WAD;
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Pulls `amount`, approves the vToken, supplies via `mint`. CEI; reverts on
    ///      a non-zero Venus error code.
    function deposit(uint256 amount) external onlyOwner {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.forceApprove(address(vToken), amount);
        uint256 code = vToken.mint(amount);
        if (code != 0) revert VenusMintFailed(code);
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Caps to available, redeems exactly `amount` of underlying, forwards to
    ///      `to`. Reverts on a non-zero Venus error code.
    function withdraw(uint256 amount, address to) external onlyOwner returns (uint256 withdrawn) {
        uint256 avail = totalAssets();
        if (amount > avail) amount = avail;
        if (amount == 0) return 0;
        uint256 code = vToken.redeemUnderlying(amount);
        if (code != 0) revert VenusRedeemFailed(code);
        underlying.safeTransfer(to, amount);
        return amount;
    }
}
