// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { PortfolioFactory } from "../../src/core/PortfolioFactory.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";

contract PortfolioFactoryTest is Fixtures {
    FixedWeightStrategy internal strat;

    function setUp() public {
        _deployL0();
        _deployFactory();
        strat = new FixedWeightStrategy(admin);
        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(goog);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 5000;
        ws[1] = 5000;
        vm.prank(admin);
        strat.setWeights(assets, ws);
    }

    function _createIndex() internal returns (address) {
        return factory.createIndex("AI", "AI", address(usdc), _equalComponents(), 100, admin, address(strat), 200, 2000);
    }

    function test_createIndexRegisters() public {
        address p = _createIndex();
        assertTrue(factory.isPortfolio(p));
        assertEq(factory.portfolioCount(), 1);
        assertEq(factory.allPortfolios(0), p);
    }

    function test_createVaultRegisters() public {
        address p = factory.createVault(
            "V", "V", address(usdc), _equalComponents(), 100, admin, address(0x9), 200, 2000, 3000
        );
        assertTrue(factory.isPortfolio(p));
    }

    function test_rejectsUnhealthyAsset() public {
        // GOOG attestation breaches -> not healthy
        vm.prank(admin);
        poc.attest(address(goog), 5000, bytes32("bad"));
        vm.expectRevert(abi.encodeWithSelector(PortfolioFactory.UnhealthyAsset.selector, address(goog)));
        _createIndex();
    }

    function test_rejectsUnsafeAsset() public {
        vm.prank(admin);
        monitor.setHalted(address(aapl), true);
        vm.expectRevert(abi.encodeWithSelector(PortfolioFactory.UnsafeAsset.selector, address(aapl)));
        _createIndex();
    }

    function test_protocolCutForcedFromFactory() public {
        // Even if a creator wanted 0 protocol cut, factory injects its configured cut (1000 bps).
        address p = factory.createVault(
            "V", "V", address(usdc), _equalComponents(), 100, admin, address(0x9), 200, 2000, 3000
        );
        // read fee config via the vault
        (,, uint16 protocolCutBps,,) = _readVaultCut(p);
        assertEq(protocolCutBps, 1000);
    }

    function _readVaultCut(address vault)
        internal
        view
        returns (uint16 m, uint16 perf, uint16 cut, address mgr, address proto)
    {
        // FeeConfig public getter returns the tuple
        (m, perf, cut, mgr, proto) = VaultLike(vault).feeConfig();
    }

    function test_onlyAdminSetsWiring() public {
        PortfolioFactory.Wiring memory w;
        vm.prank(bob);
        vm.expectRevert();
        factory.setWiring(w);
    }
}

interface VaultLike {
    function feeConfig() external view returns (uint16, uint16, uint16, address, address);
}
