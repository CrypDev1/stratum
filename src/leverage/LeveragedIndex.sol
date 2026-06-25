// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { LeverageModule } from "./LeverageModule.sol";

/// @title LeveragedIndex
/// @notice Productized target-leverage index: a single ERC20 token representing a share of one leveraged
///         portfolio position, with leverage rebalanced back toward target as price moves.
/// @dev Net asset = position equity (collateral value − debt). Shares are minted/redeemed pro-rata to
///      equity. Built on a shared LeverageModule position owned by this contract. SECURITY: deposits and
///      withdrawals carry slippage/deadline bounds; rebalancing is bounded by a leverage band.
contract LeveragedIndex is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role for the keeper that maintains target leverage.
    bytes32 public constant KEEPER = keccak256("KEEPER");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    LeverageModule public immutable module;
    IPortfolio public immutable portfolio;
    IERC20 public immutable stable;
    IERC20 public immutable shareToken;

    /// @notice Target leverage (1e18 = 1x).
    uint256 public targetLeverage;
    /// @notice Rebalance band (bps): only rebalance when leverage drifts beyond this.
    uint16 public rebalanceBandBps = 1_000;
    /// @notice The shared LeverageModule position id (0 until first deposit).
    uint256 public positionId;

    event Deposited(address indexed user, uint256 margin, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 stableOut);
    event LeverageRebalanced(uint256 leverageBefore, uint256 leverageAfter);

    error ZeroAmount();
    error SlippageExceeded();
    error InvalidParam();

    constructor(
        string memory name_,
        string memory symbol_,
        address admin,
        LeverageModule module_,
        uint256 targetLeverage_
    ) ERC20(name_, symbol_) {
        if (targetLeverage_ < WAD) revert InvalidParam();
        module = module_;
        portfolio = module_.portfolio();
        stable = module_.stable();
        shareToken = module_.shareToken();
        targetLeverage = targetLeverage_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER, admin);
    }

    /// @notice Deposit `margin` stable; the index levers it to target and mints index tokens pro-rata.
    /// @dev SECURITY: nonReentrant. Mints shares = addedEquity * supply / equityBefore (fair).
    function deposit(uint256 margin, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sharesMinted)
    {
        if (margin == 0) revert ZeroAmount();
        uint256 equityBefore = positionEquity();
        uint256 supplyBefore = totalSupply();

        stable.safeTransferFrom(msg.sender, address(this), margin);
        stable.forceApprove(address(module), margin);

        if (positionId == 0) {
            positionId = module.open(margin, targetLeverage, 0, deadline);
        } else {
            module.increase(positionId, margin, targetLeverage, 0, deadline);
        }

        uint256 equityAfter = positionEquity();
        uint256 added = equityAfter - equityBefore;
        sharesMinted = supplyBefore == 0 ? added : (added * supplyBefore) / equityBefore;
        if (sharesMinted < minSharesOut) revert SlippageExceeded();
        _mint(msg.sender, sharesMinted);
        emit Deposited(msg.sender, margin, sharesMinted);
    }

    /// @notice Burn `shares` index tokens; receive the pro-rata stable equity after deleveraging.
    /// @dev SECURITY: nonReentrant. Sells pro-rata collateral and repays pro-rata debt, keeping the
    ///      residual position's leverage unchanged; surplus equity is returned to the caller.
    function withdraw(uint256 shares, uint256 deadline) external nonReentrant returns (uint256 stableOut) {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        (, uint256 collShares, uint256 debt,) = module.positions(positionId);

        uint256 sharesToSell = (collShares * shares) / supply;
        uint256 maxRepay = (debt * shares) / supply;

        _burn(msg.sender, shares);
        uint256 balBefore = stable.balanceOf(address(this));
        module.deleverage(positionId, sharesToSell, maxRepay, deadline);
        stableOut = stable.balanceOf(address(this)) - balBefore;
        if (stableOut > 0) stable.safeTransfer(msg.sender, stableOut);
        emit Withdrawn(msg.sender, shares, stableOut);
    }

    /// @notice Rebalance leverage back toward target if it has drifted beyond the band.
    /// @dev SECURITY: KEEPER only + nonReentrant. Over target → deleverage; under target → borrow more.
    function rebalanceLeverage(uint256 deadline) external nonReentrant onlyRole(KEEPER) {
        uint256 levBefore = module.leverage(positionId);
        (, uint256 collShares, uint256 debt,) = module.positions(positionId);
        uint256 collValue = (collShares * portfolio.navPerShare()) / WAD;

        uint256 upper = (targetLeverage * (BPS + rebalanceBandBps)) / BPS;
        uint256 lower = (targetLeverage * (BPS - rebalanceBandBps)) / BPS;
        if (levBefore <= upper && levBefore >= lower) return; // within band
        if (collValue <= debt) return; // insolvent; nothing safe to do here

        // At target leverage Lt: collateral C' = Lt * equity, debt D' = C' - equity.
        // Adjustment buys/sells `delta = Lt*equity - C` of collateral (borrowing/repaying the same).
        uint256 equity = collValue - debt;
        uint256 desiredColl = (targetLeverage * equity) / WAD;

        if (desiredColl > collValue) {
            module.borrowMore(positionId, desiredColl - collValue, 0, deadline);
        } else if (collValue > desiredColl) {
            uint256 sell = collValue - desiredColl;
            uint256 sharesToSell = (sell * WAD) / portfolio.navPerShare();
            module.deleverage(positionId, sharesToSell, sell, deadline);
        }
        emit LeverageRebalanced(levBefore, module.leverage(positionId));
    }

    /// @notice Update target leverage.
    /// @dev SECURITY: DEFAULT_ADMIN only.
    function setTargetLeverage(uint256 lev) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lev < WAD) revert InvalidParam();
        targetLeverage = lev;
    }

    /// @notice Current equity (collateral value − debt) of the underlying position.
    function positionEquity() public view returns (uint256) {
        if (positionId == 0) return 0;
        (, uint256 collShares, uint256 debt,) = module.positions(positionId);
        uint256 collValue = (collShares * portfolio.navPerShare()) / WAD;
        return collValue > debt ? collValue - debt : 0;
    }

    /// @notice Index token value (equity per share, 18-dec). 1e18 when supply is zero.
    function equityPerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return (positionEquity() * WAD) / supply;
    }
}
