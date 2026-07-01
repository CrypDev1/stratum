// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { EarnVault } from "../../src/earn/EarnVault.sol";
import { EarnVaultFactory } from "../../src/earn/EarnVaultFactory.sol";
import { IStrategy } from "../../src/earn/strategies/IStrategy.sol";
import { VenusStrategy } from "../../src/earn/strategies/VenusStrategy.sol";
import { ListaStrategy } from "../../src/earn/strategies/ListaStrategy.sol";
import { IVToken } from "../../src/interfaces/external/IVToken.sol";

import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { MockVToken } from "../../src/mocks/MockVToken.sol";
import { Mock4626 } from "../../src/mocks/Mock4626.sol";

/// @notice Unit coverage for the Stratum Earn module: ERC-4626 deposit/withdraw + NAV accrual, live
///         strategy routing, admin migration, access control, reentrancy, and the share-inflation
///         ("donation") attack defense. Real venues are stood in by the repo's accrual mocks; a real
///         BNB-fork run lives in EarnFork.t.sol.
contract EarnVaultTest is Test {
    uint256 internal constant BLOCKS_PER_YEAR = 10_512_000; // ~3s blocks
    uint256 internal constant VENUS_APR_BPS = 500; // MockVToken supply APR (5%)

    MockERC20 internal usdt;
    EarnVault internal impl;
    EarnVaultFactory internal factory;
    EarnVault internal vault;

    MockVToken internal vToken;
    VenusStrategy internal venus;

    Mock4626 internal listaVault;
    ListaStrategy internal lista;

    address internal admin = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new MockERC20("Tether USD", "USDT", 18);

        impl = new EarnVault();
        factory = new EarnVaultFactory(admin, address(impl));
        vault = EarnVault(factory.createVault(address(usdt), "Stratum Earn USDT", "eUSDT", admin));

        vToken = new MockVToken(address(usdt), VENUS_APR_BPS, BLOCKS_PER_YEAR);
        venus = new VenusStrategy(address(vault), IVToken(address(vToken)), BLOCKS_PER_YEAR);

        listaVault = new Mock4626(usdt);
        lista = new ListaStrategy(address(vault), IERC4626(address(listaVault)));

        vault.setStrategy(IStrategy(address(venus)));

        _fund(alice, 1_000_000e18);
        _fund(bob, 1_000_000e18);
    }

    function _fund(address who, uint256 amount) internal {
        usdt.mint(who, amount);
        vm.prank(who);
        usdt.approve(address(vault), type(uint256).max);
    }

    // ── Metadata / wiring ────────────────────────────────────────────────────

    function test_metadataAndWiring() public view {
        assertEq(vault.asset(), address(usdt));
        assertEq(vault.name(), "Stratum Earn USDT");
        assertEq(vault.symbol(), "eUSDT");
        assertEq(vault.decimals(), 21); // 18 underlying + 3 offset
        assertEq(address(vault.strategy()), address(venus));
        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.vaultCount(), 1);
    }

    // ── Deposit routes into the strategy ─────────────────────────────────────

    function test_depositRoutesToStrategyAndMintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        assertEq(vault.balanceOf(alice), shares);
        assertGt(shares, 0);
        // 100% routed to the strategy: no idle, strategy holds the principal.
        assertEq(usdt.balanceOf(address(vault)), 0, "no idle");
        assertApproxEqAbs(venus.totalAssets(), 1_000e18, 1, "supplied to Venus");
        assertApproxEqAbs(vault.totalAssets(), 1_000e18, 1, "NAV = strategy assets");
    }

    // ── NAV accrual: share price rises, no rebasing ──────────────────────────

    function test_navAccruesYieldToSharePrice() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);
        uint256 ppsBefore = vault.pricePerShare();
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.warp(block.timestamp + 365 days);

        // No rebasing: the holder's share balance is unchanged; the *price* rose ~5%.
        assertEq(vault.balanceOf(alice), sharesBefore, "no rebasing");
        assertApproxEqRel(vault.totalAssets(), 1_050e18, 0.001e18, "5% accrued into NAV");
        assertGt(vault.pricePerShare(), ppsBefore, "share price rose");

        // Redeem all: principal + accrued yield.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertApproxEqRel(got, 1_050e18, 0.001e18, "redeemed principal + yield");
    }

    function test_withdrawExactAssetsPullsFromStrategy() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        vm.warp(block.timestamp + 365 days);

        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(400e18, alice, alice);
        assertEq(usdt.balanceOf(alice) - before, 400e18, "exact assets out");
        assertGt(sharesBurned, 0);
        // Remaining position still ~ (1050 - 400) with dust tolerance.
        assertApproxEqRel(vault.maxWithdraw(alice), 650e18, 0.002e18);
    }

    function test_previewMatchesDepositAndRedeem() public {
        uint256 predicted = vault.previewDeposit(500e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(500e18, alice);
        assertEq(shares, predicted, "previewDeposit exact");

        uint256 predictedAssets = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertEq(got, predictedAssets, "previewRedeem exact");
    }

    // ── APY derived LIVE from the venue's on-chain rate ──────────────────────

    function test_estimatedApyIsLiveFromVenue() public {
        // Venus mock reports ~5% supply APR; vault surfaces it verbatim.
        assertApproxEqAbs(venus.supplyAprBps(), VENUS_APR_BPS, 1);
        assertApproxEqAbs(vault.estimatedApyBps(), VENUS_APR_BPS, 1);

        // Change the on-chain venue rate → vault estimate tracks it (never hardcoded).
        vToken.setRateBps(1_200);
        assertApproxEqAbs(vault.estimatedApyBps(), 1_200, 2);
    }

    // ── Strategy migration (Venus → Lista) conserves value ───────────────────

    function test_adminMigratesStrategyConservingValue() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        vm.warp(block.timestamp + 365 days);
        uint256 navBefore = vault.totalAssets();
        assertGt(venus.totalAssets(), 0);

        vault.setStrategy(IStrategy(address(lista)));

        // Old venue emptied, new venue holds the whole position, NAV conserved.
        assertEq(venus.totalAssets(), 0, "old strategy drained");
        assertApproxEqRel(lista.totalAssets(), navBefore, 0.0001e18, "new strategy funded");
        assertApproxEqRel(vault.totalAssets(), navBefore, 0.0001e18, "NAV conserved across migration");
        assertEq(address(vault.strategy()), address(lista));

        // Users can still redeem against the new venue.
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertApproxEqRel(got, navBefore, 0.0002e18);
    }

    function test_clearStrategyReturnsFundsToIdle() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        vault.clearStrategy();

        assertEq(address(vault.strategy()), address(0));
        assertEq(venus.totalAssets(), 0);
        assertApproxEqAbs(usdt.balanceOf(address(vault)), 1_000e18, 1, "funds returned to idle");
        // Withdraw still works from idle.
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);
        assertApproxEqAbs(vault.maxWithdraw(alice), 500e18, 1);
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_onlyAdminSetsStrategy() public {
        bytes32 role = vault.EARN_ADMIN();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vault.setStrategy(IStrategy(address(lista)));
    }

    function test_onlyAdminClearsAndPauses() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.clearStrategy();
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();
    }

    function test_setStrategyRejectsAssetMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        Mock4626 otherVault = new Mock4626(other);
        ListaStrategy bad = new ListaStrategy(address(vault), IERC4626(address(otherVault)));
        vm.expectRevert(EarnVault.AssetMismatch.selector);
        vault.setStrategy(IStrategy(address(bad)));
    }

    function test_setStrategyRejectsForeignOwner() public {
        // Strategy whose vault() points elsewhere must be rejected.
        ListaStrategy foreign = new ListaStrategy(address(0xdead), IERC4626(address(listaVault)));
        vm.expectRevert(EarnVault.BadStrategyOwner.selector);
        vault.setStrategy(IStrategy(address(foreign)));
    }

    function test_pauseBlocksDepositsButNotWithdrawals() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1_000e18, bob);

        // Redeem stays open while paused.
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    // ── Reentrancy ───────────────────────────────────────────────────────────

    function test_depositIsNonReentrant() public {
        ReentrantToken evil = new ReentrantToken();
        EarnVault v = EarnVault(factory.createVault(address(evil), "Evil", "EVL", admin));
        evil.mint(address(this), 1_000e18);
        evil.approve(address(v), type(uint256).max);
        evil.arm(address(v));

        // The re-entrant deposit triggered inside transferFrom must make the whole call revert.
        vm.expectRevert();
        v.deposit(100e18, address(this));
    }

    // ── Share-inflation ("donation") attack is unprofitable ──────────────────

    function test_donationInflationAttackIsUnprofitable() public {
        // Attacker seeds the empty vault with 1 wei, then donates a large amount directly to inflate NAV.
        uint256 donation = 10_000e18;
        vm.prank(alice); // alice = attacker
        vault.deposit(1, alice);
        uint256 attackerShares = vault.balanceOf(alice);

        // Direct donation into the vault (idle) — the classic inflation vector.
        usdt.mint(alice, donation);
        vm.prank(alice);
        usdt.transfer(address(vault), donation);

        // Victim deposits a normal amount.
        uint256 victimIn = 10_000e18;
        vm.prank(bob);
        uint256 victimShares = vault.deposit(victimIn, bob);

        assertGt(victimShares, 0, "victim still receives shares (not rounded to zero)");

        uint256 victimRedeemable = vault.previewRedeem(victimShares);
        uint256 attackerRedeemable = vault.previewRedeem(attackerShares);

        // Victim keeps essentially all of their capital (loses < 1% to the virtual-offset rounding).
        assertGt(victimRedeemable, (victimIn * 99) / 100, "victim not materially harmed");
        // Attacker cannot profit: they get back less than the 1 wei + donation they put in.
        assertLt(attackerRedeemable, donation, "attacker loses money");
        assertGt(victimRedeemable, attackerRedeemable, "victim protected vs attacker");
    }

    // ── Lista: APR derived on-chain from realized share-price growth ──────────

    function test_listaApyDerivedFromOnchainGrowth() public {
        vault.setStrategy(IStrategy(address(lista)));
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        // Before any accrual the trailing realized APR is zero.
        assertEq(lista.supplyAprBps(), 0);

        // Simulate real venue yield: 10% underlying donated into the Lista 4626 over 30 days.
        vm.warp(block.timestamp + 30 days);
        usdt.mint(address(listaVault), 100e18);

        // Realized APR ≈ 10% over 30 days annualized ≈ 121.6% (12166 bps), read purely on-chain.
        uint256 apr = lista.supplyAprBps();
        assertApproxEqRel(apr, 12_166, 0.01e18, "on-chain realized APR");
        assertEq(vault.estimatedApyBps(), apr, "vault surfaces the live strategy APR");

        // Poke rolls the window forward; the instantaneous trailing APR resets to zero.
        lista.poke();
        assertEq(lista.supplyAprBps(), 0);
        assertApproxEqRel(lista.currentPrice(), 1.1e18, 0.0001e18);
    }
}

/// @notice ERC-20 that re-enters the vault's `deposit` during `transferFrom` to exercise the reentrancy guard.
contract ReentrantToken is ERC20 {
    address internal target;
    bool internal armed;

    constructor() ERC20("Reentrant", "RE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_) external {
        target = target_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            EarnVault(target).deposit(amount, from); // must revert via nonReentrant
        }
        return super.transferFrom(from, to, amount);
    }
}
