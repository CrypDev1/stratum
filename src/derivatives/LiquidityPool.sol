// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LiquidityPool
/// @notice Vault-backed counterparty for the PerpEngine. LPs deposit stable and earn fees/funding;
///         the pool pays trader profits and absorbs trader losses.
/// @dev ERC20 LP-share token. Only the bound `engine` may pay out pool funds. Trader losses arrive as
///      plain transfers into the pool, increasing share value. Utilization (open interest / assets)
///      drives funding in the engine.
contract LiquidityPool is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_ADMIN = keccak256("POOL_ADMIN");

    uint256 internal constant BPS = 10_000;

    /// @notice The stable collateral asset.
    IERC20 public immutable asset;
    /// @notice The PerpEngine authorized to draw pool funds.
    address public engine;

    event EngineSet(address engine);
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 assets);
    event PaidOut(address indexed to, uint256 amount);

    error OnlyEngine();
    error EngineAlreadySet();
    error ZeroAmount();

    constructor(address admin, IERC20 asset_) ERC20("Stratum Perp LP", "sLP") {
        asset = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_ADMIN, admin);
    }

    /// @notice Bind the PerpEngine once.
    /// @dev SECURITY: POOL_ADMIN only, single-shot.
    function setEngine(address engine_) external onlyRole(POOL_ADMIN) {
        if (engine != address(0)) revert EngineAlreadySet();
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Total stable assets backing LP shares.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Deposit `assets` stable for LP shares.
    /// @dev SECURITY: nonReentrant. First deposit mints 1:1; later mints pro-rata to share value.
    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        uint256 bal = totalAssets();
        shares = supply == 0 ? assets : (assets * supply) / bal;
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn `shares` for the pro-rata stable.
    /// @dev SECURITY: nonReentrant. Withdraws current share value (post PnL).
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        assets = (shares * totalAssets()) / totalSupply();
        _burn(msg.sender, shares);
        asset.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, shares, assets);
    }

    /// @notice Pay `amount` stable to `to` (covering a trader profit).
    /// @dev SECURITY: engine-only. The engine guarantees solvency/utilization caps.
    function payOut(address to, uint256 amount) external nonReentrant {
        if (msg.sender != engine) revert OnlyEngine();
        asset.safeTransfer(to, amount);
        emit PaidOut(to, amount);
    }
}
