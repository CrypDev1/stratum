// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { NAVOracle } from "../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../src/oracle/ProofOfCollateral.sol";
import { VenusOracleAdapter } from "../src/oracle/VenusOracleAdapter.sol";
import { IVenusOracle } from "../src/interfaces/external/IVenusOracle.sol";
import { ChainlinkOnlyDepegMonitor } from "../src/oracle/ChainlinkOnlyDepegMonitor.sol";
import { PancakeV3SwapAdapter } from "../src/periphery/PancakeV3SwapAdapter.sol";
import { PortfolioFactory } from "../src/core/PortfolioFactory.sol";
import { FixedWeightStrategy } from "../src/core/strategies/FixedWeightStrategy.sol";
import { INAVOracle } from "../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../src/interfaces/IOracleAdapter.sol";
import { IDepegMonitor } from "../src/interfaces/IDepegMonitor.sol";
import { IProofOfCollateral } from "../src/interfaces/IProofOfCollateral.sol";
import { IPortfolio } from "../src/interfaces/IPortfolio.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Forked-mainnet end-to-end simulation of the Titans (TTAN) launch against the LIVE core.
///         Reproduces the full broadcast sequence — onboard (Chainlink-only) -> wire Chainlink-only depeg
///         monitor + swap adapter into the factory -> create TTAN Index -> mint — using the real live
///         NAVOracle/PoC/Factory, real bStock tokens + Chainlink feeds, and real PancakeSwap V3 pools.
///
///         SKIPPED unless FORK_RPC is set, so CI stays hermetic. Run:
///           FORK_RPC=https://bsc-dataseed.bnbchain.org forge test --match-path test/Titans.fork.t.sol -vv
contract TitansForkTest is Test {
    // ── Live core (chainId 56) ──
    NAVOracle internal constant NAV = NAVOracle(0xbe263035a704E5039aCaB282AB011DF8175526e3);
    ProofOfCollateral internal constant POC = ProofOfCollateral(0xE28c10B5751bB3E64525fE85951F4A581e253c60);
    PortfolioFactory internal constant FACTORY = PortfolioFactory(0x514ff906D211c86685db3DA68B8d18876A1665bd);
    address internal constant ADMIN = 0x2e7FaF4a5c5705d87e7AB58c4a879D7F8aDb933C; // holds all admin roles

    // ── External infra ──
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    // Venus ResilientOracle — authorized reader of the access-gated bStock Chainlink SingleFeeds.
    IVenusOracle internal constant VENUS_ORACLE = IVenusOracle(0x6592b5DE802159F3E74B2486b091D11a8256ab8A);

    // ── Titans basket ──
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    uint24 internal constant NVDAB_FEE = 500;
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    uint24 internal constant SPCXB_FEE = 2500;

    uint256 internal constant BPS = 10_000;

    function _skip() internal returns (bool) {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            emit log("skipping: set FORK_RPC to run the Titans fork simulation");
            vm.skip(true);
            return true;
        }
        vm.createSelectFork(rpc);
        return false;
    }

    function test_titansEndToEndOnLiveCore() public {
        if (_skip()) return;

        // ── Step 1: onboard NVDAB + SPCXB, Chainlink-only (secondary = 0) ──
        vm.startPrank(ADMIN);
        _configure(NVDAB);
        _configure(SPCXB);
        POC.attest(NVDAB, BPS, keccak256("manual-100pct-nvdab"));
        POC.attest(SPCXB, BPS, keccak256("manual-100pct-spcxb"));

        // Prices must be sane off Chainlink (NVDA ~$100-400, SPCX ~$50-400 — wide sanity bands).
        (uint256 pN,, bool sN) = NAV.getPrice(NVDAB);
        (uint256 pS,, bool sS) = NAV.getPrice(SPCXB);
        assertFalse(sN, "NVDAB fresh");
        assertFalse(sS, "SPCXB fresh");
        assertGt(pN, 50e18);
        assertLt(pN, 1000e18);
        assertGt(pS, 20e18);
        assertLt(pS, 1000e18);

        // ── Step 2: deploy + wire the Chainlink-only depeg monitor and the V3 swap adapter ──
        ChainlinkOnlyDepegMonitor monitor = new ChainlinkOnlyDepegMonitor(ADMIN, INAVOracle(address(NAV)));
        PancakeV3SwapAdapter swap = new PancakeV3SwapAdapter(ADMIN, V3_ROUTER, address(NAV), USDT);
        swap.setPoolFee(USDT, NVDAB, NVDAB_FEE); // NVDAB/USDT lives on the 0.05% tier
        swap.setPoolFee(USDT, SPCXB, SPCXB_FEE); // SPCXB/USDT on 0.25% (== default, explicit for clarity)

        _rewire(address(swap), address(monitor));

        // Allow-list gate must now pass for both components under the Chainlink-only monitor.
        assertTrue(monitor.isTradingSafe(NVDAB), "NVDAB safe");
        assertTrue(monitor.isTradingSafe(SPCXB), "SPCXB safe");

        // ── Step 3: create the Titans (TTAN) zero-fee auto-rebalancing Index, 40/60 (deep-liquidity tilt) ──
        address[] memory tokens = new address[](2);
        tokens[0] = NVDAB;
        tokens[1] = SPCXB;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 4000; // NVDAB 40%
        weights[1] = 6000; // SPCXB 60%
        IPortfolio.Component[] memory comps = new IPortfolio.Component[](2);
        comps[0] = IPortfolio.Component({ asset: NVDAB, weightBps: 4000 });
        comps[1] = IPortfolio.Component({ asset: SPCXB, weightBps: 6000 });

        FixedWeightStrategy strategy = new FixedWeightStrategy(ADMIN);
        strategy.setWeights(tokens, weights);
        address ttan = FACTORY.createIndex(
            "Titans", "TTAN", USDT, comps, /*maxSlippageBps*/ 1000, ADMIN, address(strategy), /*tolerance*/ 100, /*maxTrade*/ 5000
        );
        vm.stopPrank();
        assertTrue(ttan != address(0), "TTAN deployed");

        // ── Step 4: a user mints TTAN with USDT; the vault swaps into NVDAB + SPCXB ──
        address user = makeAddr("titans-user");
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(100e18)); // 100 USDT
        deal(USDT, user, mintAmount);

        vm.startPrank(user);
        IERC20(USDT).approve(ttan, mintAmount);
        uint256 shares = IPortfolio(ttan).mint(mintAmount, 0, block.timestamp + 300);
        vm.stopPrank();

        assertGt(shares, 0, "minted shares");
        // First mint: navPerShare starts at 1e18, so shares ~= deposited USD value (minus swap costs).
        emit log_named_uint("TTAN shares minted", shares);
        emit log_named_uint("TTAN NAV (18dec USD)", IPortfolio(ttan).totalNAV());
        emit log_named_uint("vault NVDAB balance", IERC20(NVDAB).balanceOf(ttan));
        emit log_named_uint("vault SPCXB balance", IERC20(SPCXB).balanceOf(ttan));

        // The vault actually acquired both components (the swaps executed on the live pools).
        assertGt(IERC20(NVDAB).balanceOf(ttan), 0, "acquired NVDAB");
        assertGt(IERC20(SPCXB).balanceOf(ttan), 0, "acquired SPCXB");
        // NAV should be within a sane band of the deposit (swap fees/impact < 10%).
        assertGt(IPortfolio(ttan).totalNAV(), (mintAmount * 90) / 100, "NAV ~ deposit");
    }

    function _configure(address token) internal {
        VenusOracleAdapter primary = new VenusOracleAdapter(VENUS_ORACLE, token);
        NAV.configureAsset(
            token,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(primary)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 86_400,
                maxClosedStaleness: 604_800,
                maxDeviationBps: 0,
                maxDriftBps: 1000,
                configured: false
            })
        );
    }

    function _rewire(address swap, address monitor) internal {
        FACTORY.setWiring(
            PortfolioFactory.Wiring({
                navOracle: FACTORY.navOracle(),
                proofOfCollateral: FACTORY.proofOfCollateral(),
                depegMonitor: monitor,
                swapRouter: swap,
                feeManager: FACTORY.feeManager(),
                indexImplementation: FACTORY.indexImplementation(),
                vaultImplementation: FACTORY.vaultImplementation(),
                protocolTreasury: FACTORY.protocolTreasury(),
                protocolCutBps: FACTORY.protocolCutBps()
            })
        );
    }
}
