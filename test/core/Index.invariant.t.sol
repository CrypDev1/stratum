// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Fixtures } from "./Fixtures.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { PortfolioToken } from "../../src/core/PortfolioToken.sol";
import { FixedWeightStrategy } from "../../src/core/strategies/FixedWeightStrategy.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

/// @notice Drives random mint/redeem against an IndexPortfolio for invariant checking.
contract IndexHandler is Test {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
    MockERC20 internal usdc;
    address[3] internal actors = [address(0xA11), address(0xB0B), address(0xCa1)];

    constructor(IndexPortfolio _index, MockERC20 _usdc) {
        index = _index;
        usdc = _usdc;
        shareToken = PortfolioToken(_index.shareToken());
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e18, 100_000e18);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(index), amount);
        try index.mint(amount, 0, block.timestamp + 1) { } catch { }
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = shareToken.balanceOf(actor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(actor);
        try index.redeem(shares) { } catch { }
    }
}

contract IndexInvariantTest is StdInvariant, Fixtures {
    IndexPortfolio internal index;
    PortfolioToken internal shareToken;
    IndexHandler internal handler;

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

        handler = new IndexHandler(index, usdc);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IndexHandler.mint.selector;
        selectors[1] = IndexHandler.redeem.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice navPerShare never drops below peg (1e18) under parity mint/redeem (rounding only adds).
    function invariant_pegNeverBreaksDown() public view {
        if (shareToken.totalSupply() == 0) return;
        assertGe(index.navPerShare(), 1e18 - 1e9);
    }

    /// @notice Token supply is always fully backed: navPerShare * supply <= underlying NAV (+ dust).
    function invariant_fullyBacked() public view {
        uint256 supply = shareToken.totalSupply();
        if (supply == 0) return;
        uint256 tokenValue = (index.navPerShare() * supply) / 1e18;
        assertLe(tokenValue, index.totalNAV() + 1e13);
    }
}
