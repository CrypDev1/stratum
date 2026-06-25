// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../interfaces/ISwapRouter.sol";

/// @title LeverageModule
/// @notice One-click looping leverage on a Portfolio token: deposit margin → borrow stable → buy more
///         shares, up to a target leverage and a hard cap, with health-factor checks off the L0 oracle.
/// @dev Isolated margin: each position is independent. Borrowed stable comes from this module's reserve
///      (the lent principal returns on repay). Liquidations are gated by `DepegMonitor.isTradingSafe`
///      over every component, so positions can NOT be liquidated while the circuit-breaker is tripped.
contract LeverageModule is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role for risk-parameter and reserve management.
    bytes32 public constant RISK_ADMIN = keccak256("RISK_ADMIN");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    /// @notice The portfolio whose shares are used as collateral.
    IPortfolio public immutable portfolio;
    /// @notice Share token (collateral).
    IERC20 public immutable shareToken;
    /// @notice Borrow/stable asset (the portfolio's quote).
    IERC20 public immutable stable;
    /// @notice L0 oracle (health-factor pricing).
    INAVOracle public immutable nav;
    /// @notice L0 depeg breaker (liquidation gate).
    IDepegMonitor public immutable depeg;
    /// @notice DEX router (deleverage sells).
    ISwapRouter public immutable router;

    /// @notice Hard cap on leverage (1e18 = 1x).
    uint256 public maxLeverage = 5e18;
    /// @notice Liquidation threshold (bps of collateral value).
    uint16 public liqThresholdBps = 8_000;
    /// @notice Minimum health factor required to open/modify (1e18 = exactly at threshold).
    uint256 public minHealthFactor = 1.1e18;
    /// @notice Liquidation bonus (bps) paid to liquidators.
    uint16 public liquidationBonusBps = 500;
    /// @notice Annualized borrow rate on debt (bps) — the leverage spread.
    uint256 public borrowRateBps;
    /// @notice Per-swap slippage tolerance for deleverage sells (bps).
    uint16 public maxSlippageBps = 100;

    struct Position {
        address owner;
        uint256 collateralShares;
        uint256 debt; // stable units (USD-pegged)
        uint256 lastAccrual;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;

    event PositionOpened(uint256 indexed id, address indexed owner, uint256 margin, uint256 debt, uint256 shares);
    event PositionClosed(uint256 indexed id);
    event Deleveraged(uint256 indexed id, uint256 sharesSold, uint256 debtRepaid);
    event Repaid(uint256 indexed id, uint256 amount);
    event Liquidated(uint256 indexed id, address indexed liquidator, uint256 repaid, uint256 seizedShares);
    event ReserveFunded(uint256 amount);
    event RiskParamsSet();

    error LeverageTooHigh();
    error Unhealthy();
    error NotOwner();
    error NoReserve();
    error NotLiquidatable();
    error TradingHalted();
    error InvalidParam();
    error DeadlinePassed();

    /// @param admin Risk admin.
    /// @param _portfolio Collateral portfolio.
    /// @param _nav L0 oracle.
    /// @param _depeg L0 depeg breaker.
    /// @param _router DEX router.
    constructor(address admin, IPortfolio _portfolio, INAVOracle _nav, IDepegMonitor _depeg, ISwapRouter _router) {
        portfolio = _portfolio;
        shareToken = IERC20(_portfolio.shareToken());
        stable = IERC20(_portfolio.quoteAsset());
        nav = _nav;
        depeg = _depeg;
        router = _router;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN, admin);
    }

    // --------------------------------------------------------------------- //
    //                                 Admin                                 //
    // --------------------------------------------------------------------- //

    /// @notice Fund the borrow reserve with stable.
    /// @dev SECURITY: anyone may add liquidity; it backs borrows and is returned on repay.
    function fundReserve(uint256 amount) external nonReentrant {
        stable.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(amount);
    }

    /// @notice Set risk parameters.
    /// @dev SECURITY: RISK_ADMIN only. Bounds enforced so guardrails stay meaningful.
    function setRiskParams(
        uint256 _maxLeverage,
        uint16 _liqThresholdBps,
        uint256 _minHealthFactor,
        uint16 _liquidationBonusBps,
        uint256 _borrowRateBps,
        uint16 _maxSlippageBps
    ) external onlyRole(RISK_ADMIN) {
        if (_maxLeverage < WAD || _liqThresholdBps == 0 || _liqThresholdBps > BPS || _minHealthFactor < WAD) {
            revert InvalidParam();
        }
        maxLeverage = _maxLeverage;
        liqThresholdBps = _liqThresholdBps;
        minHealthFactor = _minHealthFactor;
        liquidationBonusBps = _liquidationBonusBps;
        borrowRateBps = _borrowRateBps;
        maxSlippageBps = _maxSlippageBps;
        emit RiskParamsSet();
    }

    /// @notice Stable available to borrow.
    function availableReserve() public view returns (uint256) {
        return stable.balanceOf(address(this));
    }

    // --------------------------------------------------------------------- //
    //                               Positions                               //
    // --------------------------------------------------------------------- //

    /// @notice Open a leveraged position: deposit `margin` stable, lever to `leverageX`.
    /// @dev SECURITY: nonReentrant. Borrows (leverageX-1)*margin from the reserve, mints shares with
    ///      margin+borrow, and requires the resulting health factor >= minHealthFactor and leverage <= cap.
    /// @param margin Stable margin deposited by the caller.
    /// @param leverageX Target leverage (1e18 = 1x).
    /// @param minSharesOut Slippage bound on the underlying portfolio mint.
    /// @param deadline Swap/mint deadline.
    /// @return id The new position id.
    function open(uint256 margin, uint256 leverageX, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (margin == 0 || leverageX < WAD) revert InvalidParam();
        if (leverageX > maxLeverage) revert LeverageTooHigh();

        uint256 borrow = (margin * (leverageX - WAD)) / WAD;
        if (borrow > availableReserve()) revert NoReserve();

        stable.safeTransferFrom(msg.sender, address(this), margin);
        uint256 total = margin + borrow;

        stable.forceApprove(address(portfolio), total);
        uint256 shares = portfolio.mint(total, minSharesOut, deadline);

        id = nextId++;
        positions[id] =
            Position({ owner: msg.sender, collateralShares: shares, debt: borrow, lastAccrual: block.timestamp });

        if (_healthFactor(shares, borrow) < minHealthFactor) revert Unhealthy();
        emit PositionOpened(id, msg.sender, margin, borrow, shares);
    }

    /// @notice Add margin and borrow to an existing position at `leverageX`, minting more collateral.
    /// @dev SECURITY: nonReentrant, owner-only. Same guardrails as `open`. Used by LeveragedIndex to
    ///      grow a shared position on each deposit.
    function increase(uint256 id, uint256 margin, uint256 leverageX, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        if (margin == 0 || leverageX < WAD || leverageX > maxLeverage) revert InvalidParam();
        _accrue(pos);

        uint256 borrow = (margin * (leverageX - WAD)) / WAD;
        if (borrow > availableReserve()) revert NoReserve();
        stable.safeTransferFrom(msg.sender, address(this), margin);
        uint256 total = margin + borrow;
        stable.forceApprove(address(portfolio), total);
        shares = portfolio.mint(total, minSharesOut, deadline);

        pos.collateralShares += shares;
        pos.debt += borrow;
        if (_healthFactor(pos.collateralShares, pos.debt) < minHealthFactor) revert Unhealthy();
        emit PositionOpened(id, msg.sender, margin, borrow, shares);
    }

    /// @notice Borrow more against an existing position (no new margin) and buy more collateral.
    /// @dev SECURITY: nonReentrant, owner-only. Raises leverage; must keep HF >= minHealthFactor and
    ///      leverage <= cap. Used by LeveragedIndex to rebalance leverage up toward target.
    function borrowMore(uint256 id, uint256 borrowAmount, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        if (borrowAmount == 0) revert InvalidParam();
        if (borrowAmount > availableReserve()) revert NoReserve();
        _accrue(pos);

        stable.forceApprove(address(portfolio), borrowAmount);
        shares = portfolio.mint(borrowAmount, minSharesOut, deadline);
        pos.collateralShares += shares;
        pos.debt += borrowAmount;
        if (_healthFactor(pos.collateralShares, pos.debt) < minHealthFactor) revert Unhealthy();
        emit PositionOpened(id, msg.sender, 0, borrowAmount, shares);
    }

    /// @notice Repay stable to reduce a position's debt (raises health factor).
    /// @dev SECURITY: nonReentrant. Anyone may repay on behalf of a position.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        Position storage pos = positions[id];
        if (pos.owner == address(0)) revert NotOwner();
        _accrue(pos);
        if (amount > pos.debt) amount = pos.debt;
        stable.safeTransferFrom(msg.sender, address(this), amount);
        pos.debt -= amount;
        emit Repaid(id, amount);
    }

    /// @notice Close a position: owner repays remaining debt and receives all collateral shares.
    /// @dev SECURITY: nonReentrant, owner-only. CEI: pulls repayment, deletes position, transfers shares.
    function close(uint256 id) external nonReentrant {
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        _accrue(pos);
        uint256 debt = pos.debt;
        uint256 shares = pos.collateralShares;
        delete positions[id];
        if (debt > 0) stable.safeTransferFrom(msg.sender, address(this), debt);
        if (shares > 0) shareToken.safeTransfer(msg.sender, shares);
        emit PositionClosed(id);
    }

    /// @notice Deleverage by selling `sharesToSell` collateral into stable and repaying debt.
    /// @dev SECURITY: nonReentrant, owner-only. Redeems shares in-kind then swaps each component to
    ///      stable (slippage + deadline bounded); proceeds repay up to `maxRepay` of debt (0 = all).
    ///      Surplus stable returns to the owner. Lowers leverage without new funds; pro-rata when the
    ///      caller caps repayment to its share of the debt.
    function deleverage(uint256 id, uint256 sharesToSell, uint256 maxRepay, uint256 deadline)
        external
        nonReentrant
        returns (uint256 surplus)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        Position storage pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        _accrue(pos);
        if (sharesToSell > pos.collateralShares) sharesToSell = pos.collateralShares;

        pos.collateralShares -= sharesToSell;
        uint256 stableOut = _sellShares(sharesToSell, deadline);

        uint256 repayAmt = stableOut > pos.debt ? pos.debt : stableOut;
        if (maxRepay != 0 && repayAmt > maxRepay) repayAmt = maxRepay;
        pos.debt -= repayAmt;
        surplus = stableOut - repayAmt;
        if (surplus > 0) stable.safeTransfer(pos.owner, surplus);
        emit Deleveraged(id, sharesToSell, repayAmt);
    }

    /// @notice Liquidate an unhealthy position by repaying its debt for discounted collateral.
    /// @dev SECURITY: nonReentrant. Allowed ONLY when health factor < 1e18 AND every component is
    ///      `isTradingSafe` (the circuit-breaker must be clear) — no liquidation during a halt/depeg.
    /// @param id Position id.
    /// @param repayAmount Stable amount the liquidator repays (capped to debt).
    function liquidate(uint256 id, uint256 repayAmount) external nonReentrant {
        Position storage pos = positions[id];
        if (pos.owner == address(0)) revert NotOwner();
        _accrue(pos);

        if (_healthFactor(pos.collateralShares, pos.debt) >= WAD) revert NotLiquidatable();
        _requireTradingSafe();

        if (repayAmount > pos.debt) repayAmount = pos.debt;
        if (repayAmount == 0) revert NotLiquidatable();

        uint256 nps = portfolio.navPerShare();
        // collateral value seized = repay * (1 + bonus); shares = value / navPerShare
        uint256 seizeValue = (repayAmount * (BPS + liquidationBonusBps)) / BPS;
        uint256 seizeShares = (seizeValue * WAD) / nps;
        if (seizeShares > pos.collateralShares) seizeShares = pos.collateralShares;

        stable.safeTransferFrom(msg.sender, address(this), repayAmount);
        pos.debt -= repayAmount;
        pos.collateralShares -= seizeShares;
        shareToken.safeTransfer(msg.sender, seizeShares);
        emit Liquidated(id, msg.sender, repayAmount, seizeShares);
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //

    /// @notice Health factor of a position (1e18 = at liquidation threshold).
    function healthFactor(uint256 id) external view returns (uint256) {
        Position storage pos = positions[id];
        uint256 debt = pos.debt + _pendingInterest(pos);
        return _healthFactor(pos.collateralShares, debt);
    }

    /// @notice Current leverage of a position (1e18 = 1x).
    function leverage(uint256 id) external view returns (uint256) {
        Position storage pos = positions[id];
        uint256 collValue = _collateralValue(pos.collateralShares);
        uint256 debt = pos.debt + _pendingInterest(pos);
        if (collValue <= debt) return type(uint256).max;
        return (collValue * WAD) / (collValue - debt);
    }

    function _healthFactor(uint256 shares, uint256 debt) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collValue = _collateralValue(shares);
        return (collValue * liqThresholdBps * WAD) / (debt * BPS);
    }

    function _collateralValue(uint256 shares) internal view returns (uint256) {
        return (shares * portfolio.navPerShare()) / WAD;
    }

    function _pendingInterest(Position storage pos) internal view returns (uint256) {
        if (borrowRateBps == 0 || pos.debt == 0) return 0;
        uint256 elapsed = block.timestamp - pos.lastAccrual;
        return (pos.debt * borrowRateBps * elapsed) / (BPS * YEAR);
    }

    function _accrue(Position storage pos) internal {
        uint256 interest = _pendingInterest(pos);
        if (interest > 0) pos.debt += interest;
        pos.lastAccrual = block.timestamp;
    }

    function _requireTradingSafe() internal view {
        IPortfolio.Component[] memory comps = portfolio.components();
        for (uint256 i; i < comps.length; ++i) {
            if (!depeg.isTradingSafe(comps[i].asset)) revert TradingHalted();
        }
    }

    /// @dev Redeem `shares` in-kind and swap each returned component into stable.
    function _sellShares(uint256 shares, uint256 deadline) internal returns (uint256 stableOut) {
        if (shares == 0) return 0;
        (address[] memory assets, uint256[] memory amounts) = portfolio.redeem(shares);
        for (uint256 i; i < assets.length; ++i) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            if (assets[i] == address(stable)) {
                stableOut += amt;
                continue;
            }
            uint256 expected = router.quote(assets[i], address(stable), amt);
            uint256 minOut = (expected * (BPS - maxSlippageBps)) / BPS;
            IERC20(assets[i]).forceApprove(address(router), amt);
            stableOut += router.swapExactIn(assets[i], address(stable), amt, minOut, deadline, address(this));
        }
    }
}
