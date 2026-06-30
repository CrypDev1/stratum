// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { YieldRouter } from "../../src/leverage/YieldRouter.sol";
import { VenusVTokenAdapter } from "../../src/yield/VenusVTokenAdapter.sol";
import { IYieldAdapter } from "../../src/interfaces/IYieldAdapter.sol";
import { IVToken } from "../../src/interfaces/external/IVToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Forked-mainnet integration for the real Venus adapter. SKIPPED unless the operator supplies a
///         BSC fork RPC and a Venus vToken, so CI stays hermetic. Run with:
///           FORK_RPC=$BSC_RPC_URL VENUS_VTOKEN=0x... VENUS_UNDERLYING_WHALE=0x... \
///           forge test --match-path test/yield/VenusFork.t.sol -vv
contract VenusForkTest is Test {
    uint256 internal constant BLOCKS_PER_YEAR = 10_512_000;

    function test_realVenusSupplyAndRedeem() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        address vTokenAddr = vm.envOr("VENUS_VTOKEN", address(0));
        address whale = vm.envOr("VENUS_UNDERLYING_WHALE", address(0));
        if (bytes(rpc).length == 0 || vTokenAddr == address(0) || whale == address(0)) {
            emit log("skipping: set FORK_RPC + VENUS_VTOKEN + VENUS_UNDERLYING_WHALE to run");
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        IVToken vToken = IVToken(vTokenAddr);
        IERC20 underlying = IERC20(vToken.underlying());

        YieldRouter router = new YieldRouter(address(this), underlying, 0);
        VenusVTokenAdapter adapter = new VenusVTokenAdapter(address(router), vToken, BLOCKS_PER_YEAR);
        router.addAdapter(IYieldAdapter(address(adapter)));

        uint8 dec = 18;
        try IERC20Metadataish(address(underlying)).decimals() returns (uint8 d) {
            dec = d;
        } catch { }
        uint256 amount = 1_000 * (10 ** dec);

        // Fund the router from a whale and supply into Venus.
        vm.prank(whale);
        underlying.transfer(address(this), amount);
        underlying.approve(address(router), amount);
        router.deposit(amount);
        router.invest();

        // Position should reflect the supplied amount (allow rounding from Venus exchange-rate math).
        assertApproxEqRel(adapter.totalAssets(), amount, 0.001e18, "supplied into Venus");
        assertGt(adapter.aprBps(), 0, "live supply APR is positive");

        // Redeem most of it back.
        uint256 redeem = (amount * 99) / 100;
        uint256 before = underlying.balanceOf(address(this));
        router.withdraw(redeem, address(this));
        assertApproxEqRel(underlying.balanceOf(address(this)) - before, redeem, 0.001e18, "redeemed");
    }
}

interface IERC20Metadataish {
    function decimals() external view returns (uint8);
}
