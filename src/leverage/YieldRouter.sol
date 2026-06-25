// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IYieldAdapter } from "../interfaces/IYieldAdapter.sol";

/// @title YieldRouter
/// @notice Allocates idle underlying across yield adapters by best rate, keeping an idle buffer for
///         redemptions.
/// @dev Single-asset router owned by a depositor (e.g. a vault/leverage module). Maintains an idle
///      reserve (>= bufferBps of managed assets) so redemptions up to the buffer are always instant.
///      Invariant: managed value is conserved across invest/withdraw (no funds lost).
contract YieldRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to deposit/withdraw and trigger investment.
    bytes32 public constant ALLOCATOR = keccak256("ALLOCATOR");
    /// @notice Role allowed to manage adapters and the buffer.
    bytes32 public constant YIELD_ADMIN = keccak256("YIELD_ADMIN");

    uint256 internal constant BPS = 10_000;

    /// @notice The single asset managed by this router.
    IERC20 public immutable asset;
    /// @notice Target idle buffer as bps of total managed assets.
    uint16 public idleBufferBps;

    IYieldAdapter[] public adapters;
    mapping(address => bool) public isAdapter;

    /// @notice Emitted when funds are invested into an adapter.
    event Invested(address indexed adapter, uint256 amount);
    /// @notice Emitted when funds are pulled from an adapter to satisfy a withdrawal.
    event Divested(address indexed adapter, uint256 amount);
    /// @notice Emitted on deposit/withdraw.
    event Deposited(uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event AdapterAdded(address indexed adapter);
    event BufferSet(uint16 bps);

    error BadAdapter();
    error InsufficientLiquidity();
    error InvalidParam();

    /// @param admin Admin + allocator.
    /// @param asset_ The managed asset.
    /// @param idleBufferBps_ Target idle buffer (bps).
    constructor(address admin, IERC20 asset_, uint16 idleBufferBps_) {
        if (idleBufferBps_ > BPS) revert InvalidParam();
        asset = asset_;
        idleBufferBps = idleBufferBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(YIELD_ADMIN, admin);
        _grantRole(ALLOCATOR, admin);
    }

    /// @notice Register a yield adapter (must manage the same asset and be owned by this router).
    /// @dev SECURITY: YIELD_ADMIN only.
    function addAdapter(IYieldAdapter adapter) external onlyRole(YIELD_ADMIN) {
        if (adapter.asset() != address(asset) || isAdapter[address(adapter)]) revert BadAdapter();
        adapters.push(adapter);
        isAdapter[address(adapter)] = true;
        emit AdapterAdded(address(adapter));
    }

    /// @notice Set the idle buffer target.
    /// @dev SECURITY: YIELD_ADMIN only.
    function setIdleBuffer(uint16 bps) external onlyRole(YIELD_ADMIN) {
        if (bps > BPS) revert InvalidParam();
        idleBufferBps = bps;
        emit BufferSet(bps);
    }

    /// @notice Deposit `amount` of asset into the router (held idle until invested).
    /// @dev SECURITY: ALLOCATOR only + nonReentrant.
    function deposit(uint256 amount) external onlyRole(ALLOCATOR) nonReentrant {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(amount);
    }

    /// @notice Withdraw `amount` to `to`, drawing from idle first then divesting adapters.
    /// @dev SECURITY: ALLOCATOR only + nonReentrant. Reverts if total managed < amount.
    function withdraw(uint256 amount, address to) external onlyRole(ALLOCATOR) nonReentrant returns (uint256) {
        uint256 idle = idleBalance();
        if (idle < amount) {
            uint256 need = amount - idle;
            uint256 len = adapters.length;
            for (uint256 i; i < len && need > 0; ++i) {
                uint256 pulled = adapters[i].withdraw(need, address(this));
                if (pulled > 0) emit Divested(address(adapters[i]), pulled);
                need = pulled >= need ? 0 : need - pulled;
            }
            if (need > 0) revert InsufficientLiquidity();
        }
        asset.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
        return amount;
    }

    /// @notice Invest idle funds above the buffer into the best-APR adapter.
    /// @dev SECURITY: ALLOCATOR only + nonReentrant. Keeps idle >= bufferBps of managed after investing.
    function invest() external onlyRole(ALLOCATOR) nonReentrant {
        uint256 managed = totalManaged();
        uint256 buffer = (managed * idleBufferBps) / BPS;
        uint256 idle = idleBalance();
        if (idle <= buffer) return;
        uint256 investable = idle - buffer;

        IYieldAdapter best = _bestAdapter();
        if (address(best) == address(0)) return;
        asset.forceApprove(address(best), investable);
        best.deposit(investable);
        emit Invested(address(best), investable);
    }

    /// @notice Idle (uninvested) balance held by the router.
    function idleBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Total assets in adapters (principal + accrued yield).
    function investedAssets() public view returns (uint256 total) {
        uint256 len = adapters.length;
        for (uint256 i; i < len; ++i) {
            total += adapters[i].totalAssets();
        }
    }

    /// @notice Total managed assets = idle + invested.
    function totalManaged() public view returns (uint256) {
        return idleBalance() + investedAssets();
    }

    /// @notice Number of registered adapters.
    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    function _bestAdapter() internal view returns (IYieldAdapter best) {
        uint256 bestApr;
        uint256 len = adapters.length;
        for (uint256 i; i < len; ++i) {
            uint256 apr = adapters[i].aprBps();
            if (apr >= bestApr) {
                bestApr = apr;
                best = adapters[i];
            }
        }
    }
}
