// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures} from "./core/Fixtures.sol";
import {IndexPortfolio} from "../src/core/IndexPortfolio.sol";
import {PortfolioToken} from "../src/core/PortfolioToken.sol";
import {FixedWeightStrategy} from "../src/core/strategies/FixedWeightStrategy.sol";
import {YieldSplitter} from "../src/structured/YieldSplitter.sol";
import {ControlledToken} from "../src/structured/ControlledToken.sol";
import {LiquidityPool} from "../src/derivatives/LiquidityPool.sol";
import {PerpEngine} from "../src/derivatives/PerpEngine.sol";
import {STRAT} from "../src/token/STRAT.sol";
import {veSTRAT} from "../src/token/veSTRAT.sol";
import {GaugeController} from "../src/token/GaugeController.sol";
import {FeeDistributor} from "../src/token/FeeDistributor.sol";

import {IPortfolio} from "../src/interfaces/IPortfolio.sol";
import {INAVOracle} from "../src/interfaces/INAVOracle.sol";
import {IDepegMonitor} from "../src/interfaces/IDepegMonitor.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Stratum end-to-end composition test
/// @notice One test that exercises the whole stack: create an AI Index → mint → earn yield → split into
///         PT/YT → open a perp against it → vote a gauge → claim fees. Proves the layers compose through
///         their interfaces, off the same L0 oracle.
contract IntegrationE2ETest is Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;

    function setUp() public {
        _deployL0();
        _deployFactory();
    }

    function test_fullStackComposes() public {
        // ── 1. Create an "AI Index" (tokenized tech-stock basket) via the permissionless factory ──
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
            factory.createIndex(
                "AI Tech Index", "AITECH", address(usdc), _equalComponents(), 100, admin, address(strat), 200, 2000
            )
        );
        shareToken = PortfolioToken(index.shareToken());
        assertTrue(factory.isPortfolio(address(index)));

        // ── 2. Mint: Alice deposits $10k USDC and receives index shares (NAV-fair) ──
        _fundUSDC(alice, 10_000e18);
        vm.startPrank(alice);
        usdc.approve(address(index), 10_000e18);
        uint256 shares = index.mint(10_000e18, 0, block.timestamp + 1);
        vm.stopPrank();
        assertApproxEqRel(shares, 10_000e18, 0.01e18);
        assertApproxEqRel(index.navPerShare(), 1e18, 0.01e18);

        // ── 3. Earn yield: the underlying tech stocks appreciate +10% → navPerShare grows ──
        _setAaplPrice(AAPL_PRICE * 11 / 10);
        _setGoogPrice(GOOG_PRICE * 11 / 10);
        assertApproxEqRel(index.navPerShare(), 1.1e18, 0.01e18);

        // ── 4. Split into PT/YT: wrap the yield-bearing index token via the YieldSplitter ──
        YieldSplitter splitter =
            new YieldSplitter(IPortfolio(address(index)), block.timestamp + 90 days, "AI Principal", "AI Yield");
        ControlledToken pt = splitter.pt();
        ControlledToken yt = splitter.yt();

        uint256 half = shares / 2;
        vm.startPrank(alice);
        shareToken.approve(address(splitter), half);
        uint256 value = splitter.split(half);
        vm.stopPrank();
        assertApproxEqAbs(pt.balanceOf(alice), value, 1);
        assertApproxEqAbs(yt.balanceOf(alice), value, 1);
        // PT + YT reconstructs the wrapped asset
        assertEq(splitter.underlyingValue(), splitter.ptValue() + splitter.ytValue());

        // ── 5. Open a perp against the index's exposure (priced off the same L0 oracle) ──
        LiquidityPool pool = new LiquidityPool(admin, IERC20(address(usdc)));
        PerpEngine perp = new PerpEngine(
            admin, IERC20(address(usdc)), INAVOracle(address(oracle)), IDepegMonitor(address(monitor)), pool, address(aapl)
        );
        vm.prank(admin);
        pool.setEngine(address(perp));
        // LP seeds the perp pool
        _fundUSDC(bob, 500_000e18);
        vm.startPrank(bob);
        usdc.approve(address(pool), 500_000e18);
        pool.deposit(500_000e18);
        vm.stopPrank();
        // Alice opens a 3x long on the index's headline name
        _fundUSDC(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(perp), 1_000e18);
        uint256 posId = perp.open(1_000e18, 10e18, true, block.timestamp + 1);
        vm.stopPrank();
        (address powner,,,,,,) = perp.positions(posId);
        assertEq(powner, alice);

        // ── 6. Vote a gauge: lock STRAT → veSTRAT, register a gauge for the index, direct emissions ──
        STRAT stratTok = new STRAT(admin, 10_000_000e18);
        veSTRAT ve = new veSTRAT(IERC20(address(stratTok)));
        GaugeController gauges = new GaugeController(admin, ve);

        vm.startPrank(admin);
        stratTok.transfer(alice, 100_000e18);
        gauges.addGauge(address(index)); // the index gets a gauge
        vm.stopPrank();

        uint256 mt = ve.MAXTIME();
        vm.startPrank(alice);
        stratTok.approve(address(ve), 100_000e18);
        ve.createLock(100_000e18, block.timestamp + mt);
        gauges.voteForGauge(address(index), 10_000); // 100% of Alice's weight to the index gauge
        vm.stopPrank();
        assertEq(gauges.relativeWeight(address(index)), 1e18);

        // ── 7. Claim fees: protocol fees flow to veSTRAT lockers, claimed pro-rata after the epoch ──
        FeeDistributor distributor = new FeeDistributor(ve, IERC20(address(usdc)));
        vm.prank(alice);
        distributor.checkpoint();

        // protocol routes $5k of accumulated fees into the distributor
        _fundUSDC(treasury, 5_000e18);
        vm.startPrank(treasury);
        usdc.approve(address(distributor), 5_000e18);
        distributor.notifyReward(5_000e18);
        vm.stopPrank();

        uint256 epoch = distributor.currentEpoch();
        skip(7 days); // finalize the epoch
        _refreshFeeds();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = distributor.claim(epoch);
        // Alice is the only locker → she receives all the fees
        assertApproxEqAbs(claimed, 5_000e18, 2);
        assertEq(usdc.balanceOf(alice) - balBefore, claimed);

        // ── Final coherence: still able to exit the perp and redeem the index in-kind ──
        vm.prank(alice);
        perp.close(posId);
        uint256 remaining = shareToken.balanceOf(alice);
        vm.prank(alice);
        index.redeem(remaining);
        assertEq(shareToken.balanceOf(alice), 0);
    }
}
