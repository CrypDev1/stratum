// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStrategy } from "./strategies/IStrategy.sol";

/// @title EarnVault
/// @notice Stratum Earn: a single-asset, non-rebasing ERC-4626 yield vault. Users deposit a base asset and
///         receive share tokens that are a proportional claim on the vault's assets; deposits are routed
///         into ONE pluggable {IStrategy} wrapping a REAL, external, audited on-chain yield venue (Venus,
///         Lista, …). Yield accrues into NAV so the share price rises — no rebasing, no minted-token yield.
/// @dev Cloneable (Initializable): the implementation's initializers are disabled and each vault is a
///      minimal-proxy clone initialized by {EarnVaultFactory}, mirroring the core PortfolioFactory style.
///      Because clones skip constructors, this contract carries its own initializable ERC-20 share ledger
///      rather than inheriting a constructor-based one.
///
///      Donation / share-inflation defense: conversions use OpenZeppelin's virtual-shares approach with a
///      non-zero `DECIMALS_OFFSET`, which makes a first-depositor inflation ("donation") attack strictly
///      unprofitable — the attacker loses more than any victim.
///
///      APY: {estimatedApyBps} is read LIVE from the active strategy's on-chain rate. It is ESTIMATED,
///      VARIABLE and NOT GUARANTEED, and is never hardcoded. Base yield comes ONLY from the external venue;
///      no STRAT (or any token) is minted and represented as yield.
contract EarnVault is IERC4626, Initializable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Role allowed to set/migrate the strategy and pause deposits.
    bytes32 public constant EARN_ADMIN = keccak256("EARN_ADMIN");

    /// @notice Virtual-shares offset for the donation-attack defense (virtual shares = 10**offset).
    /// @dev A technical accounting parameter (not an economic figure): raises the cost of a first-depositor
    ///      inflation attack so it is always unprofitable. See OpenZeppelin ERC-4626 "Inflation attack".
    uint8 internal constant DECIMALS_OFFSET = 3;

    // ── ERC-20 share ledger (initializable; constructor-free for clone compatibility) ──
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    /// @notice The base asset deposited into the vault.
    IERC20 private _asset;
    /// @notice Decimals of the base asset (share decimals = this + DECIMALS_OFFSET).
    uint8 private _underlyingDecimals;

    /// @notice The active yield strategy (address(0) until an admin sets one; assets sit idle meanwhile).
    IStrategy public strategy;

    /// @notice Clone-friendly init parameters.
    struct InitParams {
        address asset; // base asset (e.g. USDT)
        string name; // share token name
        string symbol; // share token symbol
        address admin; // EARN_ADMIN + DEFAULT_ADMIN_ROLE
    }

    /// @notice Emitted when the strategy is set or migrated. `migratedAssets` is what was pulled from the old.
    event StrategySet(address indexed oldStrategy, address indexed newStrategy, uint256 migratedAssets);
    /// @notice Emitted when the strategy is cleared and funds returned to idle.
    event StrategyCleared(address indexed oldStrategy, uint256 returnedAssets);

    error ZeroAddress();
    error ZeroAmount();
    error AssetMismatch();
    error BadStrategyOwner();
    error InsufficientLiquidity();
    error DepositsPaused();
    error ERC20InsufficientBalance();
    error ERC20InsufficientAllowance();
    error ERC4626ExceededMaxWithdraw();
    error ERC4626ExceededMaxRedeem();

    /// @dev Disable initializers on the implementation so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a clone.
    /// @dev SECURITY: `initializer` guard — callable once per clone. Detects the asset's decimals defensively.
    function initialize(InitParams calldata p) external initializer {
        if (p.asset == address(0) || p.admin == address(0)) revert ZeroAddress();
        _asset = IERC20(p.asset);
        _name = p.name;
        _symbol = p.symbol;
        _underlyingDecimals = _tryGetAssetDecimals(p.asset);
        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        _grantRole(EARN_ADMIN, p.admin);
    }

    // --------------------------------------------------------------------- //
    //                           ERC-20 (share token)                        //
    // --------------------------------------------------------------------- //

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /// @dev Share decimals = underlying decimals + virtual-offset (OpenZeppelin ERC-4626 convention).
    function decimals() public view returns (uint8) {
        return _underlyingDecimals + DECIMALS_OFFSET;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        _update(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        _update(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        if (from == address(0)) revert ZeroAddress();
        _update(from, address(0), value);
    }

    /// @dev Single balance/supply mutator (mint when from==0, burn when to==0, else transfer).
    function _update(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            _totalSupply += value;
        } else {
            uint256 fromBal = _balances[from];
            if (fromBal < value) revert ERC20InsufficientBalance();
            unchecked {
                _balances[from] = fromBal - value;
            }
        }
        if (to == address(0)) {
            unchecked {
                _totalSupply -= value;
            }
        } else {
            unchecked {
                _balances[to] += value;
            }
        }
        emit Transfer(from, to, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance();
            unchecked {
                _allowances[owner][spender] = current - value;
            }
        }
    }

    // --------------------------------------------------------------------- //
    //                            ERC-4626 accounting                        //
    // --------------------------------------------------------------------- //

    function asset() public view returns (address) {
        return address(_asset);
    }

    /// @notice Total assets under management = idle in the vault + assets held by the strategy (incl. yield).
    function totalAssets() public view returns (uint256) {
        uint256 idle = _asset.balanceOf(address(this));
        IStrategy s = strategy;
        return address(s) == address(0) ? idle : idle + s.totalAssets();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** DECIMALS_OFFSET, totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** DECIMALS_OFFSET, rounding);
    }

    function maxDeposit(address) public view returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(_balances[owner], Math.Rounding.Floor);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return _balances[owner];
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // --------------------------------------------------------------------- //
    //                          Deposit / Withdraw                           //
    // --------------------------------------------------------------------- //

    /// @notice Deposit `assets` of the base asset and mint shares to `receiver`.
    /// @dev SECURITY: nonReentrant + whenNotPaused. Shares priced on pre-deposit NAV; assets are routed to
    ///      the strategy inside the same call. CEI: pull, invest, then mint.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Mint exactly `shares` to `receiver`, pulling the required assets from the caller.
    /// @dev SECURITY: nonReentrant + whenNotPaused.
    function mint(uint256 shares, address receiver) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Withdraw exactly `assets` to `receiver`, burning shares from `owner`.
    /// @dev SECURITY: nonReentrant. Open even while paused so users can always exit. Pulls from strategy as
    ///      needed. CEI: check allowance, burn, divest, transfer.
    function withdraw(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (assets > maxWithdraw(owner)) revert ERC4626ExceededMaxWithdraw();
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Redeem `shares` from `owner`, sending the corresponding assets to `receiver`.
    /// @dev SECURITY: nonReentrant. Open even while paused.
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (shares > maxRedeem(owner)) revert ERC4626ExceededMaxRedeem();
        assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal {
        _asset.safeTransferFrom(caller, address(this), assets);
        _supplyToStrategy(assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal {
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);
        _ensureLiquidity(assets);
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Route idle `assets` into the active strategy (no-op if unset).
    function _supplyToStrategy(uint256 assets) internal {
        IStrategy s = strategy;
        if (address(s) == address(0) || assets == 0) return;
        _asset.forceApprove(address(s), assets);
        s.deposit(assets);
    }

    /// @dev Ensure the vault holds at least `assets` idle, divesting from the strategy for any shortfall.
    function _ensureLiquidity(uint256 assets) internal {
        uint256 idle = _asset.balanceOf(address(this));
        if (idle >= assets) return;
        uint256 need = assets - idle;
        IStrategy s = strategy;
        uint256 got = address(s) == address(0) ? 0 : s.withdraw(need);
        if (idle + got < assets) revert InsufficientLiquidity();
    }

    // --------------------------------------------------------------------- //
    //                        Strategy admin / migration                     //
    // --------------------------------------------------------------------- //

    /// @notice Set the active strategy, migrating any existing position into it. Also used for the first set.
    /// @dev SECURITY: EARN_ADMIN only + nonReentrant. Validates asset + owner match; withdraws the full old
    ///      position back to the vault and redeploys all idle assets into the new strategy. Value-conserving.
    function setStrategy(IStrategy newStrategy) external onlyRole(EARN_ADMIN) nonReentrant {
        if (address(newStrategy) == address(0)) revert ZeroAddress();
        if (newStrategy.asset() != address(_asset)) revert AssetMismatch();
        if (newStrategy.vault() != address(this)) revert BadStrategyOwner();

        IStrategy old = strategy;
        uint256 migrated;
        if (address(old) != address(0)) migrated = old.withdrawAll();

        strategy = newStrategy;

        uint256 idle = _asset.balanceOf(address(this));
        if (idle > 0) {
            _asset.forceApprove(address(newStrategy), idle);
            newStrategy.deposit(idle);
        }
        emit StrategySet(address(old), address(newStrategy), migrated);
    }

    /// @notice Pull the entire strategy position back to idle and detach the strategy.
    /// @dev SECURITY: EARN_ADMIN only + nonReentrant. Users can still deposit/withdraw against idle assets.
    function clearStrategy() external onlyRole(EARN_ADMIN) nonReentrant {
        IStrategy old = strategy;
        if (address(old) == address(0)) return;
        uint256 returned = old.withdrawAll();
        strategy = IStrategy(address(0));
        emit StrategyCleared(address(old), returned);
    }

    // --------------------------------------------------------------------- //
    //                              Views / admin                            //
    // --------------------------------------------------------------------- //

    /// @notice Assets redeemable for one whole share (10**decimals). Rises as yield accrues; never rebases.
    function pricePerShare() external view returns (uint256) {
        return _convertToAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    /// @notice Headline yield estimate, read LIVE from the active strategy's on-chain venue rate (bps).
    /// @dev ESTIMATED, VARIABLE and NOT GUARANTEED. This is the venue's supply APR only; it excludes any
    ///      separate STRAT reward incentives (which, if ever added, are surfaced on a distinct rewards line).
    ///      Returns 0 when no strategy is set.
    function estimatedApyBps() external view returns (uint256) {
        IStrategy s = strategy;
        return address(s) == address(0) ? 0 : s.supplyAprBps();
    }

    /// @notice Pause new deposits/mints (withdraw/redeem stay open).
    /// @dev SECURITY: EARN_ADMIN only.
    function pause() external onlyRole(EARN_ADMIN) {
        _pause();
    }

    /// @notice Resume deposits/mints.
    function unpause() external onlyRole(EARN_ADMIN) {
        _unpause();
    }

    /// @dev Best-effort asset decimals detection; defaults to 18 if the token doesn't expose `decimals()`.
    function _tryGetAssetDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
