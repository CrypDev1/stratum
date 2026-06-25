// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { veSTRAT } from "./veSTRAT.sol";

/// @title GaugeController
/// @notice veSTRAT holders vote to direct STRAT emissions across gauges (one per Index/Vault).
/// @dev Each voter splits their voting power (≤ 100%) across gauges; a gauge's weight is the sum of the
///      recorded voting power directed to it, and `relativeWeight` normalizes weights to 1e18 across all
///      gauges. Re-voting replaces a voter's prior allocation (no double counting).
contract GaugeController is AccessControl {
    bytes32 public constant GAUGE_ADMIN = keccak256("GAUGE_ADMIN");
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice The vote-escrow token.
    veSTRAT public immutable ve;

    address[] public gauges;
    mapping(address => bool) public isGauge;

    mapping(address => uint256) public gaugeVotes; // recorded voting power per gauge
    uint256 public totalVotes;

    mapping(address => mapping(address => uint256)) public userGaugeBps; // user => gauge => weightBps
    mapping(address => mapping(address => uint256)) public userGaugePower; // recorded contribution
    mapping(address => uint256) public userUsedBps;

    event GaugeAdded(address indexed gauge);
    event Voted(address indexed user, address indexed gauge, uint256 weightBps, uint256 power);

    error NotGauge();
    error OverAllocated();
    error AlreadyGauge();

    constructor(address admin, veSTRAT ve_) {
        ve = ve_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GAUGE_ADMIN, admin);
    }

    /// @notice Register a gauge.
    /// @dev SECURITY: GAUGE_ADMIN only.
    function addGauge(address gauge) external onlyRole(GAUGE_ADMIN) {
        if (isGauge[gauge]) revert AlreadyGauge();
        isGauge[gauge] = true;
        gauges.push(gauge);
        emit GaugeAdded(gauge);
    }

    /// @notice Direct `weightBps` of the caller's voting power to `gauge` (replaces any prior vote).
    /// @dev SECURITY: voter's total allocation across gauges may not exceed 100%. Uses current veBalance.
    function voteForGauge(address gauge, uint256 weightBps) external {
        if (!isGauge[gauge]) revert NotGauge();

        // Replace the caller's previous allocation to this gauge.
        uint256 oldBps = userGaugeBps[msg.sender][gauge];
        uint256 newUsed = userUsedBps[msg.sender] - oldBps + weightBps;
        if (newUsed > BPS) revert OverAllocated();
        userUsedBps[msg.sender] = newUsed;
        userGaugeBps[msg.sender][gauge] = weightBps;

        uint256 power = ve.balanceOf(msg.sender);
        uint256 oldPower = userGaugePower[msg.sender][gauge];
        uint256 newPower = (power * weightBps) / BPS;
        userGaugePower[msg.sender][gauge] = newPower;

        gaugeVotes[gauge] = gaugeVotes[gauge] - oldPower + newPower;
        totalVotes = totalVotes - oldPower + newPower;
        emit Voted(msg.sender, gauge, weightBps, newPower);
    }

    /// @notice Gauge weight relative to all gauges, scaled to 1e18 (sums to ~1e18 across gauges).
    function relativeWeight(address gauge) external view returns (uint256) {
        if (totalVotes == 0) return 0;
        return (gaugeVotes[gauge] * WAD) / totalVotes;
    }

    /// @notice Number of registered gauges.
    function gaugeCount() external view returns (uint256) {
        return gauges.length;
    }
}
