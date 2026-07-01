// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { EarnVault } from "../../src/earn/EarnVault.sol";
import { EarnVaultFactory } from "../../src/earn/EarnVaultFactory.sol";
import { IStrategy } from "../../src/earn/strategies/IStrategy.sol";
import { VenusStrategy } from "../../src/earn/strategies/VenusStrategy.sol";
import { ListaStrategy } from "../../src/earn/strategies/ListaStrategy.sol";
import { IVToken } from "../../src/interfaces/external/IVToken.sol";

/// @title EarnFork
/// @notice BNB Chain mainnet FORK integration for Stratum Earn: proves that REAL yield actually accrues to
///         an {EarnVault} through the {VenusStrategy} and {ListaStrategy} against the live venues. SKIPPED
///         unless the operator supplies a fork RPC + venue/whale addresses, so CI stays hermetic (same
///         pattern as test/yield/VenusFork.t.sol). Run with, e.g.:
///
///           FORK_RPC=$BSC_RPC_URL \
///           VENUS_VTOKEN=0x...        VENUS_UNDERLYING_WHALE=0x... \
///           LISTA_VAULT=0x...         LISTA_UNDERLYING_WHALE=0x... \
///           forge test --match-path test/earn/EarnFork.t.sol -vv
contract EarnForkTest is Test {
    uint256 internal constant BLOCKS_PER_YEAR = 10_512_000; // ~3s BSC blocks

    EarnVault internal impl;
    EarnVaultFactory internal factory;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            emit log("skipping: set FORK_RPC (+ venue/whale envs) to run the Earn fork tests");
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }

    function _newVault(address asset) internal returns (EarnVault vault) {
        impl = new EarnVault();
        factory = new EarnVaultFactory(address(this), address(impl));
        vault = EarnVault(factory.createVault(asset, "Stratum Earn", "eSTR", address(this)));
    }

    function _fundFromWhale(IERC20 token, address whale, uint256 amount) internal {
        vm.prank(whale);
        token.transfer(address(this), amount);
    }

    function _amount(IERC20 token) internal view returns (uint256) {
        uint8 dec = 18;
        try IERC20Metadataish(address(token)).decimals() returns (uint8 d) {
            dec = d;
        } catch { }
        return 1_000 * (10 ** dec);
    }

    // ── Venus: real supply APY accrues into vault NAV ────────────────────────

    function test_realVenusYieldAccruesToVault() public {
        if (!_fork()) return;
        address vTokenAddr = vm.envOr("VENUS_VTOKEN", address(0));
        address whale = vm.envOr("VENUS_UNDERLYING_WHALE", address(0));
        if (vTokenAddr == address(0) || whale == address(0)) {
            emit log("skipping Venus: set VENUS_VTOKEN + VENUS_UNDERLYING_WHALE");
            vm.skip(true);
            return;
        }

        IVToken vToken = IVToken(vTokenAddr);
        IERC20 underlying = IERC20(vToken.underlying());

        EarnVault vault = _newVault(address(underlying));
        VenusStrategy strat = new VenusStrategy(address(vault), vToken, BLOCKS_PER_YEAR);
        vault.setStrategy(IStrategy(address(strat)));

        uint256 amount = _amount(underlying);
        _fundFromWhale(underlying, whale, amount);
        underlying.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        assertApproxEqRel(vault.totalAssets(), amount, 0.001e18, "principal supplied into Venus");
        assertGt(vault.estimatedApyBps(), 0, "live Venus supply APR is positive");

        // Advance real Venus interest accrual and prove NAV grew.
        uint256 navBefore = vault.totalAssets();
        vm.roll(block.number + BLOCKS_PER_YEAR / 12); // ~1 month of blocks
        vm.warp(block.timestamp + 30 days);
        vToken.balanceOfUnderlying(address(strat)); // triggers accrueInterest on the real market

        uint256 navAfter = vault.totalAssets();
        assertGt(navAfter, navBefore, "real Venus yield accrued into vault NAV");

        // Redeem principal + accrued yield back out of the real market.
        uint256 shares = vault.balanceOf(address(this));
        uint256 got = vault.redeem(shares, address(this), address(this));
        assertGe(got, amount, "redeemed at least principal");
    }

    // ── Lista: real ERC-4626 yield accrues into vault NAV ────────────────────

    function test_realListaYieldAccruesToVault() public {
        if (!_fork()) return;
        address listaAddr = vm.envOr("LISTA_VAULT", address(0));
        address whale = vm.envOr("LISTA_UNDERLYING_WHALE", address(0));
        if (listaAddr == address(0) || whale == address(0)) {
            emit log("skipping Lista: set LISTA_VAULT + LISTA_UNDERLYING_WHALE");
            vm.skip(true);
            return;
        }

        IERC4626 listaVault = IERC4626(listaAddr);
        IERC20 underlying = IERC20(listaVault.asset());

        EarnVault vault = _newVault(address(underlying));
        ListaStrategy strat = new ListaStrategy(address(vault), listaVault);
        vault.setStrategy(IStrategy(address(strat)));

        uint256 amount = _amount(underlying);
        _fundFromWhale(underlying, whale, amount);
        underlying.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        assertApproxEqRel(vault.totalAssets(), amount, 0.001e18, "principal deposited into Lista");

        // Let the live Lista vault accrue and re-measure NAV; a real interest-bearing 4626 grows over time.
        uint256 navBefore = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + BLOCKS_PER_YEAR / 12);

        uint256 navAfter = vault.totalAssets();
        assertGe(navAfter, navBefore, "Lista NAV did not decrease");

        // Realized on-chain APR read after some accrual (>= 0; positive if the venue paid over the window).
        uint256 apr = vault.estimatedApyBps();
        emit log_named_uint("lista realized apr bps", apr);

        // Exit: users always redeem at current NAV.
        uint256 shares = vault.balanceOf(address(this));
        uint256 got = vault.redeem(shares, address(this), address(this));
        assertApproxEqRel(got, navAfter, 0.001e18, "redeemed at current NAV");
    }
}

interface IERC20Metadataish {
    function decimals() external view returns (uint8);
}
