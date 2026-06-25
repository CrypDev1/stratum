// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { PortfolioBase } from "../../src/core/PortfolioBase.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IndexPortfolioTest is Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
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

        vm.prank(alice);
        address p = factory.createIndex(
            "AI Index", "AINDEX", address(usdc), _equalComponents(), 100, admin, address(strat), 200, 2000
        );
        index = IndexPortfolio(p);
        shareToken = PortfolioToken(index.shareToken());
    }

    function _mint(address user, uint256 amount) internal returns (uint256 shares) {
        _fundUSDC(user, amount);
        vm.startPrank(user);
        usdc.approve(address(index), amount);
        shares = index.mint(amount, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_firstMintNavPerShareIsOne() public {
        uint256 shares = _mint(alice, 1_000e18);
        assertEq(index.navPerShare(), 1e18);
        assertApproxEqAbs(shares, 1_000e18, 1e6);
        assertApproxEqAbs(index.totalNAV(), 1_000e18, 1e6);
    }

    function test_componentsAllocatedByWeight() public {
        _mint(alice, 1_000e18);
        // $500 of AAPL @ $200 = 2.5; $500 of GOOG @ $150 = 3.333
        assertApproxEqAbs(aapl.balanceOf(address(index)), 2.5e18, 1e6);
        assertApproxEqAbs(goog.balanceOf(address(index)), 3333333333333333333, 1e6);
    }

    function test_secondMintFairShares() public {
        _mint(alice, 1_000e18);
        uint256 bobShares = _mint(bob, 500e18);
        assertApproxEqAbs(bobShares, 500e18, 1e9);
        // navPerShare unchanged at parity
        assertApproxEqAbs(index.navPerShare(), 1e18, 1e6);
    }

    function test_redeemInKindProRata() public {
        _mint(alice, 1_000e18);
        uint256 shares = shareToken.balanceOf(alice);
        uint256 aaplBefore = aapl.balanceOf(address(index));
        uint256 googBefore = goog.balanceOf(address(index));

        vm.prank(alice);
        index.redeem(shares / 2);

        // got half of each component
        assertApproxEqAbs(aapl.balanceOf(alice), aaplBefore / 2, 1e6);
        assertApproxEqAbs(goog.balanceOf(alice), googBefore / 2, 1e6);
        assertApproxEqAbs(shareToken.balanceOf(alice), shares / 2, 1);
    }

    function test_redeemWorksWhenPaused() public {
        _mint(alice, 1_000e18);
        vm.prank(admin);
        index.pause();
        uint256 shares = shareToken.balanceOf(alice);
        vm.prank(alice);
        index.redeem(shares); // should not revert
        assertEq(shareToken.balanceOf(alice), 0);
    }

    function test_mintRevertsWhenPaused() public {
        vm.prank(admin);
        index.pause();
        _fundUSDC(alice, 100e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 100e18);
        vm.expectRevert();
        index.mint(100e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_mintRevertsOnDeadline() public {
        _fundUSDC(alice, 100e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 100e18);
        vm.expectRevert(PortfolioBase.DeadlinePassed.selector);
        index.mint(100e18, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_mintRevertsOnSlippage() public {
        _fundUSDC(alice, 100e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 100e18);
        vm.expectRevert(PortfolioBase.SlippageExceeded.selector);
        index.mint(100e18, 1_000e18, block.timestamp + 1); // demand way too many shares
        vm.stopPrank();
    }

    function test_mintHaltedAssetReverts() public {
        vm.prank(admin);
        monitor.setHalted(address(aapl), true);
        _fundUSDC(alice, 100e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 100e18);
        vm.expectRevert(abi.encodeWithSelector(PortfolioBase.TradingUnsafe.selector, address(aapl)));
        index.mint(100e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_rebalanceTowardTarget() public {
        _mint(alice, 1_000e18);
        // Skew weights: AAPL price doubles -> AAPL now overweight.
        aaplFeed.setPrice(400e18);
        aaplDex.setPrice(400e18);
        router.setPrice(address(aapl), 400e18);

        // Now AAPL value = 2.5 * 400 = 1000, GOOG = 500 => total 1500; weights 66/33, target 50/50.
        uint256 navBefore = index.totalNAV();
        vm.prank(admin);
        index.rebalance(block.timestamp + 1);

        // After rebalance AAPL and GOOG values should be closer to equal (within tolerance + maxTrade cap).
        (uint256 aPrice,,) = oracle.getPrice(address(aapl));
        (uint256 gPrice,,) = oracle.getPrice(address(goog));
        uint256 aVal = aapl.balanceOf(address(index)) * aPrice / 1e18;
        uint256 gVal = goog.balanceOf(address(index)) * gPrice / 1e18;
        assertGt(gVal, 500e18); // GOOG bought up
        assertLt(aVal, 1_000e18); // AAPL sold down
        // NAV approximately conserved (parity swaps)
        assertApproxEqRel(index.totalNAV(), navBefore, 0.01e18);
    }

    function test_onlyRebalancerCanRebalance() public {
        _mint(alice, 1_000e18);
        vm.prank(bob);
        vm.expectRevert();
        index.rebalance(block.timestamp + 1);
    }

    function testFuzz_mintRedeemRoundTripPreservesNav(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);
        _mint(alice, amount);
        assertApproxEqRel(index.navPerShare(), 1e18, 0.0001e18);
        uint256 shares = shareToken.balanceOf(alice);
        vm.prank(alice);
        index.redeem(shares);
        // all shares burned
        assertEq(shareToken.totalSupply(), 0);
    }

    /// @dev Arbitrage peg invariant: navPerShare stays at peg (1e18) under parity within rounding.
    function testFuzz_pegInvariant(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1e18, 100_000e18);
        a2 = bound(a2, 1e18, 100_000e18);
        _mint(alice, a1);
        _mint(bob, a2);
        // token value (navPerShare * supply) <= underlying NAV (fully backed)
        uint256 supply = shareToken.totalSupply();
        uint256 tokenValue = index.navPerShare() * supply / 1e18;
        assertLe(tokenValue, index.totalNAV() + 1e12);
        assertGe(index.navPerShare(), 1e18 - 1e6);
    }
}
