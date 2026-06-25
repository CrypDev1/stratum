// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AgentPolicy
/// @notice On-chain guardrails an AI agent CANNOT violate: asset whitelist, max position size, max
///         turnover per epoch, and a max-drawdown kill switch. Parameter changes are timelocked.
/// @dev The bound `vault` calls `recordTrade`/`checkpointNav` on every agent action; this contract is
///      the "disposer" — it reverts out-of-bounds actions and trips the kill switch on drawdown.
///      Governance proposes parameter changes which only take effect after `timelockDelay`.
contract AgentPolicy is AccessControl {
    bytes32 public constant POLICY_ADMIN = keccak256("POLICY_ADMIN");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 internal constant BPS = 10_000;

    /// @notice The vault this policy governs (only it may record actions).
    address public vault;

    struct Params {
        uint16 maxPositionBps; // max weight any single asset may reach
        uint16 maxTurnoverPerEpochBps; // max traded value per epoch (bps of NAV)
        uint16 maxDrawdownBps; // drawdown from high-water that trips the kill switch
        uint64 epochLength; // seconds per turnover epoch
    }

    Params public params;
    uint64 public timelockDelay;

    // pending (timelocked) params
    Params public pendingParams;
    uint256 public pendingEta;
    bool public hasPending;

    // kill switch + drawdown tracking
    bool public killed;
    uint256 public highWaterNav; // navPerShare high-water (18-dec)

    // epoch turnover tracking
    uint256 public epochStart;
    uint256 public epochTurnover; // value traded this epoch

    mapping(address => bool) public whitelisted;

    event VaultSet(address vault);
    event WhitelistSet(address indexed asset, bool allowed);
    event ParamsProposed(uint256 eta);
    event ParamsApplied();
    event Killed(uint256 nav, uint256 highWater);
    event KillReset();

    error OnlyVault();
    error AssetNotAllowed(address asset);
    error PositionTooLarge();
    error TurnoverExceeded();
    error AgentKilled();
    error TimelockPending();
    error TimelockNotReady();

    constructor(address admin, Params memory p, uint64 timelockDelay_) {
        params = p;
        timelockDelay = timelockDelay_;
        highWaterNav = 1e18;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN, admin);
        _grantRole(GUARDIAN, admin);
    }

    /// @notice Bind the vault once.
    /// @dev SECURITY: POLICY_ADMIN only, single-shot.
    function setVault(address vault_) external onlyRole(POLICY_ADMIN) {
        require(vault == address(0), "vault set");
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice Set whitelist membership (immediate; governance-controlled, not agent-controlled).
    /// @dev SECURITY: POLICY_ADMIN only.
    function setWhitelist(address asset, bool allowed) external onlyRole(POLICY_ADMIN) {
        whitelisted[asset] = allowed;
        emit WhitelistSet(asset, allowed);
    }

    /// @notice Propose a timelocked parameter change.
    /// @dev SECURITY: POLICY_ADMIN only. Takes effect only after `timelockDelay`.
    function proposeParams(Params calldata p) external onlyRole(POLICY_ADMIN) {
        pendingParams = p;
        pendingEta = block.timestamp + timelockDelay;
        hasPending = true;
        emit ParamsProposed(pendingEta);
    }

    /// @notice Apply a previously proposed parameter change after the timelock.
    /// @dev SECURITY: POLICY_ADMIN only; reverts before the eta.
    function applyParams() external onlyRole(POLICY_ADMIN) {
        if (!hasPending) revert TimelockNotReady();
        if (block.timestamp < pendingEta) revert TimelockNotReady();
        params = pendingParams;
        hasPending = false;
        emit ParamsApplied();
    }

    /// @notice Manually trip / reset the kill switch.
    /// @dev SECURITY: GUARDIAN only.
    function setKilled(bool k) external onlyRole(GUARDIAN) {
        killed = k;
        if (!k) emit KillReset();
        else emit Killed(0, highWaterNav);
    }

    /// @notice Validate + record an agent trade. Reverts if any guardrail is breached.
    /// @dev SECURITY: vault-only. Checks kill switch, whitelist, post-trade position size, and per-epoch
    ///      turnover (which it accumulates). This is the hard gate the agent cannot bypass.
    /// @param asset The output asset of the trade.
    /// @param tradeValue USD value of the trade.
    /// @param positionValueAfter USD value of `asset` held after the trade.
    /// @param nav Current vault NAV (USD).
    function recordTrade(address asset, uint256 tradeValue, uint256 positionValueAfter, uint256 nav) external {
        if (msg.sender != vault) revert OnlyVault();
        if (killed) revert AgentKilled();
        if (!whitelisted[asset]) revert AssetNotAllowed(asset);

        if (nav > 0 && positionValueAfter * BPS > nav * params.maxPositionBps) revert PositionTooLarge();

        if (block.timestamp >= epochStart + params.epochLength) {
            epochStart = block.timestamp;
            epochTurnover = 0;
        }
        epochTurnover += tradeValue;
        if (nav > 0 && epochTurnover * BPS > nav * params.maxTurnoverPerEpochBps) revert TurnoverExceeded();
    }

    /// @notice Update the high-water NAV and trip the kill switch on excess drawdown.
    /// @dev SECURITY: vault-only. Permissionlessly callable via the vault to enforce the drawdown halt.
    /// @param nav Current vault NAV-per-share (18-dec).
    function checkpointNav(uint256 nav) external {
        if (msg.sender != vault) revert OnlyVault();
        if (nav > highWaterNav) {
            highWaterNav = nav;
        } else if (highWaterNav > 0) {
            uint256 drop = ((highWaterNav - nav) * BPS) / highWaterNav;
            if (drop >= params.maxDrawdownBps && !killed) {
                killed = true;
                emit Killed(nav, highWaterNav);
            }
        }
    }

    /// @notice Whether the agent is currently allowed to act.
    function active() external view returns (bool) {
        return !killed;
    }
}
