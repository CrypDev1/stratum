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

/// @notice Random deposit/invest/withdraw against the YieldRouter; tracks net principal.
contract YieldHandler is Test {
    YieldRouter internal router;
    MockERC20 internal usdc;
    uint256 public netDeposited;

    constructor(YieldRouter _router, MockERC20 _usdc) {
        router = _router;
        usdc = _usdc;
        usdc.mint(address(this), 1e30);
        usdc.approve(address(_router), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1_000_000e18);
        router.deposit(amount);
        netDeposited += amount;
    }

    function invest() external {
        router.invest();
    }

    function withdraw(uint256 amount) external {
        uint256 managed = router.totalManaged();
        if (managed == 0) return;
        amount = bound(amount, 1, managed);
        try router.withdraw(amount, address(this)) {
            netDeposited = amount >= netDeposited ? 0 : netDeposited - amount;
        } catch { }
    }
}

contract YieldRouterInvariantTest is StdInvariant, Test {
    YieldRouter internal router;
    MockERC20 internal usdc;
    YieldHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USDC", "USDC", 18);
        MockMoneyMarket venus = new MockMoneyMarket(address(usdc), 500);
        MockMoneyMarket lista = new MockMoneyMarket(address(usdc), 800);

        router = new YieldRouter(address(this), usdc, 1000);
        VenusYieldAdapter va = new VenusYieldAdapter(address(router), IMoneyMarket(address(venus)));
        ListaYieldAdapter la = new ListaYieldAdapter(address(router), IMoneyMarket(address(lista)));
        router.addAdapter(IYieldAdapter(address(va)));
        router.addAdapter(IYieldAdapter(address(la)));

        handler = new YieldHandler(router, usdc);
        router.grantRole(router.ALLOCATOR(), address(handler));

        targetContract(address(handler));
    }

    /// @notice Managed value is never less than net principal — adapters only add yield, never lose funds.
    function invariant_noValueLost() public view {
        assertGe(router.totalManaged() + 1e12, handler.netDeposited());
    }

    /// @notice idle + invested always equals totalManaged (accounting identity).
    function invariant_accountingIdentity() public view {
        assertEq(router.totalManaged(), router.idleBalance() + router.investedAssets());
    }
}
