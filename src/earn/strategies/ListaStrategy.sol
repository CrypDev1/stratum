// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IStrategy } from "./IStrategy.sol";

/// @title ListaStrategy
/// @notice Real Lista DAO yield strategy for {EarnVault}: routes the vault's underlying into Lista's
///         interest-bearing ERC-4626 vault and earns its live yield.
/// @dev Owned by exactly one EarnVault (`vault`), the sole caller. Accounting is exact via
///      `convertToAssets`. Lista's ERC-4626 exposes no standard APR field, so `supplyAprBps` is derived
///      LIVE and on-chain from the REALIZED growth of the venue's own share price
///      (`convertToAssets(1e18 shares)`) between a checkpoint and now — no hardcoded or off-chain rate.
///      Anyone may `poke()` to roll the measurement window forward. It is a trailing realized estimate:
///      variable, NOT guaranteed.
contract ListaStrategy is IStrategy {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    /// @notice The EarnVault that owns this strategy (sole depositor/withdrawer).
    address public immutable vault;
    /// @notice The Lista ERC-4626 vault.
    IERC4626 public immutable lista;
    /// @notice The underlying asset.
    IERC20 public immutable underlying;

    /// @notice Venue share price (`convertToAssets(1e18)`) captured at the last checkpoint.
    uint256 public checkpointPrice;
    /// @notice Timestamp of the last checkpoint.
    uint256 public checkpointTime;

    event Poked(uint256 fromPrice, uint256 toPrice, uint256 elapsed, uint256 realizedAprBps);

    error OnlyVault();
    error AssetMismatch();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @param vault_ The EarnVault that owns this strategy.
    /// @param lista_ The Lista interest-bearing ERC-4626 vault (its `asset()` is the underlying).
    constructor(address vault_, IERC4626 lista_) {
        vault = vault_;
        lista = lista_;
        underlying = IERC20(lista_.asset());
        // Seed the realized-APR measurement window at deploy from the live venue share price.
        checkpointPrice = lista_.convertToAssets(WAD);
        checkpointTime = block.timestamp;
    }

    /// @inheritdoc IStrategy
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @inheritdoc IStrategy
    /// @dev Exact redeemable underlying for this strategy's Lista shares.
    function totalAssets() public view returns (uint256) {
        return lista.convertToAssets(lista.balanceOf(address(this)));
    }

    /// @notice Live venue share price: underlying redeemable for 1e18 Lista shares.
    function currentPrice() public view returns (uint256) {
        return lista.convertToAssets(WAD);
    }

    /// @inheritdoc IStrategy
    /// @dev Trailing realized APR from the venue's own on-chain share-price growth since the last checkpoint:
    ///      aprBps = (price_now − price_ckpt) · BPS · YEAR / (price_ckpt · elapsed). Returns 0 before any
    ///      elapsed time or growth. Purely on-chain; no hardcoded rate.
    function supplyAprBps() external view returns (uint256) {
        uint256 elapsed = block.timestamp - checkpointTime;
        if (elapsed == 0) return 0;
        uint256 nowPrice = currentPrice();
        if (nowPrice <= checkpointPrice || checkpointPrice == 0) return 0;
        uint256 growth = nowPrice - checkpointPrice;
        return (growth * BPS * YEAR) / (checkpointPrice * elapsed);
    }

    /// @notice Roll the realized-APR measurement window forward to the current block.
    /// @dev Permissionless: a keeper (or anyone) calls this to keep the trailing estimate fresh. Affects only
    ///      the reported estimate, never accounting.
    function poke() external {
        uint256 nowPrice = currentPrice();
        uint256 elapsed = block.timestamp - checkpointTime;
        uint256 realized;
        if (elapsed > 0 && nowPrice > checkpointPrice && checkpointPrice > 0) {
            realized = ((nowPrice - checkpointPrice) * BPS * YEAR) / (checkpointPrice * elapsed);
        }
        emit Poked(checkpointPrice, nowPrice, elapsed, realized);
        checkpointPrice = nowPrice;
        checkpointTime = block.timestamp;
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Pulls `assets`, approves Lista, deposits for shares to this strategy.
    function deposit(uint256 assets) external onlyVault {
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        underlying.forceApprove(address(lista), assets);
        lista.deposit(assets, address(this));
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Caps to available, withdraws exactly `assets` of underlying to the vault.
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        return _redeemTo(assets, vault);
    }

    /// @inheritdoc IStrategy
    /// @dev SECURITY: vault-only. Redeems the whole position back to the vault.
    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        return _redeemTo(totalAssets(), vault);
    }

    /// @dev Withdraw `assets` (capped to available) of underlying from Lista and forward to `to`.
    function _redeemTo(uint256 assets, address to) internal returns (uint256) {
        uint256 avail = totalAssets();
        if (assets > avail) assets = avail;
        if (assets == 0) return 0;
        lista.withdraw(assets, to, address(this));
        return assets;
    }
}
