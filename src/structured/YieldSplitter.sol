// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { ControlledToken, ITransferHook } from "./ControlledToken.sol";

/// @title YieldSplitter
/// @notice Splits a yield-bearing Portfolio token into Principal (PT) and Yield (YT) tokens with a
///         maturity. Burn PT 1:1 for principal at maturity; YT accrues the portfolio's yield until then.
/// @dev Value-denominated (18-dec USD via `navPerShare`). Yield is distributed to YT holders with a
///      per-token accumulator (settled on transfer via the ControlledToken hook). Assumes the wrapped
///      token's `navPerShare` is non-decreasing (a yield-bearing wrapper), so PT principal stays backed.
///      INVARIANT: underlyingValue == ptValue + ytValue (PT+YT always reconstructs the wrapped asset).
contract YieldSplitter is ReentrancyGuard, ITransferHook {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    /// @notice The yield-bearing portfolio being split.
    IPortfolio public immutable portfolio;
    /// @notice The wrapped share token held as backing.
    IERC20 public immutable wrapped;
    /// @notice Maturity timestamp; PT is redeemable 1:1 from here.
    uint256 public immutable maturity;

    /// @notice Principal token.
    ControlledToken public immutable pt;
    /// @notice Yield token.
    ControlledToken public immutable yt;

    /// @notice Outstanding principal (value units, 18-dec USD).
    uint256 public totalPrincipal;
    /// @notice Value already accounted (principal + yield pushed into the accumulator).
    uint256 public accountedValue;
    /// @notice Cumulative yield value per YT (1e18-scaled).
    uint256 public yieldPerToken;

    mapping(address => uint256) public userCheckpoint;
    mapping(address => uint256) public accruedYield; // settled, unclaimed (value units)

    event Split(address indexed user, uint256 shares, uint256 value);
    event Combined(address indexed user, uint256 value, uint256 shares);
    event PrincipalRedeemed(address indexed user, uint256 value, uint256 shares);
    event YieldClaimed(address indexed user, uint256 value, uint256 shares);

    error NotMatured();
    error AlreadyMatured();
    error ZeroAmount();
    error OnlyYieldToken();

    /// @param _portfolio The yield-bearing portfolio.
    /// @param _maturity Maturity timestamp (must be in the future).
    /// @param ptName PT name.
    /// @param ytName YT name.
    constructor(IPortfolio _portfolio, uint256 _maturity, string memory ptName, string memory ytName) {
        if (_maturity <= block.timestamp) revert AlreadyMatured();
        portfolio = _portfolio;
        wrapped = IERC20(_portfolio.shareToken());
        maturity = _maturity;
        pt = new ControlledToken(ptName, "PT", address(this), false);
        yt = new ControlledToken(ytName, "YT", address(this), true);
    }

    /// @notice Current navPerShare of the wrapped portfolio (the accrual index).
    function index() public view returns (uint256) {
        return portfolio.navPerShare();
    }

    /// @notice Total USD value (18-dec) of wrapped shares held.
    function underlyingValue() public view returns (uint256) {
        return (wrapped.balanceOf(address(this)) * index()) / WAD;
    }

    /// @notice Value backing PT (the outstanding principal).
    function ptValue() public view returns (uint256) {
        return totalPrincipal;
    }

    /// @notice Value backing YT (all yield not yet withdrawn).
    function ytValue() public view returns (uint256) {
        uint256 u = underlyingValue();
        return u > totalPrincipal ? u - totalPrincipal : 0;
    }

    /// @notice Split `shares` of the wrapped token into equal PT and YT.
    /// @dev SECURITY: nonReentrant, pre-maturity. CEI: accrue → pull shares → settle → mint.
    function split(uint256 shares) external nonReentrant returns (uint256 value) {
        if (block.timestamp >= maturity) revert AlreadyMatured();
        if (shares == 0) revert ZeroAmount();
        _accrue();
        uint256 i = index();
        value = (shares * i) / WAD;

        wrapped.safeTransferFrom(msg.sender, address(this), shares);
        _settle(msg.sender);
        pt.mint(msg.sender, value);
        yt.mint(msg.sender, value);
        totalPrincipal += value;
        accountedValue += value;
        emit Split(msg.sender, shares, value);
    }

    /// @notice Recombine equal PT and YT back into the wrapped token (pre-maturity).
    /// @dev SECURITY: nonReentrant. Burns `value` of each; returns principal-worth shares. Accrued YT
    ///      yield is preserved (claim separately).
    function combine(uint256 value) external nonReentrant returns (uint256 shares) {
        if (value == 0) revert ZeroAmount();
        _accrue();
        _settle(msg.sender);
        pt.burn(msg.sender, value);
        yt.burn(msg.sender, value);
        uint256 i = index();
        shares = (value * WAD) / i;
        totalPrincipal -= value;
        accountedValue -= value;
        wrapped.safeTransfer(msg.sender, shares);
        emit Combined(msg.sender, value, shares);
    }

    /// @notice Redeem PT 1:1 for principal-worth shares at/after maturity.
    /// @dev SECURITY: nonReentrant, post-maturity only.
    function redeemPrincipal(uint256 value) external nonReentrant returns (uint256 shares) {
        if (block.timestamp < maturity) revert NotMatured();
        if (value == 0) revert ZeroAmount();
        _accrue();
        pt.burn(msg.sender, value);
        uint256 i = index();
        shares = (value * WAD) / i;
        totalPrincipal -= value;
        accountedValue -= value;
        wrapped.safeTransfer(msg.sender, shares);
        emit PrincipalRedeemed(msg.sender, value, shares);
    }

    /// @notice Claim accrued yield as wrapped shares.
    /// @dev SECURITY: nonReentrant. Settles the caller then pays out their accrued yield value in shares.
    function claimYield() external nonReentrant returns (uint256 shares) {
        _accrue();
        _settle(msg.sender);
        uint256 value = accruedYield[msg.sender];
        if (value == 0) return 0;
        accruedYield[msg.sender] = 0;
        uint256 i = index();
        shares = (value * WAD) / i;
        accountedValue -= value;
        wrapped.safeTransfer(msg.sender, shares);
        emit YieldClaimed(msg.sender, value, shares);
    }

    /// @notice Pending (unsettled + settled) yield value for `user`.
    function pendingYield(address user) external view returns (uint256) {
        uint256 ypt = yieldPerToken;
        uint256 supply = yt.totalSupply();
        uint256 pending = underlyingValue();
        pending = pending > accountedValue ? pending - accountedValue : 0;
        if (supply > 0 && pending > 0) ypt += (pending * WAD) / supply;
        uint256 bal = yt.balanceOf(user);
        return accruedYield[user] + (bal * (ypt - userCheckpoint[user])) / WAD;
    }

    /// @inheritdoc ITransferHook
    /// @dev Settles both parties before a YT transfer so yield follows the pre-transfer balances.
    function onTokenTransfer(address token, address from, address to) external {
        if (msg.sender != address(yt)) revert OnlyYieldToken();
        if (token != address(yt)) revert OnlyYieldToken();
        _accrue();
        if (from != address(0)) _settle(from);
        if (to != address(0)) _settle(to);
    }

    /// @dev Crystallize pending yield into the per-token accumulator.
    function _accrue() internal {
        uint256 u = underlyingValue();
        if (u <= accountedValue) return;
        uint256 pending = u - accountedValue;
        uint256 supply = yt.totalSupply();
        if (supply == 0) return; // no YT holders to credit; stays as extra backing
        uint256 delta = (pending * WAD) / supply;
        if (delta == 0) return;
        yieldPerToken += delta;
        accountedValue += (delta * supply) / WAD;
    }

    /// @dev Settle `user`'s accrued yield against the current accumulator.
    function _settle(address user) internal {
        uint256 bal = yt.balanceOf(user);
        uint256 cp = userCheckpoint[user];
        if (yieldPerToken > cp && bal > 0) {
            accruedYield[user] += (bal * (yieldPerToken - cp)) / WAD;
        }
        userCheckpoint[user] = yieldPerToken;
    }
}
