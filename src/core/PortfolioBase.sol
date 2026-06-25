// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IProofOfCollateral } from "../interfaces/IProofOfCollateral.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../interfaces/ISwapRouter.sol";
import { PortfolioToken } from "./PortfolioToken.sol";
import { PriceLib } from "../libraries/PriceLib.sol";

/// @title PortfolioBase
/// @notice Shared accounting engine for Index and Vault portfolios.
/// @dev Holds a basket of components, computes NAV via the L0 oracle, and mints/redeems NAV-fairly so
///      external arbitrage keeps the share token pegged to underlying value. Cloneable (Initializable).
///      Redeem is in-kind and oracle-independent so users can always exit, even if the oracle is stale.
abstract contract PortfolioBase is IPortfolio, Initializable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using PriceLib for uint256;

    /// @notice Role that can pause minting and manage portfolio params.
    bytes32 public constant PORTFOLIO_ADMIN = keccak256("PORTFOLIO_ADMIN");

    /// @notice Maximum number of components (bounds all loops).
    uint256 public constant MAX_COMPONENTS = 32;
    uint256 internal constant BPS = 10_000;

    /// @notice L0 fair-value oracle.
    INAVOracle public nav;
    /// @notice L0 proof-of-collateral.
    IProofOfCollateral public poc;
    /// @notice L0 depeg circuit-breaker.
    IDepegMonitor public depeg;
    /// @notice DEX router adapter.
    ISwapRouter public router;
    /// @notice Quote/deposit asset (e.g. USDC).
    IERC20 public quote;
    /// @notice The ERC20 share token.
    PortfolioToken public share;
    /// @notice Per-swap slippage tolerance (bps).
    uint16 public maxSlippageBps;

    Component[] internal _components;
    mapping(address => bool) internal _isComponent;

    /// @notice Parameters for initialization (clone-friendly).
    struct InitParams {
        address nav;
        address poc;
        address depeg;
        address router;
        address quoteAsset;
        string name;
        string symbol;
        Component[] components;
        uint16 maxSlippageBps;
        address admin;
    }

    /// @notice Emitted when shares are minted against a quote deposit.
    event Minted(address indexed user, uint256 quoteIn, uint256 sharesOut, uint256 navAfter);
    /// @notice Emitted when shares are redeemed in kind.
    event Redeemed(address indexed user, uint256 sharesIn);

    error DeadlinePassed();
    error ZeroAmount();
    error SlippageExceeded();
    error TradingUnsafe(address asset);
    error PriceUnusable(address asset);
    error InvalidComponents();
    error NotComponent(address asset);

    /// @dev Disable initializers on the implementation so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @dev Shared initializer; derived contracts call this from their own initializer.
    ///      SECURITY: validates the component set (non-empty, unique, non-zero, weights sum to 10_000,
    ///      capped length) so NAV math and loops are always well-formed.
    function __PortfolioBase_init(InitParams calldata p) internal onlyInitializing {
        if (p.components.length == 0 || p.components.length > MAX_COMPONENTS) revert InvalidComponents();
        nav = INAVOracle(p.nav);
        poc = IProofOfCollateral(p.poc);
        depeg = IDepegMonitor(p.depeg);
        router = ISwapRouter(p.router);
        quote = IERC20(p.quoteAsset);
        maxSlippageBps = p.maxSlippageBps;

        uint256 sum;
        for (uint256 i; i < p.components.length; ++i) {
            Component calldata c = p.components[i];
            if (c.asset == address(0) || c.weightBps == 0 || _isComponent[c.asset]) revert InvalidComponents();
            _isComponent[c.asset] = true;
            _components.push(c);
            sum += c.weightBps;
        }
        if (sum != BPS) revert InvalidComponents();

        share = new PortfolioToken(p.name, p.symbol, address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        _grantRole(PORTFOLIO_ADMIN, p.admin);
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //

    /// @inheritdoc IPortfolio
    function shareToken() external view returns (address) {
        return address(share);
    }

    /// @inheritdoc IPortfolio
    function quoteAsset() external view returns (address) {
        return address(quote);
    }

    /// @notice The portfolio's component list.
    function components() external view returns (Component[] memory) {
        return _components;
    }

    /// @inheritdoc IPortfolio
    /// @dev SECURITY: reverts if any component price is stale/zero, so NAV is never computed on bad data.
    ///      Idle quote held by the portfolio counts 1:1 as USD (the stable numéraire), so trading a
    ///      component into quote does not spuriously change NAV.
    function totalNAV() public view returns (uint256 total) {
        uint256 len = _components.length;
        for (uint256 i; i < len; ++i) {
            address asset = _components[i].asset;
            if (asset == address(quote)) continue; // counted once below
            total += _assetValue(asset);
        }
        uint256 quoteBal = quote.balanceOf(address(this));
        if (quoteBal > 0) {
            uint8 qdec = IERC20Metadata(address(quote)).decimals();
            total += (quoteBal * 1e18) / (10 ** qdec);
        }
    }

    /// @inheritdoc IPortfolio
    function navPerShare() public view returns (uint256) {
        uint256 supply = share.totalSupply();
        if (supply == 0) return 1e18;
        return (totalNAV() * 1e18) / supply;
    }

    /// @notice USD (18-dec) value of the portfolio's balance of `asset`.
    function _assetValue(address asset) internal view returns (uint256) {
        (uint256 price,, bool isStale) = nav.getPrice(asset);
        if (isStale || price == 0) revert PriceUnusable(asset);
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return 0;
        uint8 dec = IERC20Metadata(asset).decimals();
        return (bal * price) / (10 ** dec);
    }

    // --------------------------------------------------------------------- //
    //                              Mint / Redeem                            //
    // --------------------------------------------------------------------- //

    /// @inheritdoc IPortfolio
    /// @dev SECURITY: nonReentrant + whenNotPaused. NAV-fair: shares = depositValue * supply / navBefore.
    ///      Snapshots navBefore *before* pulling quote, gates every component on the depeg breaker, and
    ///      enforces the caller's `minSharesOut`. Checks-effects-interactions: external swaps precede mint.
    function mint(uint256 quoteAmountIn, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (quoteAmountIn == 0) revert ZeroAmount();

        // Accrue fees on the pre-deposit state so a new depositor never pays a fee on their own capital.
        _preMint();

        uint256 navBefore = totalNAV();
        uint256 supplyBefore = share.totalSupply();

        quote.safeTransferFrom(msg.sender, address(this), quoteAmountIn);
        _allocate(quoteAmountIn, deadline);

        uint256 navAfter = totalNAV();
        uint256 added = navAfter - navBefore;
        if (added == 0) revert ZeroAmount();

        shares = supplyBefore == 0 ? added : (added * supplyBefore) / navBefore;
        if (shares < minSharesOut) revert SlippageExceeded();

        share.mint(msg.sender, shares);
        emit Minted(msg.sender, quoteAmountIn, shares, navAfter);
    }

    /// @inheritdoc IPortfolio
    /// @dev SECURITY: nonReentrant. In-kind and oracle-independent — works even while paused or the
    ///      oracle is stale, guaranteeing users can always exit. Checks-effects-interactions: burn first,
    ///      then transfer pro-rata components.
    function redeem(uint256 shares) external nonReentrant returns (address[] memory assets, uint256[] memory amounts) {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = share.totalSupply();

        // Effects: burn first.
        share.burn(msg.sender, shares);

        uint256 len = _components.length;
        assets = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            address asset = _components[i].asset;
            uint256 bal = IERC20(asset).balanceOf(address(this));
            uint256 amt = (bal * shares) / supply;
            assets[i] = asset;
            amounts[i] = amt;
            if (amt > 0) IERC20(asset).safeTransfer(msg.sender, amt);
        }
        emit Redeemed(msg.sender, shares);
    }

    /// @dev Allocate `quoteAmountIn` across components by target weight, swapping where needed.
    ///      SECURITY: every component gated on `isTradingSafe`; each swap carries a slippage-bounded
    ///      `minAmountOut` derived from the router quote, plus the `deadline`.
    function _allocate(uint256 quoteAmountIn, uint256 deadline) internal {
        uint256 len = _components.length;
        for (uint256 i; i < len; ++i) {
            Component storage c = _components[i];
            if (!depeg.isTradingSafe(c.asset)) revert TradingUnsafe(c.asset);

            uint256 portion = (quoteAmountIn * c.weightBps) / BPS;
            if (portion == 0) continue;
            if (c.asset == address(quote)) continue; // already the right asset

            uint256 expected = router.quote(address(quote), c.asset, portion);
            uint256 minOut = (expected * (BPS - maxSlippageBps)) / BPS;
            quote.forceApprove(address(router), portion);
            router.swapExactIn(address(quote), c.asset, portion, minOut, deadline, address(this));
        }
    }

    /// @dev Hook for derived contracts to accrue fees (dilution) on the pre-deposit state. No-op here.
    function _preMint() internal virtual { }

    // --------------------------------------------------------------------- //
    //                                 Admin                                 //
    // --------------------------------------------------------------------- //

    /// @notice Pause minting (redeem stays open).
    /// @dev SECURITY: PORTFOLIO_ADMIN only.
    function pause() external onlyRole(PORTFOLIO_ADMIN) {
        _pause();
    }

    /// @notice Resume minting.
    function unpause() external onlyRole(PORTFOLIO_ADMIN) {
        _unpause();
    }
}
