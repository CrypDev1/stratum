// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { AgentVault } from "../../src/agents/AgentVault.sol";
import { AgentPolicy } from "../../src/agents/AgentPolicy.sol";
import { VaultPortfolio } from "../../src/core/VaultPortfolio.sol";
import { PortfolioBase } from "../../src/core/PortfolioBase.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { IFeeManager } from "../../src/interfaces/IFeeManager.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract AgentVaultTest is Fixtures {
    AgentVault internal vault;
    AgentPolicy internal policy;
    PortfolioToken internal shareToken;
    address internal agent = address(0xA6E27);

    function setUp() public {
        _deployL0();
        _deployFactory();

        // Policy: max 60% position, 50% turnover/epoch, 20% drawdown kill, 1-day epoch, 1-day timelock.
        policy = new AgentPolicy(
            admin,
            AgentPolicy.Params({
                maxPositionBps: 6000, maxTurnoverPerEpochBps: 5000, maxDrawdownBps: 2000, epochLength: 1 days
            }),
            1 days
        );

        address impl = address(new AgentVault());
        vault = AgentVault(Clones.clone(impl));

        PortfolioBase.InitParams memory p = PortfolioBase.InitParams({
            nav: address(oracle),
            poc: address(poc),
            depeg: address(monitor),
            router: address(router),
            quoteAsset: address(usdc),
            name: "Agent AI",
            symbol: "aAI",
            components: _equalComponents(),
            maxSlippageBps: 100,
            admin: admin
        });
        IFeeManager.FeeConfig memory cfg = IFeeManager.FeeConfig({
            managementFeeBps: 200,
            performanceFeeBps: 2000,
            protocolCutBps: 1000,
            manager: agent, // the agent executor is the "manager"
            protocol: treasury
        });
        vault.initializeAgent(p, address(feeManager), cfg, 5000, address(policy));
        shareToken = PortfolioToken(vault.shareToken());

        vm.startPrank(admin);
        policy.setVault(address(vault));
        policy.setWhitelist(address(aapl), true);
        policy.setWhitelist(address(goog), true);
        policy.setWhitelist(address(usdc), true);
        vm.stopPrank();

        // seed the vault with deposits
        _fundUSDC(alice, 10_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e18);
        vault.mint(10_000e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function _agentTrade(address tin, address tout, uint256 amt) internal returns (uint256) {
        vm.prank(agent);
        return vault.executeTrade(tin, tout, amt, 0, block.timestamp + 1);
    }

    function test_agentCanTradeWithinPolicy() public {
        // sell a little AAPL to USDC (small turnover, reduces AAPL position)
        uint256 out = _agentTrade(address(aapl), address(usdc), 1e18); // $200 trade
        assertGt(out, 0);
    }

    function test_nonAgentCannotTrade() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.executeTrade(address(aapl), address(usdc), 1e18, 0, block.timestamp + 1);
    }

    function test_turnoverCapRejects() public {
        // NAV ~10000; 50% turnover cap => $5000/epoch. maxTradeBps=5000 also caps single trade at $5000.
        // Two $5000-ish trades in one epoch should breach turnover.
        // AAPL holds $5000; sell $2500 worth (12.5 AAPL) twice.
        _agentTrade(address(aapl), address(usdc), 12.5e18); // ~$2500
        _agentTrade(address(goog), address(usdc), 16e18); // ~$2400, cumulative ~4900 < 5000 ok
        // third pushes over
        vm.prank(agent);
        vm.expectRevert(AgentPolicy.TurnoverExceeded.selector);
        vault.executeTrade(address(aapl), address(usdc), 5e18, 0, block.timestamp + 1); // +$1000 -> >5000
    }

    function test_positionSizeCapRejects() public {
        // Buying more AAPL until >60% of NAV should revert. Start: AAPL is 50%.
        // Sell GOOG -> AAPL to push AAPL over 60%.
        vm.prank(agent);
        vm.expectRevert(AgentPolicy.PositionTooLarge.selector);
        // buy ~$2000 AAPL using GOOG: AAPL would become ~70% -> rejected
        vault.executeTrade(address(goog), address(aapl), 20e18, 0, block.timestamp + 1); // $3000 of GOOG->AAPL
    }

    function test_notWhitelistedRejects() public {
        vm.prank(admin);
        policy.setWhitelist(address(aapl), false);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPolicy.AssetNotAllowed.selector, address(aapl)));
        vault.executeTrade(address(goog), address(aapl), 1e18, 0, block.timestamp + 1);
    }

    function test_drawdownKillSwitch() public {
        // checkpoint at current high, then crash price 25% (> 20% drawdown) -> kill switch trips on next action
        vault.checkpoint();
        _setAaplPrice(AAPL_PRICE * 70 / 100);
        _setGoogPrice(GOOG_PRICE * 70 / 100);
        vault.checkpoint(); // trips kill
        assertFalse(vault.agentActive());

        vm.prank(agent);
        vm.expectRevert(AgentPolicy.AgentKilled.selector);
        vault.executeTrade(address(aapl), address(usdc), 1e18, 0, block.timestamp + 1);
    }

    function test_paramChangeTimelocked() public {
        AgentPolicy.Params memory np = AgentPolicy.Params({
            maxPositionBps: 9000, maxTurnoverPerEpochBps: 9000, maxDrawdownBps: 5000, epochLength: 1 days
        });
        vm.prank(admin);
        policy.proposeParams(np);
        // cannot apply before delay
        vm.prank(admin);
        vm.expectRevert(AgentPolicy.TimelockNotReady.selector);
        policy.applyParams();
        // after delay
        skip(1 days + 1);
        vm.prank(admin);
        policy.applyParams();
        (uint16 maxPos,,,) = policy.params();
        assertEq(maxPos, 9000);
    }

    function testFuzz_maliciousAgentBounded(uint256 amt, bool dir) public {
        amt = bound(amt, 1e15, 1_000e18);
        address tin = dir ? address(goog) : address(aapl);
        address tout = dir ? address(aapl) : address(goog);
        vm.prank(agent);
        try vault.executeTrade(tin, tout, amt, 0, block.timestamp + 1) {
            // if it succeeded, the resulting position must be within the policy cap
            uint256 nav = vault.totalNAV();
            (uint256 price,,) = oracle.getPrice(tout);
            uint256 posVal = aapl.balanceOf(address(vault)); // approximate check below
            posVal; // silence
            uint256 outVal = (IERC20Like(tout).balanceOf(address(vault)) * price) / 1e18;
            assertLe(outVal * 10_000, nav * 6000 + 1e18);
        } catch {
            // reverts are acceptable (policy rejected an out-of-bounds action)
        }
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
