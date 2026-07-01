// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { EarnVault } from "../src/earn/EarnVault.sol";
import { EarnVaultFactory } from "../src/earn/EarnVaultFactory.sol";
import { IStrategy } from "../src/earn/strategies/IStrategy.sol";
import { VenusStrategy } from "../src/earn/strategies/VenusStrategy.sol";
import { ListaStrategy } from "../src/earn/strategies/ListaStrategy.sol";
import { IVToken } from "../src/interfaces/external/IVToken.sol";

/// @title DeployEarn
/// @notice Deploys the additive "Stratum Earn" module — an EarnVault ERC-4626 implementation, its clone
///         factory, a first USDT vault, and the real yield strategy adapter(s) — then attaches an initial
///         strategy. Fully additive to the live core (chainId 56): touches NO existing core contract.
/// @dev SECURITY / operational constraints honored by this script:
///        - Uses argument-less `vm.startBroadcast()` so the SIGNER is supplied at the CLI
///          (`--private-key` / `--account` / `--ledger`); the script never reads the deployer key from env.
///        - Adds NO liquidity anywhere and performs NO contract verification (no `--verify`).
///        - Deploys nothing that modifies/redeploys core; the Earn module stands alone.
///
///      Run (simulate — no state change):
///        `forge script script/DeployEarn.s.sol:DeployEarn --rpc-url bsc`
///      Broadcast (operator supplies the signer; add verification separately per VERIFY.md if desired):
///        `forge script script/DeployEarn.s.sol:DeployEarn --rpc-url bsc --account <acct> --broadcast`
contract DeployEarn is Script {
    // Live BNB Chain default: USDT (18-dec) — the initial Earn base asset.
    address internal constant USDT_DEFAULT = 0x55d398326f99059fF775485246999027B3197955;

    function run() external {
        address admin = vm.envOr("ADMIN", msg.sender);
        address stable = vm.envOr("STABLE_TOKEN", USDT_DEFAULT);
        string memory vaultName = vm.envOr("EARN_VAULT_NAME", string("Stratum Earn USDT"));
        string memory vaultSymbol = vm.envOr("EARN_VAULT_SYMBOL", string("eUSDT"));

        address venusVToken = vm.envOr("VENUS_VTOKEN", address(0));
        address listaVault = vm.envOr("LISTA_VAULT", address(0));
        uint256 blocksPerYear = vm.envOr("BLOCKS_PER_YEAR", uint256(10_512_000));

        vm.startBroadcast();

        // 1. Implementation + clone factory (mirrors the core PortfolioFactory pattern).
        EarnVault impl = new EarnVault();
        EarnVaultFactory factory = new EarnVaultFactory(admin, address(impl));
        console2.log("EarnVault implementation:", address(impl));
        console2.log("EarnVaultFactory:", address(factory));

        // 2. First vault for the base asset.
        address vault = factory.createVault(stable, vaultName, vaultSymbol, admin);
        console2.log("EarnVault (base asset):", stable);
        console2.log("EarnVault deployed:", vault);

        // 3. Real strategy adapter(s), each owned by the new vault. Only one is active at a time; the other
        //    (if deployed) is available for the admin to migrate to later via EarnVault.setStrategy.
        address venusStrat;
        address listaStrat;
        if (venusVToken != address(0)) {
            venusStrat = address(new VenusStrategy(vault, IVToken(venusVToken), blocksPerYear));
            console2.log("VenusStrategy:", venusStrat);
        }
        if (listaVault != address(0)) {
            listaStrat = address(new ListaStrategy(vault, IERC4626(listaVault)));
            console2.log("ListaStrategy:", listaStrat);
        }

        // 4. Attach the initial strategy (Venus preferred if both are provided). If neither venue is
        //    configured the vault is deployed strategy-less; the admin attaches one later.
        if (venusStrat != address(0)) {
            EarnVault(vault).setStrategy(IStrategy(venusStrat));
            console2.log("Active strategy set -> VenusStrategy:", venusStrat);
            if (listaStrat != address(0)) console2.log("Migration target available -> ListaStrategy:", listaStrat);
        } else if (listaStrat != address(0)) {
            EarnVault(vault).setStrategy(IStrategy(listaStrat));
            console2.log("Active strategy set -> ListaStrategy:", listaStrat);
        } else {
            console2.log("No strategy configured (set VENUS_VTOKEN and/or LISTA_VAULT); vault is idle-only.");
        }

        vm.stopBroadcast();
    }
}
