// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IYieldAdapter } from "../interfaces/IYieldAdapter.sol";
import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";

/// @title MoneyMarketYieldAdapter
/// @notice Adapts a Venus/Lista-style money market to the IYieldAdapter interface.
/// @dev Owned by the YieldRouter (sole depositor). Holds no idle funds — everything is supplied to the
///      market and redeemed on withdraw. Concrete `VenusYieldAdapter`/`ListaYieldAdapter` only differ
///      in which market they wrap. TODO(integration): point at the real Venus vToken / Lista market.
abstract contract MoneyMarketYieldAdapter is IYieldAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The wrapped money market.
    IMoneyMarket public immutable market;
    /// @notice The underlying asset.
    IERC20 public immutable underlying;

    error AssetMismatch();

    /// @param owner_ The YieldRouter.
    /// @param market_ The money market to wrap.
    constructor(address owner_, IMoneyMarket market_) Ownable(owner_) {
        market = market_;
        underlying = IERC20(market_.underlying());
    }

    /// @inheritdoc IYieldAdapter
    function asset() external view returns (address) {
        return address(underlying);
    }

    /// @inheritdoc IYieldAdapter
    function totalAssets() public view returns (uint256) {
        return market.balanceOfUnderlying(address(this));
    }

    /// @inheritdoc IYieldAdapter
    function aprBps() external view returns (uint256) {
        return market.supplyRatePerYearBps();
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Pulls `amount` then supplies it; CEI — external pull/supply, no callbacks.
    function deposit(uint256 amount) external onlyOwner {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.forceApprove(address(market), amount);
        market.supply(amount);
    }

    /// @inheritdoc IYieldAdapter
    /// @dev SECURITY: owner-only. Redeems from the market then forwards to `to`. Caps to available.
    function withdraw(uint256 amount, address to) external onlyOwner returns (uint256 withdrawn) {
        uint256 avail = totalAssets();
        if (amount > avail) amount = avail;
        if (amount == 0) return 0;
        market.redeemUnderlying(amount);
        underlying.safeTransfer(to, amount);
        return amount;
    }
}

/// @title VenusYieldAdapter
/// @notice Yield adapter targeting the Venus money market.
contract VenusYieldAdapter is MoneyMarketYieldAdapter {
    constructor(address owner_, IMoneyMarket market_) MoneyMarketYieldAdapter(owner_, market_) { }
}

/// @title ListaYieldAdapter
/// @notice Yield adapter targeting the Lista money market.
contract ListaYieldAdapter is MoneyMarketYieldAdapter {
    constructor(address owner_, IMoneyMarket market_) MoneyMarketYieldAdapter(owner_, market_) { }
}
