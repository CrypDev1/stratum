// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { GaugeController } from "./GaugeController.sol";

/// @title GaugeDistributor
/// @notice Splits STRAT emissions across GaugeController gauges in proportion to their veSTRAT-voted
///         relative weight, and lets each gauge's reward be claimed to a configurable receiver.
/// @dev Additive: the deployed GaugeController only *computes* gauge weights — it holds no rewards and
///      has no distributor. The EmissionsMinter is pointed at this contract (its `emitTo` recipient); each
///      `distribute()` allocates the STRAT that has arrived since the last call across gauges by
///      `relativeWeight`. Funds are conserved: unallocated dust (rounding, or weight that sums to < 1e18
///      when some gauges have no votes) simply stays as the next call's undistributed balance — never lost.
///      SECURITY: `distribute`/`claim` are permissionless (claims always pay the gauge's configured
///      receiver); only receiver wiring is admin-gated.
contract GaugeDistributor is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to set per-gauge reward receivers.
    bytes32 public constant DISTRIBUTOR_ADMIN = keccak256("DISTRIBUTOR_ADMIN");

    uint256 internal constant WAD = 1e18;

    /// @notice The reward token (STRAT).
    IERC20 public immutable reward;
    /// @notice The gauge controller providing the gauge set and relative weights.
    GaugeController public immutable controller;

    /// @notice Unclaimed reward accrued to each gauge.
    mapping(address => uint256) public gaugeAccrued;
    /// @notice Optional override of where a gauge's reward is sent on claim (default: the gauge address).
    mapping(address => address) public rewardReceiver;
    /// @notice Total accrued-but-unclaimed across all gauges (excluded from `undistributed`).
    uint256 public totalAccrued;

    event ReceiverSet(address indexed gauge, address receiver);
    event Distributed(uint256 amount);
    event GaugeAllocated(address indexed gauge, uint256 amount);
    event Claimed(address indexed gauge, address indexed receiver, uint256 amount);

    error ZeroAddress();

    /// @param admin Distributor admin (receiver wiring).
    /// @param reward_ The STRAT token.
    /// @param controller_ The GaugeController.
    constructor(address admin, IERC20 reward_, GaugeController controller_) {
        if (address(reward_) == address(0) || address(controller_) == address(0)) revert ZeroAddress();
        reward = reward_;
        controller = controller_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DISTRIBUTOR_ADMIN, admin);
    }

    /// @notice Set where `gauge`'s reward is sent on claim (address(0) restores the default: the gauge).
    /// @dev SECURITY: DISTRIBUTOR_ADMIN only.
    function setRewardReceiver(address gauge, address receiver) external onlyRole(DISTRIBUTOR_ADMIN) {
        rewardReceiver[gauge] = receiver;
        emit ReceiverSet(gauge, receiver);
    }

    /// @notice STRAT received but not yet allocated to gauges.
    function undistributed() public view returns (uint256) {
        return reward.balanceOf(address(this)) - totalAccrued;
    }

    /// @notice Allocate newly-arrived STRAT across gauges by current relative weight.
    /// @dev Permissionless poke (run by the emissions keeper after `EmissionsMinter.emitTo(this)`). When
    ///      `totalVotes == 0` all weights are 0 and nothing is allocated — the balance waits for votes.
    /// @return distributed Total newly allocated this call.
    function distribute() external returns (uint256 distributed) {
        uint256 newReward = undistributed();
        if (newReward == 0) return 0;

        uint256 n = controller.gaugeCount();
        for (uint256 i; i < n; ++i) {
            address gauge = controller.gauges(i);
            uint256 w = controller.relativeWeight(gauge);
            if (w == 0) continue;
            uint256 alloc = (newReward * w) / WAD;
            if (alloc == 0) continue;
            gaugeAccrued[gauge] += alloc;
            distributed += alloc;
            emit GaugeAllocated(gauge, alloc);
        }
        totalAccrued += distributed;
        emit Distributed(distributed);
    }

    /// @notice Claim a gauge's accrued reward to its configured receiver (default: the gauge address).
    /// @dev Permissionless; funds always go to the receiver, so anyone may trigger a claim.
    /// @param gauge The gauge to claim for.
    /// @return amount The amount transferred.
    function claim(address gauge) external returns (uint256 amount) {
        amount = gaugeAccrued[gauge];
        if (amount == 0) return 0;
        gaugeAccrued[gauge] = 0;
        totalAccrued -= amount;
        address to = rewardReceiver[gauge];
        if (to == address(0)) to = gauge;
        reward.safeTransfer(to, amount);
        emit Claimed(gauge, to, amount);
    }

    /// @notice Receiver a claim would pay for `gauge`.
    function receiverOf(address gauge) external view returns (address) {
        address to = rewardReceiver[gauge];
        return to == address(0) ? gauge : to;
    }
}
