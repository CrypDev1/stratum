// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VaultPortfolio } from "../core/VaultPortfolio.sol";
import { IFeeManager } from "../interfaces/IFeeManager.sol";
import { AgentPolicy } from "./AgentPolicy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AgentVault
/// @notice A VaultPortfolio whose "manager" is an authorized AI agent executor bound to an on-chain
///         AgentPolicy. The agent proposes trades; the policy disposes — it rejects any action that
///         breaches the whitelist, max position size, per-epoch turnover or drawdown kill switch.
/// @dev Every agent trade routes through `executeTrade`, which checkpoints NAV (tripping the drawdown
///      kill switch if needed) and records the trade against the policy. The agent cannot bypass these
///      guardrails: the policy's parameters are governance-owned and timelocked, not agent-controlled.
contract AgentVault is VaultPortfolio {
    /// @notice The hard-guardrail policy.
    AgentPolicy public policy;

    event AgentTrade(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event NavCheckpointed(uint256 navPerShare);

    error PolicyNotSet();

    /// @notice Initialize a cloned AgentVault.
    /// @param p Base init params (p.admin governance; cfg.manager is the agent executor).
    /// @param feeManager_ Fee math.
    /// @param cfg Fee config (manager = agent).
    /// @param maxTradeBps_ Per-trade cap.
    /// @param policy_ The bound AgentPolicy.
    function initializeAgent(
        InitParams calldata p,
        address feeManager_,
        IFeeManager.FeeConfig calldata cfg,
        uint16 maxTradeBps_,
        address policy_
    ) external initializer {
        if (policy_ == address(0)) revert PolicyNotSet();
        __VaultPortfolio_init(p, feeManager_, cfg, maxTradeBps_);
        policy = AgentPolicy(policy_);
    }

    /// @notice Agent trade — identical to a vault trade but gated by the AgentPolicy.
    /// @dev SECURITY: MANAGER(=agent) only (enforced by super). Checkpoints NAV (drawdown kill switch),
    ///      executes the swap, then records the trade against the policy; any breach reverts the whole
    ///      action atomically. The agent can never exceed the policy's hard limits.
    function executeTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        public
        override
        returns (uint256 amountOut)
    {
        uint256 nav = totalNAV();
        // Trip the drawdown kill switch before acting; recordTrade below will reject if killed.
        policy.checkpointNav(navPerShare());

        uint256 tradeValue = _usdValue(tokenIn, amountIn);
        amountOut = super.executeTrade(tokenIn, tokenOut, amountIn, minOut, deadline);

        // The quote stablecoin is the USD numéraire and is never position-capped.
        uint256 positionAfter =
            tokenOut == address(quote) ? 0 : _valueOf(tokenOut, IERC20(tokenOut).balanceOf(address(this)));
        policy.recordTrade(tokenOut, tradeValue, positionAfter, nav);
        emit AgentTrade(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev USD value of `amount` of `asset`; the quote stablecoin counts 1:1 (no oracle entry needed).
    function _usdValue(address asset, uint256 amount) internal view returns (uint256) {
        if (asset == address(quote)) return amount;
        return _valueOf(asset, amount);
    }

    /// @notice Permissionlessly checkpoint NAV to enforce the drawdown kill switch.
    /// @dev SECURITY: anyone may poke; updates high-water and trips the kill switch on excess drawdown.
    function checkpoint() external {
        uint256 nps = navPerShare();
        policy.checkpointNav(nps);
        emit NavCheckpointed(nps);
    }

    /// @notice Whether the agent is currently permitted to trade.
    function agentActive() external view returns (bool) {
        return policy.active();
    }
}
