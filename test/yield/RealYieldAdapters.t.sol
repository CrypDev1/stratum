// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { YieldRouter } from "../../src/leverage/YieldRouter.sol";
import { VenusVTokenAdapter } from "../../src/yield/VenusVTokenAdapter.sol";
import { ERC4626YieldAdapter, Lista4626Adapter } from "../../src/yield/ERC4626YieldAdapter.sol";
import { IYieldAdapter } from "../../src/interfaces/IYieldAdapter.sol";
import { IVToken } from "../../src/interfaces/external/IVToken.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MockVToken } from "../../src/mocks/MockVToken.sol";
import { Mock4626 } from "../../src/mocks/Mock4626.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract RealYieldAdaptersTest is Test {
    uint256 internal constant BLOCKS_PER_YEAR = 10_512_000; // ~3s blocks

    MockERC20 internal usdc;
    YieldRouter internal router;

    MockVToken internal vToken;
    VenusVTokenAdapter internal venus;

    Mock4626 internal vault;
    Lista4626Adapter internal lista;

    address internal admin = address(this);
    address internal keeper = address(0xCEE9);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USDC", "USDC", 18);

        router = new YieldRouter(admin, usdc, 1000); // 10% idle buffer

        vToken = new MockVToken(address(usdc), 500, BLOCKS_PER_YEAR); // 5% APR
        venus = new VenusVTokenAdapter(address(router), IVToken(address(vToken)), BLOCKS_PER_YEAR);

        vault = new Mock4626(usdc);
        lista = new Lista4626Adapter(address(router), IERC4626(address(vault)), keeper, 800); // 8% reported APR

        usdc.mint(admin, 10_000_000e18);
        usdc.approve(address(router), type(uint256).max);
    }

    // ── Venus ──────────────────────────────────────────────────────────────

    function test_venus_assetAndApr() public view {
        assertEq(venus.asset(), address(usdc));
        // 5% APR reported back as ~500 bps (per-block round-trip introduces <1bp error).
        assertApproxEqAbs(venus.aprBps(), 500, 1);
    }

    function test_venus_depositInvestsAndAccrues() public {
        router.addAdapter(IYieldAdapter(address(venus)));
        router.deposit(1_000e18);
        router.invest();

        // 10% buffer kept idle, 900 supplied to Venus.
        assertApproxEqAbs(router.idleBalance(), 100e18, 1);
        assertApproxEqAbs(venus.totalAssets(), 900e18, 1);

        // One year later the Venus position has grown ~5%.
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(venus.totalAssets(), 945e18, 0.001e18); // 900 * 1.05
        assertApproxEqRel(router.totalManaged(), 1_045e18, 0.001e18); // 100 idle + 945
    }

    function test_venus_withdrawReturnsPrincipalPlusYield() public {
        router.addAdapter(IYieldAdapter(address(venus)));
        router.deposit(1_000e18);
        router.invest();
        vm.warp(block.timestamp + 365 days);

        uint256 before = usdc.balanceOf(admin);
        router.withdraw(1_040e18, admin); // > original deposit, payable only from accrued yield
        assertEq(usdc.balanceOf(admin) - before, 1_040e18, "withdrew principal + yield");
    }

    // ── Lista (ERC-4626) ─────────────────────────────────────────────────────

    function test_lista_assetAndKeeperApr() public {
        assertEq(lista.asset(), address(usdc));
        assertEq(lista.aprBps(), 800);

        vm.prank(keeper);
        lista.setAprBps(950);
        assertEq(lista.aprBps(), 950);

        vm.expectRevert(ERC4626YieldAdapter.NotRateKeeper.selector);
        lista.setAprBps(1);
    }

    function test_lista_depositInvestsAndAccrues() public {
        router.addAdapter(IYieldAdapter(address(lista)));
        router.deposit(1_000e18);
        router.invest();
        assertApproxEqAbs(lista.totalAssets(), 900e18, 1);

        // Simulate vault yield: donate 90 underlying into the 4626 vault (10% gain on the position).
        usdc.mint(address(vault), 90e18);
        assertApproxEqRel(lista.totalAssets(), 990e18, 0.0001e18);

        uint256 before = usdc.balanceOf(admin);
        router.withdraw(990e18, admin);
        assertApproxEqRel(usdc.balanceOf(admin) - before, 990e18, 0.0001e18);
    }

    // ── Router ranking across both real adapters ─────────────────────────────

    function test_router_routesToHigherAprAdapter() public {
        router.addAdapter(IYieldAdapter(address(venus))); // 5%
        router.addAdapter(IYieldAdapter(address(lista))); // 8% reported
        router.deposit(1_000e18);
        router.invest();
        // Lista has the higher (reported) APR ⇒ receives the investable 900.
        assertApproxEqAbs(lista.totalAssets(), 900e18, 1);
        assertEq(venus.totalAssets(), 0);

        // Keeper marks Venus the better venue; next investable flow goes to Venus.
        vToken.setRateBps(1500);
        router.deposit(1_000e18);
        router.invest();
        assertGt(venus.totalAssets(), 0, "subsequent flow routed to Venus");
    }
}
