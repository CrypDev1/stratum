// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "../core/Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { YieldSplitter } from "../../src/structured/YieldSplitter.sol";
import { ControlledToken } from "../../src/structured/ControlledToken.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";

contract YieldSplitterTest is Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
    YieldSplitter internal splitter;
    ControlledToken internal pt;
    ControlledToken internal yt;

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

        splitter = new YieldSplitter(IPortfolio(address(index)), block.timestamp + 30 days, "Principal", "Yield");
        pt = splitter.pt();
        yt = splitter.yt();

        // alice mints shares then splits
        _fundUSDC(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 1_000e18);
        index.mint(1_000e18, 0, block.timestamp + 1);
        shareToken.approve(address(splitter), type(uint256).max);
        vm.stopPrank();
    }

    function _splitAll() internal returns (uint256 value) {
        uint256 bal = shareToken.balanceOf(alice);
        vm.prank(alice);
        value = splitter.split(bal);
    }

    function test_splitMintsEqualPtYt() public {
        uint256 value = _splitAll();
        assertApproxEqAbs(pt.balanceOf(alice), value, 1);
        assertApproxEqAbs(yt.balanceOf(alice), value, 1);
        assertApproxEqRel(value, 1_000e18, 0.01e18);
    }

    function test_reconstructInvariant() public {
        _splitAll();
        assertEq(splitter.underlyingValue(), splitter.ptValue() + splitter.ytValue());
        // appreciate
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        assertEq(splitter.underlyingValue(), splitter.ptValue() + splitter.ytValue());
    }

    function test_yieldAccruesToYT() public {
        _splitAll();
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        // ~10% gain -> ytValue ~ 100
        assertApproxEqRel(splitter.ytValue(), 100e18, 0.02e18);
        assertApproxEqRel(splitter.pendingYield(alice), 100e18, 0.02e18);
    }

    function test_claimYield() public {
        _splitAll();
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        uint256 before = shareToken.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = splitter.claimYield();
        assertGt(shares, 0);
        assertEq(shareToken.balanceOf(alice) - before, shares);
        // after claim, principal still fully backed, no residual yield
        assertApproxEqAbs(splitter.ytValue(), 0, 1e12);
    }

    function test_combineBeforeMaturity() public {
        uint256 value = _splitAll();
        vm.prank(alice);
        uint256 shares = splitter.combine(value / 2);
        assertGt(shares, 0);
        assertApproxEqAbs(pt.balanceOf(alice), value / 2, 1);
        assertApproxEqAbs(yt.balanceOf(alice), value / 2, 1);
    }

    function test_redeemPrincipalAtMaturity() public {
        uint256 value = _splitAll();
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds(); // keep prices fresh

        uint256 before = shareToken.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = splitter.redeemPrincipal(value);
        // principal redeems for value-worth of shares at current index (~1.1)
        uint256 nps = index.navPerShare();
        assertApproxEqRel(shares * nps / 1e18, value, 0.01e18);
        assertEq(shareToken.balanceOf(alice) - before, shares);
    }

    function test_cannotRedeemPrincipalBeforeMaturity() public {
        uint256 value = _splitAll();
        vm.prank(alice);
        vm.expectRevert(YieldSplitter.NotMatured.selector);
        splitter.redeemPrincipal(value);
    }

    function test_cannotSplitAfterMaturity() public {
        vm.warp(block.timestamp + 31 days);
        _refreshFeeds();
        vm.prank(alice);
        vm.expectRevert(YieldSplitter.AlreadyMatured.selector);
        splitter.split(1e18);
    }

    function testFuzz_reconstructUnderArbitraryYield(uint256 priceMul) public {
        _splitAll();
        priceMul = bound(priceMul, 10_000, 30_000); // 1x .. 3x (yield-bearing => non-decreasing)
        _setAaplPrice(AAPL_PRICE * priceMul / 10_000);
        _setGoogPrice(GOOG_PRICE * priceMul / 10_000);
        assertEq(splitter.underlyingValue(), splitter.ptValue() + splitter.ytValue());
        assertGe(splitter.underlyingValue(), splitter.ptValue()); // principal always backed
    }
}
