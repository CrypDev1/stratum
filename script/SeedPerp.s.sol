// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { LiquidityPool } from "../src/derivatives/LiquidityPool.sol";
import { PerpEngine } from "../src/derivatives/PerpEngine.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedPerp
/// @notice Seeds the perp LiquidityPool (trader counterparty) and the PerpEngine insurance fund so the
///         derivatives market has a counterparty and bad-debt backstop.
/// @dev Both deposits pull stable from the broadcaster. The pool's first deposit mints LP shares 1:1.
///
///      Env:
///        PRIVATE_KEY           funder EOA (holds stable)
///        STABLE_TOKEN          the perp collateral (USDT/USDC)
///        LIQUIDITY_POOL        deployed LiquidityPool
///        PERP_ENGINE           deployed PerpEngine
///        POOL_SEED_AMOUNT      stable units to deposit as LP counterparty
///        INSURANCE_SEED_AMOUNT stable units to seed the insurance fund
///
///      Run: `forge script script/SeedPerp.s.sol:SeedPerp --rpc-url bsc --broadcast`
contract SeedPerp is Script {
    function run() external {
        IERC20 stable = IERC20(vm.envAddress("STABLE_TOKEN"));
        LiquidityPool pool = LiquidityPool(vm.envAddress("LIQUIDITY_POOL"));
        PerpEngine engine = PerpEngine(vm.envAddress("PERP_ENGINE"));
        uint256 poolSeed = vm.envUint("POOL_SEED_AMOUNT");
        uint256 insuranceSeed = vm.envUint("INSURANCE_SEED_AMOUNT");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        if (poolSeed > 0) {
            stable.approve(address(pool), poolSeed);
            uint256 shares = pool.deposit(poolSeed);
            console2.log("LiquidityPool seeded:", poolSeed);
            console2.log("  LP shares minted:  ", shares);
        }

        if (insuranceSeed > 0) {
            stable.approve(address(engine), insuranceSeed);
            engine.fundInsurance(insuranceSeed);
            console2.log("Insurance fund seeded:", insuranceSeed);
        }

        console2.log("Pool totalAssets:    ", pool.totalAssets());
        console2.log("Engine insuranceFund:", engine.insuranceFund());

        vm.stopBroadcast();
    }
}
