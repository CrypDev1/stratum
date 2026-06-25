// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IPortfolio } from "../interfaces/IPortfolio.sol";
import { IFeeManager } from "../interfaces/IFeeManager.sol";
import { IProofOfCollateral } from "../interfaces/IProofOfCollateral.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { PortfolioBase } from "./PortfolioBase.sol";
import { IndexPortfolio } from "./IndexPortfolio.sol";
import { VaultPortfolio } from "./VaultPortfolio.sol";

/// @title PortfolioFactory
/// @notice Permissionless deployment of Index and Vault portfolios via minimal-proxy clones.
/// @dev Injects the shared L0 wiring (oracle/PoC/depeg/router), enforces the protocol fee cut, and
///      gates every component on L0 health: a portfolio can only include assets with a fresh, healthy
///      proof-of-collateral AND safe trading status. Registers each deployment for discovery.
contract PortfolioFactory is AccessControl {
    /// @notice Role allowed to update implementations, wiring and protocol params.
    bytes32 public constant FACTORY_ADMIN = keccak256("FACTORY_ADMIN");

    /// @notice IndexPortfolio implementation cloned for new indexes.
    address public indexImplementation;
    /// @notice VaultPortfolio implementation cloned for new vaults.
    address public vaultImplementation;

    address public navOracle;
    address public proofOfCollateral;
    address public depegMonitor;
    address public swapRouter;
    address public feeManager;

    /// @notice Protocol treasury receiving the protocol fee cut.
    address public protocolTreasury;
    /// @notice Protocol's cut of all portfolio fees (bps).
    uint16 public protocolCutBps;

    address[] public allPortfolios;
    mapping(address => bool) public isPortfolio;

    /// @notice Emitted when a portfolio is deployed.
    event PortfolioCreated(address indexed portfolio, address indexed creator, bool isVault);
    /// @notice Emitted when protocol fee params change.
    event ProtocolParamsSet(address treasury, uint16 cutBps);

    error UnhealthyAsset(address asset);
    error UnsafeAsset(address asset);
    error ZeroAddress();
    error CutTooHigh();

    struct Wiring {
        address navOracle;
        address proofOfCollateral;
        address depegMonitor;
        address swapRouter;
        address feeManager;
        address indexImplementation;
        address vaultImplementation;
        address protocolTreasury;
        uint16 protocolCutBps;
    }

    /// @param admin Factory admin.
    /// @param w Shared wiring + protocol params.
    constructor(address admin, Wiring memory w) {
        _set(w);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FACTORY_ADMIN, admin);
    }

    /// @notice Update wiring/implementations/protocol params.
    /// @dev SECURITY: FACTORY_ADMIN only.
    function setWiring(Wiring calldata w) external onlyRole(FACTORY_ADMIN) {
        _set(w);
    }

    function _set(Wiring memory w) internal {
        if (
            w.navOracle == address(0) || w.proofOfCollateral == address(0) || w.depegMonitor == address(0)
                || w.swapRouter == address(0) || w.indexImplementation == address(0)
                || w.vaultImplementation == address(0) || w.protocolTreasury == address(0)
        ) revert ZeroAddress();
        if (w.protocolCutBps > 5_000) revert CutTooHigh();
        navOracle = w.navOracle;
        proofOfCollateral = w.proofOfCollateral;
        depegMonitor = w.depegMonitor;
        swapRouter = w.swapRouter;
        feeManager = w.feeManager;
        indexImplementation = w.indexImplementation;
        vaultImplementation = w.vaultImplementation;
        protocolTreasury = w.protocolTreasury;
        protocolCutBps = w.protocolCutBps;
        emit ProtocolParamsSet(w.protocolTreasury, w.protocolCutBps);
    }

    /// @notice Deploy a new rules-based IndexPortfolio.
    /// @dev SECURITY: permissionless. Validates every component against L0 health before deploying.
    /// @param name Share token name.
    /// @param symbol Share token symbol.
    /// @param quoteAsset Quote/deposit asset.
    /// @param comps Basket components (weights sum to 10_000).
    /// @param maxSlippageBps Per-swap slippage tolerance.
    /// @param admin Portfolio admin/rebalancer.
    /// @param strategy Weight strategy.
    /// @param toleranceBps Rebalance no-trade band.
    /// @param maxTradeBps Per-asset max sell per rebalance.
    /// @return portfolio The deployed clone address.
    function createIndex(
        string calldata name,
        string calldata symbol,
        address quoteAsset,
        IPortfolio.Component[] calldata comps,
        uint16 maxSlippageBps,
        address admin,
        address strategy,
        uint16 toleranceBps,
        uint16 maxTradeBps
    ) external returns (address portfolio) {
        _validateComponents(comps);
        portfolio = Clones.clone(indexImplementation);
        IndexPortfolio(portfolio)
            .initialize(
                _params(name, symbol, quoteAsset, comps, maxSlippageBps, admin), strategy, toleranceBps, maxTradeBps
            );
        _register(portfolio, false);
    }

    /// @notice Deploy a new manager-driven VaultPortfolio.
    /// @dev SECURITY: permissionless. Validates components against L0 health; protocol cut + treasury
    ///      are forced from factory config so a creator cannot starve the protocol fee.
    /// @param maxTradeBps Per-trade cap (bps of NAV).
    /// @return portfolio The deployed clone address.
    function createVault(
        string calldata name,
        string calldata symbol,
        address quoteAsset,
        IPortfolio.Component[] calldata comps,
        uint16 maxSlippageBps,
        address admin,
        address manager,
        uint16 managementFeeBps,
        uint16 performanceFeeBps,
        uint16 maxTradeBps
    ) external returns (address portfolio) {
        _validateComponents(comps);
        portfolio = Clones.clone(vaultImplementation);
        IFeeManager.FeeConfig memory cfg = IFeeManager.FeeConfig({
            managementFeeBps: managementFeeBps,
            performanceFeeBps: performanceFeeBps,
            protocolCutBps: protocolCutBps,
            manager: manager,
            protocol: protocolTreasury
        });
        VaultPortfolio(portfolio)
            .initialize(_params(name, symbol, quoteAsset, comps, maxSlippageBps, admin), feeManager, cfg, maxTradeBps);
        _register(portfolio, true);
    }

    /// @notice Number of portfolios deployed.
    function portfolioCount() external view returns (uint256) {
        return allPortfolios.length;
    }

    function _params(
        string calldata name,
        string calldata symbol,
        address quoteAsset,
        IPortfolio.Component[] calldata comps,
        uint16 maxSlippageBps,
        address admin
    ) internal view returns (PortfolioBase.InitParams memory p) {
        p.nav = navOracle;
        p.poc = proofOfCollateral;
        p.depeg = depegMonitor;
        p.router = swapRouter;
        p.quoteAsset = quoteAsset;
        p.name = name;
        p.symbol = symbol;
        p.components = comps;
        p.maxSlippageBps = maxSlippageBps;
        p.admin = admin;
    }

    /// @dev Enforce the L0 whitelist: each component must be healthy (PoC) and safe to trade (depeg).
    function _validateComponents(IPortfolio.Component[] calldata comps) internal view {
        for (uint256 i; i < comps.length; ++i) {
            address asset = comps[i].asset;
            if (!IProofOfCollateral(proofOfCollateral).isHealthy(asset)) revert UnhealthyAsset(asset);
            if (!IDepegMonitor(depegMonitor).isTradingSafe(asset)) revert UnsafeAsset(asset);
        }
    }

    function _register(address portfolio, bool isVault) internal {
        allPortfolios.push(portfolio);
        isPortfolio[portfolio] = true;
        emit PortfolioCreated(portfolio, msg.sender, isVault);
    }
}
