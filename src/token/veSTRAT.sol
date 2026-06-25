// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title veSTRAT
/// @notice Vote-escrowed STRAT (Curve-style): lock STRAT up to 4 years for non-transferable, linearly
///         decaying voting power.
/// @dev `balanceOf` decays to zero at unlock; `totalSupply` is maintained via a global point with
///      scheduled slope changes at each lock's expiry (the canonical Curve method). Non-transferable.
contract veSTRAT is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum lock time (4 years).
    uint256 public constant MAXTIME = 4 * 365 days;
    /// @notice Lock-end rounding granularity.
    uint256 public constant WEEK = 7 days;

    /// @notice The locked STRAT token.
    IERC20 public immutable strat;

    struct LockedBalance {
        uint256 amount;
        uint256 end;
    }

    mapping(address => LockedBalance) public locked;

    // Global point (Curve-style): bias - slope·(t − ts), with scheduled slope changes.
    int128 public globalBias;
    int128 public globalSlope;
    uint256 public globalTs;
    mapping(uint256 => int128) public slopeChanges; // week-ts => slope delta applied at expiry

    event LockCreated(address indexed user, uint256 amount, uint256 end);
    event AmountIncreased(address indexed user, uint256 amount);
    event UnlockExtended(address indexed user, uint256 end);
    event Withdrawn(address indexed user, uint256 amount);

    error NoLock();
    error LockExists();
    error LockExpired();
    error BadUnlockTime();
    error NotExpired();
    error ZeroAmount();

    constructor(IERC20 strat_) {
        strat = strat_;
        globalTs = block.timestamp;
    }

    /// @notice Create a lock of `amount` STRAT until `unlockTime` (rounded down to a week).
    /// @dev SECURITY: nonReentrant. CEI: state then token pull. No existing lock allowed.
    function createLock(uint256 amount, uint256 unlockTime) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 end = (unlockTime / WEEK) * WEEK;
        if (locked[msg.sender].amount != 0) revert LockExists();
        if (end <= block.timestamp || end > block.timestamp + MAXTIME) revert BadUnlockTime();

        LockedBalance memory old = locked[msg.sender];
        LockedBalance memory neu = LockedBalance({ amount: amount, end: end });
        locked[msg.sender] = neu;
        _checkpoint(old, neu);
        strat.safeTransferFrom(msg.sender, address(this), amount);
        emit LockCreated(msg.sender, amount, end);
    }

    /// @notice Add `amount` to an existing, unexpired lock.
    /// @dev SECURITY: nonReentrant.
    function increaseAmount(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LockedBalance memory old = locked[msg.sender];
        if (old.amount == 0) revert NoLock();
        if (old.end <= block.timestamp) revert LockExpired();

        LockedBalance memory neu = LockedBalance({ amount: old.amount + amount, end: old.end });
        locked[msg.sender] = neu;
        _checkpoint(old, neu);
        strat.safeTransferFrom(msg.sender, address(this), amount);
        emit AmountIncreased(msg.sender, amount);
    }

    /// @notice Extend the unlock time of an existing lock.
    /// @dev SECURITY: nonReentrant.
    function increaseUnlockTime(uint256 unlockTime) external nonReentrant {
        LockedBalance memory old = locked[msg.sender];
        if (old.amount == 0) revert NoLock();
        if (old.end <= block.timestamp) revert LockExpired();
        uint256 end = (unlockTime / WEEK) * WEEK;
        if (end <= old.end || end > block.timestamp + MAXTIME) revert BadUnlockTime();

        LockedBalance memory neu = LockedBalance({ amount: old.amount, end: end });
        locked[msg.sender] = neu;
        _checkpoint(old, neu);
        emit UnlockExtended(msg.sender, end);
    }

    /// @notice Withdraw STRAT from an expired lock.
    /// @dev SECURITY: nonReentrant. CEI: clear state, checkpoint, then transfer.
    function withdraw() external nonReentrant {
        LockedBalance memory old = locked[msg.sender];
        if (old.amount == 0) revert NoLock();
        if (old.end > block.timestamp) revert NotExpired();

        uint256 amount = old.amount;
        LockedBalance memory neu = LockedBalance({ amount: 0, end: 0 });
        locked[msg.sender] = neu;
        _checkpoint(old, neu);
        strat.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Current decayed voting power of `user`.
    function balanceOf(address user) public view returns (uint256) {
        LockedBalance memory l = locked[user];
        if (l.end <= block.timestamp) return 0;
        return (l.amount * (l.end - block.timestamp)) / MAXTIME;
    }

    /// @notice Total decayed voting power across all locks.
    function totalSupply() public view returns (uint256) {
        int128 bias = globalBias;
        int128 slope = globalSlope;
        uint256 ti = (globalTs / WEEK) * WEEK;
        uint256 lastTi = globalTs;
        for (uint256 i; i < 255; ++i) {
            ti += WEEK;
            int128 dSlope = 0;
            if (ti > block.timestamp) {
                ti = block.timestamp;
            } else {
                dSlope = slopeChanges[ti];
            }
            bias -= slope * int128(uint128(ti - lastTi));
            if (ti == block.timestamp) break;
            slope += dSlope;
            lastTi = ti;
        }
        return bias < 0 ? 0 : uint256(uint128(bias));
    }

    /// @dev Advance the global point to `now`, applying scheduled slope changes week by week.
    function _checkpointGlobal() internal {
        int128 bias = globalBias;
        int128 slope = globalSlope;
        uint256 ti = (globalTs / WEEK) * WEEK;
        uint256 lastTi = globalTs;
        for (uint256 i; i < 255; ++i) {
            ti += WEEK;
            int128 dSlope = 0;
            if (ti > block.timestamp) {
                ti = block.timestamp;
            } else {
                dSlope = slopeChanges[ti];
            }
            bias -= slope * int128(uint128(ti - lastTi));
            slope += dSlope;
            if (bias < 0) bias = 0;
            if (slope < 0) slope = 0;
            lastTi = ti;
            if (ti == block.timestamp) break;
        }
        globalBias = bias;
        globalSlope = slope;
        globalTs = block.timestamp;
    }

    /// @dev Apply a user's lock change to the global point and scheduled slope changes.
    function _checkpoint(LockedBalance memory old, LockedBalance memory neu) internal {
        _checkpointGlobal();

        int128 oldSlope = old.end > block.timestamp ? int128(uint128(old.amount / MAXTIME)) : int128(0);
        int128 newSlope = neu.end > block.timestamp ? int128(uint128(neu.amount / MAXTIME)) : int128(0);
        int128 oldBias = oldSlope * int128(uint128(old.end > block.timestamp ? old.end - block.timestamp : 0));
        int128 newBias = newSlope * int128(uint128(neu.end > block.timestamp ? neu.end - block.timestamp : 0));

        globalSlope += newSlope - oldSlope;
        globalBias += newBias - oldBias;
        if (globalSlope < 0) globalSlope = 0;
        if (globalBias < 0) globalBias = 0;

        // Schedule slope changes at expiries (Curve method).
        if (old.end > block.timestamp) {
            int128 oldDslope = slopeChanges[old.end] + oldSlope;
            if (neu.end == old.end) oldDslope -= newSlope;
            slopeChanges[old.end] = oldDslope;
        }
        if (neu.end > block.timestamp && neu.end > old.end) {
            slopeChanges[neu.end] -= newSlope;
        }
    }
}
