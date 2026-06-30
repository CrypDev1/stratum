// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { GaugeController } from "../src/token/GaugeController.sol";

/// @title CreateGauge
/// @notice Registers a GaugeController gauge for a portfolio so it can receive STRAT emissions.
/// @dev One gauge per Index/Vault: the gauge address is the portfolio address itself. Idempotent — skips
///      if the gauge is already registered.
///
///      Env:
///        PRIVATE_KEY      admin EOA (must hold GAUGE_ADMIN)
///        GAUGE_CONTROLLER live GaugeController (default: mainnet)
///        GAUGE            the portfolio (gauge) address to register
///
///      Run: `forge script script/CreateGauge.s.sol:CreateGauge --rpc-url bsc --broadcast`
contract CreateGauge is Script {
    address internal constant GAUGE_CONTROLLER_DEFAULT = 0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE;

    function run() external {
        GaugeController gc = GaugeController(vm.envOr("GAUGE_CONTROLLER", GAUGE_CONTROLLER_DEFAULT));
        address gauge = vm.envAddress("GAUGE");

        if (gc.isGauge(gauge)) {
            console2.log("Gauge already registered:", gauge);
            return;
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        gc.addGauge(gauge);
        vm.stopBroadcast();

        console2.log("Gauge registered:", gauge);
        console2.log("Total gauges:", gc.gaugeCount());
    }
}
