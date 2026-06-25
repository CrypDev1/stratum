// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { TrancheVault } from "../../src/structured/TrancheVault.sol";
import { ControlledToken } from "../../src/structured/ControlledToken.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";

contract TrancheVaultTest is Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
    TrancheVault internal vault;
    ControlledToken internal senior;
    ControlledToken internal junior;

    address internal srUser = address(0x5E);
    address internal jrUser = address(0x10);

    function setUp() public {
        _deployL0();
        _deployFactory();
        FixedWeightStrategy strat = new FixedWeightStrategy(admin);
        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(goog);
        uint256[] memory ws = new uint256[](2);
        ws[0] = 5000;
        ws[1] = 5000;
        vm.prank(admin);
        strat.setWeights(assets, ws);
        index = IndexPortfolio(
            factory.createIndex("AI", "AI", address(usdc), _equalComponents(), 100, admin, address(strat), 200, 2000)
        );
        shareToken = PortfolioToken(index.shareToken());

        // 30-day term, 5% senior coupon cap, max 70% senior coverage.
        vault = new TrancheVault(admin, IPortfolio(address(index)), block.timestamp + 30 days, 500, 7000);
        senior = vault.senior();
        junior = vault.junior();
    }

    function _depositSenior(address user, uint256 amount) internal {
        _fundUSDC(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.depositSenior(amount, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function _depositJunior(address user, uint256 amount) internal {
        _fundUSDC(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.depositJunior(amount, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function _setup6040() internal {
        _depositSenior(srUser, 600e18);
        _depositJunior(jrUser, 400e18);
        vm.prank(admin);
        vault.activate();
    }

    function test_depositsAndActivate() public {
        _setup6040();
        assertApproxEqRel(vault.seniorPrincipal(), 600e18, 0.01e18);
        assertApproxEqRel(vault.juniorPrincipal(), 400e18, 0.01e18);
        assertEq(uint256(vault.phase()), 1); // Active
    }

    function test_coverageBreachReverts() public {
        _depositSenior(srUser, 800e18);
        _depositJunior(jrUser, 200e18); // senior 80% > 70% cap
        vm.prank(admin);
        vm.expectRevert(TrancheVault.CoverageBreached.selector);
        vault.activate();
    }

    function test_settleGain_seniorCappedJuniorUpside() public {
        _setup6040();
        // +20% gain
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vault.settle();

        uint256 nps = index.navPerShare();
        // senior gets capped claim 600*1.05 = 630
        uint256 srShares = vault.seniorSharesPool();
        assertApproxEqRel(srShares * nps / 1e18, 630e18, 0.01e18);
        // junior gets the rest: total ~1200 - 630 = 570
        uint256 jrShares = vault.juniorSharesPool();
        assertApproxEqRel(jrShares * nps / 1e18, 570e18, 0.02e18);
    }

    function test_settleLoss_seniorProtectedJuniorFirstLoss() public {
        _setup6040();
        // -30% loss -> total ~700; senior claim 630 -> senior takes 630, junior 70
        _setAaplPrice(AAPL_PRICE * 7 / 10);
        _setGoogPrice(GOOG_PRICE * 7 / 10);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vault.settle();

        uint256 nps = index.navPerShare();
        uint256 srVal = vault.seniorSharesPool() * nps / 1e18;
        uint256 jrVal = vault.juniorSharesPool() * nps / 1e18;
        assertApproxEqRel(srVal, 630e18, 0.02e18); // senior still ~protected
        assertApproxEqRel(jrVal, 70e18, 0.05e18); // junior absorbs loss
    }

    function test_settleSevereLoss_juniorWiped() public {
        _setup6040();
        // -50% -> total ~600 < senior claim 630 -> senior takes all, junior wiped
        _setAaplPrice(AAPL_PRICE / 2);
        _setGoogPrice(GOOG_PRICE / 2);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vault.settle();

        assertEq(vault.juniorSharesPool(), 0);
        assertEq(vault.seniorSharesPool(), shareToken.balanceOf(address(vault)));
    }

    function test_redeemAfterSettle() public {
        _setup6040();
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vault.settle();

        uint256 srAmount = senior.balanceOf(srUser);
        vm.prank(srUser);
        uint256 srShares = vault.redeemSenior(srAmount);
        assertGt(srShares, 0);
        assertEq(shareToken.balanceOf(srUser), srShares);

        uint256 jrAmount = junior.balanceOf(jrUser);
        vm.prank(jrUser);
        uint256 jrShares = vault.redeemJunior(jrAmount);
        assertGt(jrShares, 0);
    }

    function test_cannotDepositAfterActivate() public {
        _setup6040();
        _fundUSDC(srUser, 100e18);
        vm.startPrank(srUser);
        usdc.approve(address(vault), 100e18);
        vm.expectRevert(TrancheVault.WrongPhase.selector);
        vault.depositSenior(100e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @dev Waterfall invariant: senior always receives >= its principal until junior is fully wiped.
    function testFuzz_seniorPriorityOverJunior(uint256 priceMul) public {
        _setup6040();
        priceMul = bound(priceMul, 3_000, 20_000); // -70% .. +100%
        _setAaplPrice(AAPL_PRICE * priceMul / 10_000);
        _setGoogPrice(GOOG_PRICE * priceMul / 10_000);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vault.settle();

        uint256 nps = index.navPerShare();
        uint256 srVal = vault.seniorSharesPool() * nps / 1e18;
        uint256 jrVal = vault.juniorSharesPool() * nps / 1e18;

        if (jrVal > 0) {
            // junior still has value => senior must be fully covered to its principal
            assertGe(srVal + 1e15, vault.seniorPrincipal());
        }
        // proceeds fully distributed (no shares stranded)
        assertEq(vault.seniorSharesPool() + vault.juniorSharesPool(), shareToken.balanceOf(address(vault)));
    }
}
