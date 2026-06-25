// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { AgentRegistry } from "../../src/agents/AgentRegistry.sol";

contract AgentRegistryTest is Test {
    AgentRegistry internal reg;
    address internal vault = address(0xBEEF);
    address internal controller = address(0xC07);

    function setUp() public {
        reg = new AgentRegistry();
    }

    function test_register() public {
        vm.prank(controller);
        uint256 id = reg.register(vault, "Tech Momentum");
        assertEq(id, 0);
        assertEq(reg.agentIdOfVault(vault), 1);
        AgentRegistry.AgentRecord memory a = reg.getAgent(id);
        assertEq(a.controller, controller);
        assertEq(a.vault, vault);
        assertEq(a.name, "Tech Momentum");
    }

    function test_cannotDoubleRegister() public {
        reg.register(vault, "A");
        vm.expectRevert(AgentRegistry.AlreadyRegistered.selector);
        reg.register(vault, "B");
    }

    function test_onlyVaultReports() public {
        reg.register(vault, "A");
        vm.prank(address(0xBAD));
        vm.expectRevert(AgentRegistry.NotVault.selector);
        reg.reportNav(1.1e18);
    }

    function test_trackRecordAccumulates() public {
        uint256 id = reg.register(vault, "A");
        vm.startPrank(vault);
        reg.reportNav(1.1e18); // +10% vs 1.0
        reg.reportNav(1.21e18); // +10% vs 1.1
        vm.stopPrank();

        AgentRegistry.AgentRecord memory a = reg.getAgent(id);
        assertEq(a.epochs, 2);
        assertEq(a.lastNav, 1.21e18);
        // cumulative ~ 1000 + 1000 bps
        assertApproxEqAbs(uint256(a.cumulativeReturnBps), 2000, 2);
    }

    function test_negativeReturnRecorded() public {
        uint256 id = reg.register(vault, "A");
        vm.startPrank(vault);
        reg.reportNav(1.2e18); // +2000 bps
        reg.reportNav(0.9e18); // -2500 bps vs 1.2
        vm.stopPrank();
        AgentRegistry.AgentRecord memory a = reg.getAgent(id);
        assertLt(a.cumulativeReturnBps, 2000);
        assertEq(a.epochs, 2);
    }

    function test_appendOnlyEpochs() public {
        reg.register(vault, "A");
        vm.startPrank(vault);
        for (uint256 i; i < 5; ++i) {
            reg.reportNav(1e18 + i * 1e16);
        }
        vm.stopPrank();
        assertEq(reg.getAgent(0).epochs, 5); // monotonic, tamper-evident counter
    }
}
