// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PortfolioBase } from "./PortfolioBase.sol";
import { IFeeManager } from "../interfaces/IFeeManager.sol";
import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VaultPortfolio
/// @notice Manager-driven portfolio: a `manager` allocates within guardrails and earns fees.
/// @dev Same NAV-fair accounting as the index. The manager may only trade whitelisted assets (the
///      basket components + quote), each trade capped to a bps-of-NAV size, with no leverage (1x).
///      Streaming + high-water-mark performance fees are charged via dilution (FeeManager) on every
///      accrual; the protocol takes a configurable cut of all fees.
contract VaultPortfolio is PortfolioBase {
    using SafeERC20 for IERC20;

    /// @notice Role held by the vault manager (proposes/executes allocations).
    bytes32 public constant MANAGER = keccak256("MANAGER");

    /// @notice Fee math contract.
    IFeeManager public feeManager;
    /// @notice Fee configuration.
    IFeeManager.FeeConfig public feeConfig;
    /// @notice Per-trade size cap as bps of NAV.
    uint16 public maxTradeBps;
    /// @notice High-water mark (navPerShare) for performance fees.
    uint256 public highWaterMark;
    /// @notice Timestamp of last fee accrual.
    uint256 public lastAccrual;
    /// @notice Manager's declared target weights (informational; basis points by component index).
    uint256[] public targetWeights;

    /// @notice Emitted when the manager executes a trade.
    event TradeExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    /// @notice Emitted when fees are accrued (minted via dilution).
    event FeesAccrued(uint256 managementShares, uint256 performanceShares, uint256 newHighWaterMark);
    /// @notice Emitted when the manager declares target weights.
    event TargetWeightsSet(uint256[] weightsBps);

    error InvalidParams();
    error NotWhitelisted(address asset);
    error TradeTooLarge();

    /// @notice Initialize a cloned VaultPortfolio.
    /// @param p Base init params (p.admin is the manager + admin).
    /// @param feeManager_ Fee math contract.
    /// @param cfg Fee configuration.
    /// @param maxTradeBps_ Per-trade size cap (bps of NAV).
    function initialize(
        InitParams calldata p,
        address feeManager_,
        IFeeManager.FeeConfig calldata cfg,
        uint16 maxTradeBps_
    ) external initializer {
        __VaultPortfolio_init(p, feeManager_, cfg, maxTradeBps_);
    }

    /// @dev Shared vault initializer; AgentVault calls this from its own initializer.
    function __VaultPortfolio_init(
        InitParams calldata p,
        address feeManager_,
        IFeeManager.FeeConfig calldata cfg,
        uint16 maxTradeBps_
    ) internal onlyInitializing {
        if (feeManager_ == address(0) || maxTradeBps_ == 0 || maxTradeBps_ > BPS || cfg.manager == address(0)) {
            revert InvalidParams();
        }
        __PortfolioBase_init(p);
        feeManager = IFeeManager(feeManager_);
        feeConfig = cfg;
        maxTradeBps = maxTradeBps_;
        highWaterMark = 1e18;
        lastAccrual = block.timestamp;
        _grantRole(MANAGER, cfg.manager);
    }

    /// @notice Declare manager target weights (used off-chain / for guidance; trading is via executeTrade).
    /// @dev SECURITY: MANAGER only. Weights must match component count and sum to 10_000.
    function setTargetWeights(uint256[] calldata weightsBps) external onlyRole(MANAGER) {
        if (weightsBps.length != _components.length) revert InvalidParams();
        uint256 sum;
        for (uint256 i; i < weightsBps.length; ++i) {
            sum += weightsBps[i];
        }
        if (sum != BPS) revert InvalidParams();
        targetWeights = weightsBps;
        emit TargetWeightsSet(weightsBps);
    }

    /// @notice Manager swaps between whitelisted assets within the per-trade cap.
    /// @dev SECURITY: MANAGER + nonReentrant. Whitelist = components + quote (no arbitrary assets, no
    ///      leverage). Trade value capped to maxTradeBps of NAV. Output asset gated on the depeg breaker.
    ///      Slippage + deadline enforced on the swap.
    function executeTrade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 deadline)
        public
        virtual
        nonReentrant
        onlyRole(MANAGER)
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amountIn == 0) revert ZeroAmount();
        if (!_whitelisted(tokenIn) || !_whitelisted(tokenOut)) revert NotWhitelisted(tokenIn);
        // Gate equity components on the depeg breaker; the quote stablecoin has no equity feed.
        if (tokenOut != address(quote) && !depeg.isTradingSafe(tokenOut)) revert TradingUnsafe(tokenOut);

        // Cap trade value to maxTradeBps of NAV.
        uint256 valueIn = _valueOf(tokenIn, amountIn);
        uint256 cap = (totalNAV() * maxTradeBps) / BPS;
        if (valueIn > cap) revert TradeTooLarge();

        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.swapExactIn(tokenIn, tokenOut, amountIn, minOut, deadline, address(this));
        emit TradeExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Accrue streaming + performance fees by minting dilution shares to manager and protocol.
    /// @dev SECURITY: permissionless (anyone can poke). Performance fee only above the high-water mark.
    ///      Requires fresh prices (navPerShare). Updates HWM and lastAccrual.
    function accrueFees() public {
        uint256 supply = share.totalSupply();
        if (supply == 0) {
            lastAccrual = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastAccrual;
        uint256 navPS = navPerShare();

        uint256 mgmtShares = feeManager.managementFeeShares(supply, feeConfig.managementFeeBps, elapsed);
        uint256 perfShares = feeManager.performanceFeeShares(supply, navPS, highWaterMark, feeConfig.performanceFeeBps);

        lastAccrual = block.timestamp;
        if (navPS > highWaterMark) highWaterMark = navPS;

        uint256 totalFee = mgmtShares + perfShares;
        if (totalFee > 0) {
            uint256 protocolShares = (totalFee * feeConfig.protocolCutBps) / BPS;
            uint256 managerShares = totalFee - protocolShares;
            if (protocolShares > 0) share.mint(feeConfig.protocol, protocolShares);
            if (managerShares > 0) share.mint(feeConfig.manager, managerShares);
        }
        emit FeesAccrued(mgmtShares, perfShares, highWaterMark);
    }

    /// @dev Accrue fees on the pre-deposit state so new depositors don't pay fees on their own capital.
    function _preMint() internal override {
        accrueFees();
    }

    /// @notice Whether `asset` is tradeable by the manager (component or quote).
    function _whitelisted(address asset) internal view returns (bool) {
        return _isComponent[asset] || asset == address(quote);
    }

    /// @dev USD (18-dec) value of `amount` of `asset` at oracle price.
    function _valueOf(address asset, uint256 amount) internal view returns (uint256) {
        (uint256 price,, bool stale) = nav.getPrice(asset);
        if (stale || price == 0) revert PriceUnusable(asset);
        uint8 dec = IERC20Metadata(asset).decimals();
        return (amount * price) / (10 ** dec);
    }
}
