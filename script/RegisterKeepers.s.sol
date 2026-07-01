// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { EmissionsAutomation, IEmissionsMinterLike, IGaugeDistributorLike } from "../src/token/EmissionsAutomation.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title RegisterKeepers
/// @notice Deploys the EmissionsAutomation adapter and grants it EMISSIONS_ADMIN on the live minter, so a
///         Chainlink Automation custom-logic upkeep can push the STRAT schedule + split it across gauges.
/// @dev After this runs, register `EmissionsAutomation` as a Chainlink custom-logic upkeep (see
///      keepers/AUTOMATION.md) and fund it with LINK. The market-status keeper is off-chain (Gelato Web3
///      Function) — see the same doc. Additive: only deploys a peripheral and calls existing admin setters.
///
///      Env:
///        PRIVATE_KEY        admin EOA (holds DEFAULT_ADMIN_ROLE on the EmissionsMinter)
///        EMISSIONS_MINTER   live minter (default: mainnet)
///        EMISSIONS_RECIPIENT / GAUGE_DISTRIBUTOR  where emissions go (default: GAUGE_DISTRIBUTOR)
///        MIN_MINTABLE_WEI   dust threshold (default 0)
///        EMISSIONS_AUTOMATION  reuse a prior deployment (idempotency)
contract RegisterKeepers is Script {
    address internal constant EMISSIONS_MINTER_DEFAULT = 0x11e3f4d2c27e37ad7438deac5C143a06381C4816;

    function run() external returns (address automation) {
        address admin = vm.envOr("ADMIN", msg.sender);
        address minter = vm.envOr("EMISSIONS_MINTER", EMISSIONS_MINTER_DEFAULT);
        address distributor = vm.envOr("GAUGE_DISTRIBUTOR", address(0));
        address recipient = vm.envOr("EMISSIONS_RECIPIENT", distributor);
        require(recipient != address(0), "set EMISSIONS_RECIPIENT or GAUGE_DISTRIBUTOR");
        uint256 minMintable = vm.envOr("MIN_MINTABLE_WEI", uint256(0));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        automation = vm.envOr("EMISSIONS_AUTOMATION", address(0));
        if (automation == address(0)) {
            automation = address(
                new EmissionsAutomation(
                    admin,
                    IEmissionsMinterLike(minter),
                    recipient,
                    IGaugeDistributorLike(distributor),
                    minMintable
                )
            );
            console2.log("Deployed EmissionsAutomation:", automation);
        } else {
            console2.log("Reusing EMISSIONS_AUTOMATION:", automation);
        }

        // Grant EMISSIONS_ADMIN so the adapter may call emitTo (role-gated on the minter).
        bytes32 role = keccak256("EMISSIONS_ADMIN");
        if (!IAccessControl(minter).hasRole(role, automation)) {
            IAccessControl(minter).grantRole(role, automation);
            console2.log("Granted EMISSIONS_ADMIN to automation on minter");
        } else {
            console2.log("Automation already holds EMISSIONS_ADMIN");
        }

        vm.stopBroadcast();

        console2.log("Next: register this address as a Chainlink custom-logic upkeep and fund with LINK.");
        console2.log("  recipient (emissions -> here):", recipient);
    }
}
