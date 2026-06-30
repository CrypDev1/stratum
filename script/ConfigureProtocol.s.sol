// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";
import { INAVOracle } from "../src/interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../src/interfaces/IDepegMonitor.sol";
import { ISwapRouter } from "../src/interfaces/ISwapRouter.sol";
import { IPortfolio } from "../src/interfaces/IPortfolio.sol";
import { IVToken } from "../src/interfaces/external/IVToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { PancakeV3SwapAdapter } from "../src/periphery/PancakeV3SwapAdapter.sol";
import { YieldRouter } from "../src/leverage/YieldRouter.sol";
import { VenusVTokenAdapter } from "../src/yield/VenusVTokenAdapter.sol";
import { Lista4626Adapter } from "../src/yield/ERC4626YieldAdapter.sol";
import { IYieldAdapter } from "../src/interfaces/IYieldAdapter.sol";
import { LiquidityPool } from "../src/derivatives/LiquidityPool.sol";
import { PerpEngine } from "../src/derivatives/PerpEngine.sol";
import { LeverageModule } from "../src/leverage/LeverageModule.sol";
import { GaugeController } from "../src/token/GaugeController.sol";
import { GaugeDistributor } from "../src/token/GaugeDistributor.sol";

/// @title ConfigureProtocol
/// @notice One-shot, idempotent deploy-and-wire of all the NEW additive pieces on top of the LIVE core.
/// @dev Each stage is independent and safe to re-run: it reuses an address you pass back via env (so a
///      second run doesn't redeploy) and only writes on-chain state when it actually differs. Nothing here
///      touches or redeploys the live core contracts — it only deploys peripherals and calls existing
///      admin setters (factory wiring) you already own.
///
///      Stages (each gated on the env it needs):
///        1. Swap adapter      — always: deploys PancakeV3SwapAdapter, wires it into the factory.
///        2. Earn YieldRouter  — if VENUS_VTOKEN and/or LISTA_VAULT set.
///        3. Perp market       — if PERP_MARKET set: LiquidityPool + PerpEngine (priced off live oracle).
///        4. Leverage module   — if LEVERAGE_PORTFOLIO set.
///
///      Core env (mainnet defaults):
///        PRIVATE_KEY ADMIN NAV_ORACLE DEPEG_MONITOR PORTFOLIO_FACTORY STABLE_TOKEN PANCAKE_V3_ROUTER
///      Reuse env (set to a prior run's output to skip redeploy):
///        SWAP_ADAPTER EARN_YIELD_ROUTER PERP_LIQUIDITY_POOL PERP_ENGINE LEVERAGE_MODULE
///
///      Run: `forge script script/ConfigureProtocol.s.sol:ConfigureProtocol --rpc-url bsc --broadcast`
contract ConfigureProtocol is Script {
    // Live mainnet defaults (chainId 56).
    address internal constant NAV_ORACLE_DEFAULT = 0xbe263035a704E5039aCaB282AB011DF8175526e3;
    address internal constant DEPEG_DEFAULT = 0x7EB90C8F1E8E6bcC0C31A13D37271519dBB50D2a;
    address internal constant FACTORY_DEFAULT = 0x514ff906D211c86685db3DA68B8d18876A1665bd;
    address internal constant STRAT_DEFAULT = 0xf0C2705Cb380c37FA92EEBD9301e13496D859906;
    address internal constant GAUGE_CONTROLLER_DEFAULT = 0xacA48e04ce3b7AD51963fE822Cf04dFB362FA6CE;

    struct Ctx {
        address admin;
        address navOracle;
        address depeg;
        address factory;
        address stable;
        address v3Router;
    }

    function run() external {
        Ctx memory c = Ctx({
            admin: vm.envOr("ADMIN", msg.sender),
            navOracle: vm.envOr("NAV_ORACLE", NAV_ORACLE_DEFAULT),
            depeg: vm.envOr("DEPEG_MONITOR", DEPEG_DEFAULT),
            factory: vm.envOr("PORTFOLIO_FACTORY", FACTORY_DEFAULT),
            stable: vm.envAddress("STABLE_TOKEN"),
            v3Router: vm.envAddress("PANCAKE_V3_ROUTER")
        });

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address swapAdapter = _swapAdapter(c);
        _earn(c);
        _perp(c);
        _leverage(c, swapAdapter);
        _gaugeDistributor();

        vm.stopBroadcast();
    }

    // ── Stage 5: gauge emissions distributor ─────────────────────────────────

    function _gaugeDistributor() internal {
        address existing = vm.envOr("GAUGE_DISTRIBUTOR", address(0));
        if (existing != address(0)) {
            console2.log("Reusing GAUGE_DISTRIBUTOR:", existing);
            return;
        }
        address admin = vm.envOr("ADMIN", msg.sender);
        IERC20 strat = IERC20(vm.envOr("STRAT", STRAT_DEFAULT));
        GaugeController controller = GaugeController(vm.envOr("GAUGE_CONTROLLER", GAUGE_CONTROLLER_DEFAULT));
        GaugeDistributor d = new GaugeDistributor(admin, strat, controller);
        console2.log("Deployed GaugeDistributor:", address(d));
        console2.log("  point the emissions keeper's EMISSIONS_RECIPIENT at this address");
    }

    // ── Stage 1: swap adapter + factory wiring ───────────────────────────────

    function _swapAdapter(Ctx memory c) internal returns (address swapAdapter) {
        swapAdapter = vm.envOr("SWAP_ADAPTER", address(0));
        if (swapAdapter == address(0)) {
            swapAdapter = address(new PancakeV3SwapAdapter(c.admin, c.v3Router, c.navOracle, c.stable));
            console2.log("Deployed PancakeV3SwapAdapter:", swapAdapter);
        } else {
            console2.log("Reusing SWAP_ADAPTER:", swapAdapter);
        }

        PortfolioFactory f = PortfolioFactory(c.factory);
        if (f.swapRouter() != swapAdapter) {
            f.setWiring(
                PortfolioFactory.Wiring({
                    navOracle: f.navOracle(),
                    proofOfCollateral: f.proofOfCollateral(),
                    depegMonitor: f.depegMonitor(),
                    swapRouter: swapAdapter,
                    feeManager: f.feeManager(),
                    indexImplementation: f.indexImplementation(),
                    vaultImplementation: f.vaultImplementation(),
                    protocolTreasury: f.protocolTreasury(),
                    protocolCutBps: f.protocolCutBps()
                })
            );
            console2.log("Factory swapRouter wired ->", swapAdapter);
        } else {
            console2.log("Factory swapRouter already set; no change");
        }
    }

    // ── Stage 2: standalone Earn YieldRouter + real adapters ─────────────────

    function _earn(Ctx memory c) internal {
        address venusVToken = vm.envOr("VENUS_VTOKEN", address(0));
        address listaVault = vm.envOr("LISTA_VAULT", address(0));
        if (venusVToken == address(0) && listaVault == address(0)) {
            console2.log("Earn: skipped (set VENUS_VTOKEN and/or LISTA_VAULT)");
            return;
        }

        address routerAddr = vm.envOr("EARN_YIELD_ROUTER", address(0));
        YieldRouter router;
        if (routerAddr == address(0)) {
            uint16 buffer = uint16(vm.envOr("EARN_IDLE_BUFFER_BPS", uint256(1000)));
            router = new YieldRouter(c.admin, IERC20(c.stable), buffer);
            console2.log("Deployed Earn YieldRouter:", address(router));
        } else {
            router = YieldRouter(routerAddr);
            console2.log("Reusing EARN_YIELD_ROUTER:", routerAddr);
        }

        uint256 blocksPerYear = vm.envOr("BLOCKS_PER_YEAR", uint256(10_512_000));
        if (venusVToken != address(0)) {
            VenusVTokenAdapter a = new VenusVTokenAdapter(address(router), IVToken(venusVToken), blocksPerYear);
            router.addAdapter(IYieldAdapter(address(a)));
            console2.log("Wired VenusVTokenAdapter:", address(a));
        }
        if (listaVault != address(0)) {
            uint256 apr = vm.envOr("LISTA_APR_BPS", uint256(0));
            Lista4626Adapter a = new Lista4626Adapter(address(router), IERC4626(listaVault), c.admin, apr);
            router.addAdapter(IYieldAdapter(address(a)));
            console2.log("Wired Lista4626Adapter:", address(a));
        }
    }

    // ── Stage 3: perp market (priced off live oracle) ────────────────────────

    function _perp(Ctx memory c) internal {
        address market = vm.envOr("PERP_MARKET", address(0));
        if (market == address(0)) {
            console2.log("Perp: skipped (set PERP_MARKET)");
            return;
        }

        address poolAddr = vm.envOr("PERP_LIQUIDITY_POOL", address(0));
        LiquidityPool pool =
            poolAddr == address(0) ? new LiquidityPool(c.admin, IERC20(c.stable)) : LiquidityPool(poolAddr);
        if (poolAddr == address(0)) console2.log("Deployed LiquidityPool:", address(pool));

        address engineAddr = vm.envOr("PERP_ENGINE", address(0));
        PerpEngine engine = engineAddr == address(0)
            ? new PerpEngine(
                c.admin, IERC20(c.stable), INAVOracle(c.navOracle), IDepegMonitor(c.depeg), pool, market
            )
            : PerpEngine(engineAddr);
        if (engineAddr == address(0)) console2.log("Deployed PerpEngine:", address(engine));

        if (pool.engine() == address(0)) {
            pool.setEngine(address(engine));
            console2.log("Pool engine bound ->", address(engine));
        }
        console2.log("PerpEngine market priced off live NAVOracle:", address(engine.nav()));
    }

    // ── Stage 4: leverage module (health off live oracle) ────────────────────

    function _leverage(Ctx memory c, address swapAdapter) internal {
        address portfolio = vm.envOr("LEVERAGE_PORTFOLIO", address(0));
        if (portfolio == address(0)) {
            console2.log("Leverage: skipped (set LEVERAGE_PORTFOLIO)");
            return;
        }
        address moduleAddr = vm.envOr("LEVERAGE_MODULE", address(0));
        if (moduleAddr != address(0)) {
            console2.log("Reusing LEVERAGE_MODULE:", moduleAddr);
            return;
        }
        LeverageModule m = new LeverageModule(
            c.admin, IPortfolio(portfolio), INAVOracle(c.navOracle), IDepegMonitor(c.depeg), ISwapRouter(swapAdapter)
        );
        console2.log("Deployed LeverageModule:", address(m));
        console2.log("  health/oracle:", address(m.nav()));
        console2.log("  seed its borrow reserve with stable via LeverageModule.fundReserve()");
    }
}
