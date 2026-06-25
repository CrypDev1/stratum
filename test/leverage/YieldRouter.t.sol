// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { YieldRouter } from "../../src/leverage/YieldRouter.sol";
import { VenusYieldAdapter, ListaYieldAdapter } from "../../src/leverage/MoneyMarketYieldAdapter.sol";
import { MockMoneyMarket } from "../../src/mocks/MockMoneyMarket.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { IMoneyMarket } from "../../src/interfaces/IMoneyMarket.sol";
import { IYieldAdapter } from "../../src/interfaces/IYieldAdapter.sol";

contract YieldRouterTest is Test {
    YieldRouter internal router;
    MockERC20 internal usdc;
    MockMoneyMarket internal venus;
    MockMoneyMarket internal lista;
    VenusYieldAdapter internal venusAdapter;
    ListaYieldAdapter internal listaAdapter;

    address internal admin = address(this);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USDC", "USDC", 18);
        venus = new MockMoneyMarket(address(usdc), 500); // 5% APR
        lista = new MockMoneyMarket(address(usdc), 800); // 8% APR

        router = new YieldRouter(admin, usdc, 1000); // 10% idle buffer
        venusAdapter = new VenusYieldAdapter(address(router), IMoneyMarket(address(venus)));
        listaAdapter = new ListaYieldAdapter(address(router), IMoneyMarket(address(lista)));
        router.addAdapter(IYieldAdapter(address(venusAdapter)));
        router.addAdapter(IYieldAdapter(address(listaAdapter)));

        usdc.mint(admin, 1_000_000e18);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_depositHeldIdle() public {
        router.deposit(1_000e18);
        assertEq(router.idleBalance(), 1_000e18);
        assertEq(router.totalManaged(), 1_000e18);
    }

    function test_investKeepsBuffer() public {
        router.deposit(1_000e18);
        router.invest();
        // 10% buffer => 100 idle, 900 invested into best (lista @ 8%)
        assertApproxEqAbs(router.idleBalance(), 100e18, 1);
        assertApproxEqAbs(lista.balanceOfUnderlying(address(listaAdapter)), 900e18, 1);
        assertEq(venus.balanceOfUnderlying(address(venusAdapter)), 0); // venus has lower APR
    }

    function test_investRoutesToBestRate() public {
        // raise venus above lista
        venus.setRateBps(1200);
        router.deposit(1_000e18);
        router.invest();
        assertApproxEqAbs(venus.balanceOfUnderlying(address(venusAdapter)), 900e18, 1);
    }

    function test_yieldAccrues() public {
        router.deposit(1_000e18);
        router.invest();
        uint256 before = router.totalManaged();
        skip(365 days);
        // lista 8% on 900 => ~72 yield
        assertApproxEqAbs(router.totalManaged(), before + 72e18, 1e16);
    }

    function test_withdrawFromIdleFirst() public {
        router.deposit(1_000e18);
        router.invest(); // 100 idle, 900 invested
        router.withdraw(50e18, admin);
        assertApproxEqAbs(router.idleBalance(), 50e18, 1);
        // invested untouched
        assertApproxEqAbs(lista.balanceOfUnderlying(address(listaAdapter)), 900e18, 1);
    }

    function test_withdrawDivestsWhenIdleShort() public {
        router.deposit(1_000e18);
        router.invest(); // 100 idle, 900 invested
        uint256 balBefore = usdc.balanceOf(admin);
        router.withdraw(500e18, admin);
        assertEq(usdc.balanceOf(admin) - balBefore, 500e18);
        // pulled 400 from adapters
        assertApproxEqAbs(router.investedAssets(), 500e18, 1e12);
    }

    function test_withdrawRevertsInsufficient() public {
        router.deposit(100e18);
        vm.expectRevert(YieldRouter.InsufficientLiquidity.selector);
        router.withdraw(200e18, admin);
    }

    function test_onlyAllocatorDeposits() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        router.deposit(1e18);
    }

    function testFuzz_managedConservedAcrossInvest(uint256 amount) public {
        amount = bound(amount, 1e18, 500_000e18);
        router.deposit(amount);
        uint256 before = router.totalManaged();
        router.invest();
        assertApproxEqAbs(router.totalManaged(), before, 1e6);
        // buffer maintained
        uint256 buffer = before * 1000 / 10000;
        assertGe(router.idleBalance(), buffer == 0 ? 0 : buffer - 1);
    }
}
