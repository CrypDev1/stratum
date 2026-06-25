// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { veSTRAT } from "./veSTRAT.sol";

/// @title FeeDistributor
/// @notice Collects protocol fees from L1–L4 and distributes them to veSTRAT lockers pro-rata, per epoch.
/// @dev Epoch = 1 week. Lockers `checkpoint` their voting power into an epoch to be eligible; rewards
///      notified in that epoch are split pro-rata to checkpointed power. Claims are per-epoch and
///      one-shot. INVARIANT: total claimed for an epoch never exceeds the rewards notified for it, and
///      no epoch can be claimed twice by the same user.
contract FeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;

    /// @notice The vote-escrow token (eligibility weight).
    veSTRAT public immutable ve;
    /// @notice The reward token distributed (e.g. protocol stable).
    IERC20 public immutable reward;

    mapping(uint256 => uint256) public epochReward; // epoch => total reward notified
    mapping(uint256 => uint256) public epochTotalVe; // epoch => total checkpointed ve power
    mapping(uint256 => mapping(address => uint256)) public userEpochVe; // epoch => user => power
    mapping(uint256 => mapping(address => bool)) public claimed; // epoch => user => claimed
    mapping(uint256 => uint256) public epochClaimed; // epoch => total claimed (accounting)

    event RewardNotified(uint256 indexed epoch, uint256 amount);
    event Checkpointed(uint256 indexed epoch, address indexed user, uint256 power);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    error NotFinalized();
    error AlreadyClaimed();
    error NothingToClaim();

    constructor(veSTRAT ve_, IERC20 reward_) {
        ve = ve_;
        reward = reward_;
    }

    /// @notice The current epoch index.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    /// @notice Notify `amount` of reward for the current epoch (pulled from caller).
    /// @dev SECURITY: nonReentrant. Any protocol module may forward fees here.
    function notifyReward(uint256 amount) external nonReentrant {
        if (amount == 0) revert NothingToClaim();
        reward.safeTransferFrom(msg.sender, address(this), amount);
        epochReward[currentEpoch()] += amount;
        emit RewardNotified(currentEpoch(), amount);
    }

    /// @notice Record the caller's current veSTRAT power into the current epoch's distribution.
    /// @dev SECURITY: idempotent within an epoch (updates to the latest balance). Must be called in the
    ///      epoch the fees are earned to be eligible for them.
    function checkpoint() external {
        uint256 e = currentEpoch();
        uint256 bal = ve.balanceOf(msg.sender);
        uint256 prev = userEpochVe[e][msg.sender];
        epochTotalVe[e] = epochTotalVe[e] - prev + bal;
        userEpochVe[e][msg.sender] = bal;
        emit Checkpointed(e, msg.sender, bal);
    }

    /// @notice Claimable reward for `user` in a finalized `epoch`.
    function claimable(address user, uint256 epoch) public view returns (uint256) {
        if (epoch >= currentEpoch()) return 0;
        if (claimed[epoch][user]) return 0;
        uint256 total = epochTotalVe[epoch];
        if (total == 0) return 0;
        return (epochReward[epoch] * userEpochVe[epoch][user]) / total;
    }

    /// @notice Claim the caller's reward for a finalized `epoch`.
    /// @dev SECURITY: nonReentrant. Reverts if the epoch is not yet finalized or already claimed.
    function claim(uint256 epoch) external nonReentrant returns (uint256 amount) {
        if (epoch >= currentEpoch()) revert NotFinalized();
        if (claimed[epoch][msg.sender]) revert AlreadyClaimed();
        uint256 total = epochTotalVe[epoch];
        if (total == 0) revert NothingToClaim();

        amount = (epochReward[epoch] * userEpochVe[epoch][msg.sender]) / total;
        claimed[epoch][msg.sender] = true;
        if (amount == 0) revert NothingToClaim();
        epochClaimed[epoch] += amount;
        reward.safeTransfer(msg.sender, amount);
        emit Claimed(epoch, msg.sender, amount);
    }
}
