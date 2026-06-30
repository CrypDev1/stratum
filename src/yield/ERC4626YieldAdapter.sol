// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IYieldAdapter } from "../interfaces/IYieldAdapter.sol";

/// @title ERC4626YieldAdapter
/// @notice Real yield adapter over any ERC-4626 vault, exposed through the protocol's `IYieldAdapter`.
/// @dev Used for venues that expose the ERC-4626 standard (e.g. Lista's interest-bearing vaults). Owned by
///      the YieldRouter (sole depositor). ERC-4626 carries no on-chain APR, so the supply rate used for
///      router ranking is a keeper-maintained `aprBps` (set by `rateKeeper`); accounting is exact via
///      `convertToAssets`. SECURITY: deposit/withdraw are owner-only; rate updates are keeper-only.
contract ERC4626YieldAdapter is IYieldAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The ERC-4626 vault.
    IERC4626 public immutable vault;
    /// @notice The underlying asset.
    IERC20 public immutable underlying;
    /// @notice Address allowed to update the reported APR (an off-chain keeper).
    address public immutable rateKeeper;

    /// @notice Keeper-maintained supply APR (bps) used only for router adapter ranking.
    uint256 public aprBpsStored;

    event AprSet(uint256 aprBps);

    error NotRateKeeper();
    error AssetMismatch();

    /// @param owner_ The YieldRouter (sole depositor).
    /// @param vault_ The ERC-4626 vault.
    /// @param rateKeeper_ Address allowed to update the reported APR.
    /// @param initialAprBps_ Initial reported APR (bps).
    constructor(address owner_, IERC4626 vault_, address rateKeeper_, uint256 initialAprBps_) Ownable(owner_) {
        vault = vault_;
        underlying = IERC20(vault_.asset());
        rateKeeper = rateKeeper_;
        aprBpsStored = initialAprBps_;
    }

    /// @notice Update the reported supply APR (bps).
    /// @dev SECURITY: rateKeeper only. Affects only adapter ranking, never accounting.
    function setAprBps(uint256 aprBps_) external {
        if (msg.sender != rateKeeper) revert NotRateKeeper();
        aprBpsStored = aprBps_;
        emit AprSet(aprBps_);
    }

    /// @inheritdoc IYieldAdapter
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @inheritdoc IYieldAdapter
    /// @dev Exact redeemable underlying for this adapter's vault shares.
    function totalAssets() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /// @inheritdoc IYieldAdapter
    function aprBps() external view returns (uint256) {
        return aprBpsStored;
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Pulls `amount`, approves the vault, deposits for shares to this adapter.
    function deposit(uint256 amount) external onlyOwner {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.forceApprove(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Caps to available, withdraws exactly `amount` of underlying to `to`.
    function withdraw(uint256 amount, address to) external onlyOwner returns (uint256 withdrawn) {
        uint256 avail = totalAssets();
        if (amount > avail) amount = avail;
        if (amount == 0) return 0;
        vault.withdraw(amount, to, address(this));
        return amount;
    }
}

/// @title Lista4626Adapter
/// @notice Lista DAO yield adapter. Lista's modern interest-bearing vaults implement ERC-4626, so this is
///         a thin named wrapper over {ERC4626YieldAdapter}.
/// @dev TODO(integration): confirm the target Lista vault is ERC-4626 and pass its address. If Lista's
///      lending core (Moolah/peer-to-peer markets) is used instead, a dedicated adapter is required.
contract Lista4626Adapter is ERC4626YieldAdapter {
    constructor(address owner_, IERC4626 vault_, address rateKeeper_, uint256 initialAprBps_)
        ERC4626YieldAdapter(owner_, vault_, rateKeeper_, initialAprBps_)
    { }
}
