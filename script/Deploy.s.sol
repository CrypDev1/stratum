// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { NAVOracle } from "../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../src/oracle/ProofOfCollateral.sol";
import { DepegMonitor } from "../src/oracle/DepegMonitor.sol";
import { INAVOracle } from "../src/interfaces/INAVOracle.sol";

import { FeeManager } from "../src/core/FeeManager.sol";
import { IndexPortfolio } from "../src/core/IndexPortfolio.sol";
import { VaultPortfolio } from "../src/core/VaultPortfolio.sol";
import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";

import { STRAT } from "../src/token/STRAT.sol";
import { EmissionsMinter } from "../src/token/EmissionsMinter.sol";
import { TeamVesting } from "../src/token/TeamVesting.sol";
import { veSTRAT } from "../src/token/veSTRAT.sol";
import { GaugeController } from "../src/token/GaugeController.sol";
import { FeeDistributor } from "../src/token/FeeDistributor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys the full Stratum stack to BNB testnet in dependency order (L0 → ★), wiring addresses
///         through a `Config` struct parameterized from env. Asset feeds/whitelist are configured
///         post-deploy by the oracle/PoC keepers.
/// @dev `forge script script/Deploy.s.sol:Deploy --rpc-url bsc_testnet --broadcast`.
contract Deploy is Script {
    // ── STRAT fixed supply & distribution (percentages of the 1,000,000,000 hard cap) ──
    uint256 internal constant LIQUIDITY_ALLOC = 500_000_000e18; // 50% → liquidityWallet (manual LP later)
    uint256 internal constant EMISSIONS_ALLOC = 300_000_000e18; // 30% → community emissions over 12 months
    uint256 internal constant TEAM_ALLOC = 50_000_000e18; //  5% → TeamVesting (cliff + linear)
    uint256 internal constant TREASURY_ALLOC = 150_000_000e18; // 15% → treasuryWallet (locked externally)

    uint256 internal constant EMISSIONS_PERIOD = 365 days; // 12-month community-emissions schedule
    uint256 internal constant TEAM_CLIFF = 90 days; // 3-month team cliff
    uint256 internal constant TEAM_VESTING_DURATION = 730 days; // 24-month linear vesting after the cliff

    struct Config {
        address admin; // protocol governance / admin (must hold STRAT admin role at deploy time)
        address treasury; // protocol fee recipient (factory)
        address swapRouter; // PancakeSwap router adapter (TODO(integration))
        address stable; // quote/reward stable (USDC/USDT) — reward token for FeeDistributor
        uint16 protocolCutBps; // protocol fee cut
        // ── STRAT distribution targets (addresses only; amounts are fixed above) ──
        address liquidityWallet; // 50% — receives 500,000,000 STRAT for manual PancakeSwap LP
        address treasuryWallet; // 15% — receives 150,000,000 STRAT, locked externally
        address teamBeneficiary; // 5% — beneficiary of the TeamVesting contract
        uint256 emissionsTarget; // 30% — lifetime community-emissions cap (300,000,000 STRAT)
    }

    struct Deployed {
        address oracle;
        address poc;
        address depeg;
        address feeManager;
        address indexImpl;
        address vaultImpl;
        address factory;
        address strat;
        address emissions;
        address teamVesting;
        address veStrat;
        address gauges;
        address feeDistributor;
    }

    function run() external returns (Deployed memory d) {
        Config memory cfg = _config();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // ── L0: oracle stack ──
        NAVOracle oracle = new NAVOracle(cfg.admin);
        ProofOfCollateral poc = new ProofOfCollateral(cfg.admin);
        DepegMonitor depeg = new DepegMonitor(cfg.admin, INAVOracle(address(oracle)));

        // ── L1: core ──
        FeeManager feeManager = new FeeManager();
        address indexImpl = address(new IndexPortfolio());
        address vaultImpl = address(new VaultPortfolio());
        PortfolioFactory factory = new PortfolioFactory(
            cfg.admin,
            PortfolioFactory.Wiring({
                navOracle: address(oracle),
                proofOfCollateral: address(poc),
                depegMonitor: address(depeg),
                swapRouter: cfg.swapRouter,
                feeManager: address(feeManager),
                indexImplementation: indexImpl,
                vaultImplementation: vaultImpl,
                protocolTreasury: cfg.treasury,
                protocolCutBps: cfg.protocolCutBps
            })
        );

        // ── ★ token flywheel ──
        STRAT strat = new STRAT(cfg.admin, 0); // no genesis mint — distribute explicitly below

        // Fixed 1,000,000,000 hard cap, distributed exactly 50/30/5/15. The four allocations must sum to
        // the cap with nothing left unminted or over-minted.
        require(LIQUIDITY_ALLOC + cfg.emissionsTarget + TEAM_ALLOC + TREASURY_ALLOC == strat.cap(), "alloc sum != cap");

        // 30% community emissions: linear over 12 months, hard-capped at the emissions target (300M).
        EmissionsMinter emissions =
            new EmissionsMinter(cfg.admin, strat, cfg.emissionsTarget / EMISSIONS_PERIOD, cfg.emissionsTarget);

        // 5% team: 3-month cliff then 24-month linear vesting.
        TeamVesting teamVesting =
            new TeamVesting(IERC20(address(strat)), cfg.teamBeneficiary, TEAM_CLIFF, TEAM_VESTING_DURATION);

        // Distribute the three up-front allocations via a temporary MINTER grant to the deployer.
        strat.grantRole(strat.MINTER(), deployer);
        strat.mint(cfg.liquidityWallet, LIQUIDITY_ALLOC); // 50% → liquidity (manual PancakeSwap LP later)
        strat.mint(cfg.treasuryWallet, TREASURY_ALLOC); // 15% → treasury (locked externally)
        strat.mint(address(teamVesting), TEAM_ALLOC); //  5% → team vesting
        strat.revokeRole(strat.MINTER(), deployer);

        // 30% remains mintable only by the EmissionsMinter, over the 12-month schedule.
        strat.grantRole(strat.MINTER(), address(emissions));

        veSTRAT ve = new veSTRAT(IERC20(address(strat)));
        GaugeController gauges = new GaugeController(cfg.admin, ve);
        FeeDistributor feeDistributor = new FeeDistributor(ve, IERC20(cfg.stable));

        vm.stopBroadcast();

        d = Deployed({
            oracle: address(oracle),
            poc: address(poc),
            depeg: address(depeg),
            feeManager: address(feeManager),
            indexImpl: indexImpl,
            vaultImpl: vaultImpl,
            factory: address(factory),
            strat: address(strat),
            emissions: address(emissions),
            teamVesting: address(teamVesting),
            veStrat: address(ve),
            gauges: address(gauges),
            feeDistributor: address(feeDistributor)
        });

        console2.log("NAVOracle       ", d.oracle);
        console2.log("ProofOfCollat   ", d.poc);
        console2.log("DepegMonitor    ", d.depeg);
        console2.log("FeeManager      ", d.feeManager);
        console2.log("Factory         ", d.factory);
        console2.log("STRAT           ", d.strat);
        console2.log("EmissionsMinter ", d.emissions);
        console2.log("TeamVesting     ", d.teamVesting);
        console2.log("veSTRAT         ", d.veStrat);
        console2.log("GaugeController ", d.gauges);
        console2.log("FeeDistributor  ", d.feeDistributor);
        console2.log("--- STRAT distribution (STRAT) ---");
        console2.log("liquidityWallet (50%)", cfg.liquidityWallet, LIQUIDITY_ALLOC / 1e18);
        console2.log("treasuryWallet  (15%)", cfg.treasuryWallet, TREASURY_ALLOC / 1e18);
        console2.log("teamVesting     ( 5%)", d.teamVesting, TEAM_ALLOC / 1e18);
        console2.log("emissions       (30%)", d.emissions, cfg.emissionsTarget / 1e18);
    }

    /// @dev Build the config from env with sensible defaults. Distribution targets default to the deployer
    ///      for local/test runs; for mainnet they MUST be set explicitly (see README / .env.example).
    function _config() internal view returns (Config memory cfg) {
        cfg.admin = vm.envOr("ADMIN", msg.sender);
        cfg.treasury = vm.envOr("PROTOCOL_TREASURY", msg.sender);
        cfg.swapRouter = vm.envOr("SWAP_ROUTER", address(0)); // TODO(integration): PancakeSwap adapter
        cfg.stable = vm.envOr("STABLE_TOKEN", address(0)); // TODO(integration): USDT/USDC on BNB
        cfg.protocolCutBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", uint256(1000)));
        // STRAT distribution targets (default to deployer only for local/test).
        cfg.liquidityWallet = vm.envOr("LIQUIDITY_WALLET", msg.sender);
        cfg.treasuryWallet = vm.envOr("TREASURY_WALLET", msg.sender);
        cfg.teamBeneficiary = vm.envOr("TEAM_BENEFICIARY", msg.sender);
        cfg.emissionsTarget = vm.envOr("EMISSIONS_TARGET", EMISSIONS_ALLOC); // 30% = 300,000,000 STRAT
    }
}
