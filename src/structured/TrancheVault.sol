// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { ControlledToken } from "./ControlledToken.sol";

/// @title TrancheVault
/// @notice Splits a base portfolio's risk/return into Senior (capped, protected, first claim) and
///         Junior (leveraged, residual, first-loss) tranches with a fixed term.
/// @dev Deposits are deployed into the base portfolio. At settlement the proceeds run through a
///      waterfall: Senior is paid up to its capped claim first; Junior takes the residual (and the
///      first loss). A senior coverage ratio is enforced at activation. Settlement is in-kind (tranche
///      tokens redeem portfolio shares), so the vault never force-sells.
contract TrancheVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TRANCHE_ADMIN = keccak256("TRANCHE_ADMIN");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    enum Phase {
        Open,
        Active,
        Settled
    }

    /// @notice Base portfolio receiving deposits.
    IPortfolio public immutable portfolio;
    /// @notice Quote/deposit asset.
    IERC20 public immutable quote;
    /// @notice Portfolio share token held as backing.
    IERC20 public immutable shareToken;
    /// @notice Senior tranche token.
    ControlledToken public immutable senior;
    /// @notice Junior tranche token.
    ControlledToken public immutable junior;

    /// @notice Maturity timestamp.
    uint256 public immutable maturity;
    /// @notice Senior capped coupon (bps) added to principal as the senior claim.
    uint16 public immutable seniorCouponBps;
    /// @notice Max senior share of total principal at activation (bps) — the coverage ratio.
    uint16 public immutable maxSeniorRatioBps;

    Phase public phase;
    uint256 public seniorPrincipal; // value units (18-dec)
    uint256 public juniorPrincipal;

    // Settlement results
    uint256 public seniorSharesPool;
    uint256 public juniorSharesPool;
    uint256 public seniorSupplyAtSettle;
    uint256 public juniorSupplyAtSettle;

    event DepositedSenior(address indexed user, uint256 quoteIn, uint256 value);
    event DepositedJunior(address indexed user, uint256 quoteIn, uint256 value);
    event Activated(uint256 seniorPrincipal, uint256 juniorPrincipal);
    event Settled(uint256 proceeds, uint256 seniorValue, uint256 juniorValue);
    event RedeemedSenior(address indexed user, uint256 amount, uint256 shares);
    event RedeemedJunior(address indexed user, uint256 amount, uint256 shares);

    error WrongPhase();
    error ZeroAmount();
    error CoverageBreached();
    error NotMatured();

    constructor(
        address admin,
        IPortfolio _portfolio,
        uint256 _maturity,
        uint16 _seniorCouponBps,
        uint16 _maxSeniorRatioBps
    ) {
        if (_maturity <= block.timestamp || _maxSeniorRatioBps > BPS) revert ZeroAmount();
        portfolio = _portfolio;
        quote = IERC20(_portfolio.quoteAsset());
        shareToken = IERC20(_portfolio.shareToken());
        maturity = _maturity;
        seniorCouponBps = _seniorCouponBps;
        maxSeniorRatioBps = _maxSeniorRatioBps;
        senior = new ControlledToken("Stratum Senior", "SR", address(this), false);
        junior = new ControlledToken("Stratum Junior", "JR", address(this), false);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TRANCHE_ADMIN, admin);
    }

    /// @notice Deposit into the Senior tranche.
    /// @dev SECURITY: nonReentrant, Open phase. Deploys capital into the base portfolio.
    function depositSenior(uint256 quoteAmount, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 value)
    {
        value = _deposit(quoteAmount, minShares, deadline);
        seniorPrincipal += value;
        senior.mint(msg.sender, value);
        emit DepositedSenior(msg.sender, quoteAmount, value);
    }

    /// @notice Deposit into the Junior tranche (first-loss).
    /// @dev SECURITY: nonReentrant, Open phase.
    function depositJunior(uint256 quoteAmount, uint256 minShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 value)
    {
        value = _deposit(quoteAmount, minShares, deadline);
        juniorPrincipal += value;
        junior.mint(msg.sender, value);
        emit DepositedJunior(msg.sender, quoteAmount, value);
    }

    function _deposit(uint256 quoteAmount, uint256 minShares, uint256 deadline) internal returns (uint256 value) {
        if (phase != Phase.Open) revert WrongPhase();
        if (quoteAmount == 0) revert ZeroAmount();
        quote.safeTransferFrom(msg.sender, address(this), quoteAmount);
        quote.forceApprove(address(portfolio), quoteAmount);
        uint256 shares = portfolio.mint(quoteAmount, minShares, deadline);
        value = (shares * portfolio.navPerShare()) / WAD;
    }

    /// @notice Lock deposits and enforce the senior coverage ratio.
    /// @dev SECURITY: TRANCHE_ADMIN only. Senior principal must be <= maxSeniorRatio of total.
    function activate() external onlyRole(TRANCHE_ADMIN) {
        if (phase != Phase.Open) revert WrongPhase();
        uint256 total = seniorPrincipal + juniorPrincipal;
        if (total == 0) revert ZeroAmount();
        if (seniorPrincipal * BPS > total * maxSeniorRatioBps) revert CoverageBreached();
        phase = Phase.Active;
        emit Activated(seniorPrincipal, juniorPrincipal);
    }

    /// @notice Settle at maturity: run the waterfall and fix per-tranche share pools.
    /// @dev SECURITY: nonReentrant, Active phase, post-maturity. Senior paid first up to its capped
    ///      claim; Junior takes the residual. In-kind: tranche tokens then redeem portfolio shares.
    function settle() external nonReentrant {
        if (phase != Phase.Active) revert WrongPhase();
        if (block.timestamp < maturity) revert NotMatured();

        uint256 totalShares = shareToken.balanceOf(address(this));
        uint256 nps = portfolio.navPerShare();
        uint256 proceeds = (totalShares * nps) / WAD;

        uint256 seniorClaim = (seniorPrincipal * (BPS + seniorCouponBps)) / BPS;
        uint256 seniorValue = proceeds < seniorClaim ? proceeds : seniorClaim;
        uint256 juniorValue = proceeds - seniorValue;

        seniorSharesPool = proceeds == 0 ? 0 : (totalShares * seniorValue) / proceeds;
        juniorSharesPool = totalShares - seniorSharesPool;
        seniorSupplyAtSettle = senior.totalSupply();
        juniorSupplyAtSettle = junior.totalSupply();

        phase = Phase.Settled;
        emit Settled(proceeds, seniorValue, juniorValue);
    }

    /// @notice Redeem Senior tranche tokens for portfolio shares post-settlement.
    /// @dev SECURITY: nonReentrant, Settled phase.
    function redeemSenior(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (phase != Phase.Settled) revert WrongPhase();
        if (amount == 0) revert ZeroAmount();
        shares = seniorSupplyAtSettle == 0 ? 0 : (seniorSharesPool * amount) / seniorSupplyAtSettle;
        senior.burn(msg.sender, amount);
        if (shares > 0) shareToken.safeTransfer(msg.sender, shares);
        emit RedeemedSenior(msg.sender, amount, shares);
    }

    /// @notice Redeem Junior tranche tokens for portfolio shares post-settlement.
    /// @dev SECURITY: nonReentrant, Settled phase.
    function redeemJunior(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (phase != Phase.Settled) revert WrongPhase();
        if (amount == 0) revert ZeroAmount();
        shares = juniorSupplyAtSettle == 0 ? 0 : (juniorSharesPool * amount) / juniorSupplyAtSettle;
        junior.burn(msg.sender, amount);
        if (shares > 0) shareToken.safeTransfer(msg.sender, shares);
        emit RedeemedJunior(msg.sender, amount, shares);
    }

    /// @notice Senior's capped claim value at current principal.
    function seniorClaim() external view returns (uint256) {
        return (seniorPrincipal * (BPS + seniorCouponBps)) / BPS;
    }
}
