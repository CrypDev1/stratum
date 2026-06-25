// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AgentRegistry
/// @notice Public, on-chain track record for agent strategies so a vault marketplace can rank them
///         trustlessly.
/// @dev Tamper-evident: only the bound vault may report its own NAV checkpoints, and history is
///      append-only (epoch counter + cumulative return only ever increase in count). No one can rewrite
///      a past data point.
contract AgentRegistry {
    struct AgentRecord {
        address controller; // who registered the strategy
        address vault; // the AgentVault that reports performance
        string name;
        uint256 epochs; // number of reported checkpoints
        uint256 lastNav; // last reported navPerShare (18-dec)
        int256 cumulativeReturnBps; // sum of per-epoch returns (bps)
        bool active;
    }

    AgentRecord[] private _agents;
    /// @notice vault => agentId+1 (0 = unregistered).
    mapping(address => uint256) public agentIdOfVault;

    event AgentRegistered(uint256 indexed id, address indexed vault, address indexed controller, string name);
    event NavReported(uint256 indexed id, uint256 nav, int256 returnBps, uint256 epoch);

    error AlreadyRegistered();
    error NotVault();
    error UnknownAgent();

    /// @notice Register an agent strategy bound to `vault`.
    /// @dev Permissionless; records msg.sender as the controller. One registration per vault.
    /// @param vault The AgentVault that will report performance.
    /// @param name Human-readable strategy name.
    /// @return id The agent id.
    function register(address vault, string calldata name) external returns (uint256 id) {
        if (agentIdOfVault[vault] != 0) revert AlreadyRegistered();
        id = _agents.length;
        _agents.push(
            AgentRecord({
                controller: msg.sender,
                vault: vault,
                name: name,
                epochs: 0,
                lastNav: 1e18,
                cumulativeReturnBps: 0,
                active: true
            })
        );
        agentIdOfVault[vault] = id + 1;
        emit AgentRegistered(id, vault, msg.sender, name);
    }

    /// @notice Report a NAV checkpoint for the caller's agent (must be the bound vault).
    /// @dev SECURITY: only the registered `vault` may report — makes the track record tamper-evident.
    ///      Append-only: increments the epoch counter and accumulates the per-epoch return.
    /// @param navPerShare Current navPerShare (18-dec).
    function reportNav(uint256 navPerShare) external {
        uint256 idx = agentIdOfVault[msg.sender];
        if (idx == 0) revert NotVault();
        AgentRecord storage a = _agents[idx - 1];
        int256 returnBps =
            a.lastNav == 0 ? int256(0) : ((int256(navPerShare) - int256(a.lastNav)) * 10_000) / int256(a.lastNav);
        a.cumulativeReturnBps += returnBps;
        a.lastNav = navPerShare;
        a.epochs += 1;
        emit NavReported(idx - 1, navPerShare, returnBps, a.epochs);
    }

    /// @notice Number of registered agents.
    function agentCount() external view returns (uint256) {
        return _agents.length;
    }

    /// @notice Read an agent record.
    function getAgent(uint256 id) external view returns (AgentRecord memory) {
        if (id >= _agents.length) revert UnknownAgent();
        return _agents[id];
    }
}
