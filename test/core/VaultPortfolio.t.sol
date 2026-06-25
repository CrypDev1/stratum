// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { VaultPortfolio } from "../../src/core/VaultPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { PortfolioBase } from "../../src/core/PortfolioBase.sol";

contract VaultPortfolioTest is Fixtures {
    VaultPortfolio internal vault;
    PortfolioToken internal shareToken;
    address internal manager = address(0x9A9A);

    function setUp() public {
        _deployL0();
        _deployFactory();

        vm.prank(alice);
        address p = factory.createVault(
            "Managed Tech", "MTECH", address(usdc), _equalComponents(), 100, admin, manager, 200, 2000, 3000
        );
        vault = VaultPortfolio(p);
        shareToken = PortfolioToken(vault.shareToken());
    }

    function _mint(address user, uint256 amount) internal returns (uint256 shares) {
        _fundUSDC(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.mint(amount, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_mintWorks() public {
        uint256 shares = _mint(alice, 1_000e18);
        assertApproxEqAbs(shares, 1_000e18, 1e6);
        assertEq(vault.navPerShare(), 1e18);
    }

    function test_managementFeeAccrues() public {
        _mint(alice, 1_000e18);
        uint256 supplyBefore = shareToken.totalSupply();
        skip(365 days);
        _refreshFeeds(); // keep prices fresh after time travel
        vault.accrueFees();
        uint256 minted = shareToken.totalSupply() - supplyBefore;
        // 2% mgmt fee -> ~2% dilution
        assertApproxEqRel(minted, supplyBefore * 200 / 10000, 0.05e18);
        // protocol gets 10% cut, manager 90%
        uint256 protoBal = shareToken.balanceOf(treasury);
        uint256 mgrBal = shareToken.balanceOf(manager);
        assertApproxEqRel(protoBal, minted * 1000 / 10000, 0.02e18);
        assertApproxEqRel(mgrBal, minted * 9000 / 10000, 0.02e18);
    }

    function test_performanceFeeOnGain() public {
        _mint(alice, 1_000e18);
        // Price appreciation: AAPL & GOOG +20%
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);

        assertApproxEqRel(vault.navPerShare(), 1.2e18, 0.001e18);
        uint256 mgrBefore = shareToken.balanceOf(manager);
        vault.accrueFees();
        assertGt(shareToken.balanceOf(manager), mgrBefore); // perf fee minted
        // HWM updated to ~1.2
        assertApproxEqRel(vault.highWaterMark(), 1.2e18, 0.01e18);
    }

    function test_noPerformanceFeeWithoutNewHigh() public {
        _mint(alice, 1_000e18);
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);
        vault.accrueFees(); // sets HWM ~1.2, takes fee

        // price falls back -> no new perf fee
        _setAaplPrice(AAPL_PRICE);
        _setGoogPrice(GOOG_PRICE);
        uint256 mgrBal = shareToken.balanceOf(manager);
        vault.accrueFees(); // below HWM, mgmt fee ~0 (no time elapsed)
        assertEq(shareToken.balanceOf(manager), mgrBal);
    }

    function test_managerExecuteTrade() public {
        _mint(alice, 1_000e18);
        uint256 aaplBefore = aapl.balanceOf(address(vault));
        // sell 1 AAPL for USDC
        vm.prank(manager);
        vault.executeTrade(address(aapl), address(usdc), 1e18, 0, block.timestamp + 1);
        assertEq(aapl.balanceOf(address(vault)), aaplBefore - 1e18);
        assertGt(usdc.balanceOf(address(vault)), 0);
    }

    function test_executeTradeNonWhitelistedReverts() public {
        _mint(alice, 1_000e18);
        address rando = address(new MockUnlisted());
        vm.prank(manager);
        vm.expectRevert();
        vault.executeTrade(address(aapl), rando, 1e18, 0, block.timestamp + 1);
    }

    function test_executeTradeTooLargeReverts() public {
        _mint(alice, 1_000e18);
        // maxTradeBps = 3000 (30% of NAV $1000 = $300). 2 AAPL = $400 > cap.
        vm.prank(manager);
        vm.expectRevert(VaultPortfolio.TradeTooLarge.selector);
        vault.executeTrade(address(aapl), address(usdc), 2e18, 0, block.timestamp + 1);
    }

    function test_onlyManagerTrades() public {
        _mint(alice, 1_000e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.executeTrade(address(aapl), address(usdc), 1e18, 0, block.timestamp + 1);
    }

    function test_setTargetWeights() public {
        uint256[] memory ws = new uint256[](2);
        ws[0] = 7000;
        ws[1] = 3000;
        vm.prank(manager);
        vault.setTargetWeights(ws);
        assertEq(vault.targetWeights(0), 7000);
    }

    function test_setTargetWeightsBadSumReverts() public {
        uint256[] memory ws = new uint256[](2);
        ws[0] = 7000;
        ws[1] = 4000;
        vm.prank(manager);
        vm.expectRevert(VaultPortfolio.InvalidParams.selector);
        vault.setTargetWeights(ws);
    }

    function test_depositorNotChargedPerfOnOwnCapital() public {
        _mint(alice, 1_000e18);
        // gain to set up
        _setAaplPrice(AAPL_PRICE * 12 / 10);
        _setGoogPrice(GOOG_PRICE * 12 / 10);
        vault.accrueFees(); // HWM ~1.2

        uint256 mgrBefore = shareToken.balanceOf(manager);
        // Bob deposits; his capital must not trigger a perf fee.
        _mint(bob, 1_000e18);
        assertApproxEqRel(shareToken.balanceOf(manager), mgrBefore, 0.001e18);
    }
}

contract MockUnlisted {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
