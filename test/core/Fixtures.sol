// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NAVOracle } from "../../src/oracle/NAVOracle.sol";
import { ProofOfCollateral } from "../../src/oracle/ProofOfCollateral.sol";
import { DepegMonitor } from "../../src/oracle/DepegMonitor.sol";
import { INAVOracle } from "../../src/interfaces/INAVOracle.sol";
import { IOracleAdapter } from "../../src/interfaces/IOracleAdapter.sol";
import { MockOracleAdapter } from "../../src/mocks/MockOracleAdapter.sol";
import { MockSwapRouter } from "../../src/mocks/MockSwapRouter.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

import { FeeManager } from "../../src/core/FeeManager.sol";
import { IndexPortfolio } from "../../src/core/IndexPortfolio.sol";
import { VaultPortfolio } from "../../src/core/VaultPortfolio.sol";
import { PortfolioFactory } from "../../src/core/PortfolioFactory.sol";
import { IPortfolio } from "../../src/interfaces/IPortfolio.sol";

/// @notice Shared L1 test scaffold: L0 oracle stack + mock tokens + parity router + factory.
abstract contract Fixtures is Test {
    NAVOracle internal oracle;
    ProofOfCollateral internal poc;
    DepegMonitor internal monitor;
    MockSwapRouter internal router;
    FeeManager internal feeManager;
    PortfolioFactory internal factory;

    MockERC20 internal usdc; // quote, 18 dec
    MockERC20 internal aapl; // bStock, 18 dec
    MockERC20 internal goog; // bStock, 18 dec

    MockOracleAdapter internal aaplFeed;
    MockOracleAdapter internal googFeed;
    MockOracleAdapter internal aaplDex;
    MockOracleAdapter internal googDex;

    address internal admin = address(0xA11CE);
    address internal treasury = address(0x7EE5);
    address internal alice = address(0xA11);
    address internal bob = address(0xB0B);

    uint256 internal constant AAPL_PRICE = 200e18;
    uint256 internal constant GOOG_PRICE = 150e18;

    function _deployL0() internal {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        aapl = new MockERC20("bAAPL", "bAAPL", 18);
        goog = new MockERC20("bGOOG", "bGOOG", 18);

        oracle = new NAVOracle(admin);
        poc = new ProofOfCollateral(admin);
        monitor = new DepegMonitor(admin, INAVOracle(address(oracle)));
        router = new MockSwapRouter();
        feeManager = new FeeManager();

        aaplFeed = new MockOracleAdapter(AAPL_PRICE, block.timestamp);
        googFeed = new MockOracleAdapter(GOOG_PRICE, block.timestamp);
        aaplDex = new MockOracleAdapter(AAPL_PRICE, block.timestamp);
        googDex = new MockOracleAdapter(GOOG_PRICE, block.timestamp);

        vm.startPrank(admin);
        _configAsset(address(aapl), aaplFeed, aaplDex);
        _configAsset(address(goog), googFeed, googDex);
        poc.attest(address(aapl), 10_000, bytes32("a"));
        poc.attest(address(goog), 10_000, bytes32("g"));
        vm.stopPrank();

        // Router prices at oracle parity.
        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(aapl), AAPL_PRICE);
        router.setPrice(address(goog), GOOG_PRICE);
    }

    function _configAsset(address asset, MockOracleAdapter feed, MockOracleAdapter dex) internal {
        oracle.configureAsset(
            asset,
            NAVOracle.AssetConfig({
                primary: IOracleAdapter(address(feed)),
                secondary: IOracleAdapter(address(0)),
                maxStaleness: 1 days,
                maxClosedStaleness: 7 days,
                maxDeviationBps: 500,
                maxDriftBps: 1000,
                configured: false
            })
        );
        monitor.setDexSource(asset, IOracleAdapter(address(dex)));
    }

    function _deployFactory() internal {
        address indexImpl = address(new IndexPortfolio());
        address vaultImpl = address(new VaultPortfolio());
        PortfolioFactory.Wiring memory w = PortfolioFactory.Wiring({
            navOracle: address(oracle),
            proofOfCollateral: address(poc),
            depegMonitor: address(monitor),
            swapRouter: address(router),
            feeManager: address(feeManager),
            indexImplementation: indexImpl,
            vaultImplementation: vaultImpl,
            protocolTreasury: treasury,
            protocolCutBps: 1000
        });
        factory = new PortfolioFactory(admin, w);
    }

    function _equalComponents() internal view returns (IPortfolio.Component[] memory comps) {
        comps = new IPortfolio.Component[](2);
        comps[0] = IPortfolio.Component({ asset: address(aapl), weightBps: 5000 });
        comps[1] = IPortfolio.Component({ asset: address(goog), weightBps: 5000 });
    }

    function _fundUSDC(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    /// @dev Move feed, DEX and router prices in lockstep so NAV is fresh and depeg stays ~0.
    function _setAaplPrice(uint256 price) internal {
        aaplFeed.setPrice(price);
        aaplDex.setPrice(price);
        router.setPrice(address(aapl), price);
    }

    function _setGoogPrice(uint256 price) internal {
        googFeed.setPrice(price);
        googDex.setPrice(price);
        router.setPrice(address(goog), price);
    }

    /// @dev Re-stamp current prices so feeds aren't stale after time travel.
    function _refreshFeeds() internal {
        (uint256 a,) = aaplFeed.latestPrice();
        (uint256 g,) = googFeed.latestPrice();
        _setAaplPrice(a);
        _setGoogPrice(g);
    }
}
