// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { INAVOracle } from "../interfaces/INAVOracle.sol";
import { IDepegMonitor } from "../interfaces/IDepegMonitor.sol";
import { LiquidityPool } from "./LiquidityPool.sol";

/// @title PerpEngine
/// @notice Isolated-margin perpetual futures on an index/portfolio asset, marked to the L0 NAV oracle
///         (after-hours aware), with a funding-rate mechanism, liquidations and an insurance fund.
/// @dev The LiquidityPool is the counterparty: trader profit is paid by the pool, trader loss flows to
///      the pool, funding flows trader↔pool. Bad debt beyond a trader's margin is covered by the
///      insurance fund. SECURITY: opens require a fresh oracle AND `DepegMonitor.isTradingSafe`; while
///      the breaker is tripped or the oracle is stale, no new risk can be added.
contract PerpEngine is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PERP_ADMIN = keccak256("PERP_ADMIN");

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    /// @notice Stable collateral.
    IERC20 public immutable asset;
    /// @notice NAV oracle (mark price).
    INAVOracle public immutable nav;
    /// @notice Depeg breaker (open gate).
    IDepegMonitor public immutable depeg;
    /// @notice Counterparty pool.
    LiquidityPool public immutable pool;
    /// @notice The asset whose NAV fair value is the perp mark price.
    address public immutable market;

    // Risk params
    uint256 public maxLeverage = 10e18;
    uint16 public maintenanceMarginBps = 500; // 5%
    uint16 public openFeeBps = 10; // 0.10%
    uint16 public liquidationFeeBps = 100; // 1% of notional to liquidator
    uint16 public maxUtilizationBps = 8_000; // OI <= 80% of pool
    int256 public fundingCoefBpsPerYear = 1_000; // skew-scaled funding coefficient

    /// @notice Insurance fund balance (stable, accounted within the engine).
    uint256 public insuranceFund;
    /// @notice Cumulative funding index (1e18 = 100% of notional); +ve => longs pay.
    int256 public fundingIndex;
    uint256 public lastFundingTime;
    /// @notice Open interest (USD notional, entry-priced) per side.
    uint256 public oiLong;
    uint256 public oiShort;

    struct Position {
        address owner;
        bool isLong;
        uint256 size; // base units (1e18)
        uint256 margin; // stable
        uint256 entryPrice; // 18-dec
        uint256 entryNotional; // USD at entry
        int256 entryFundingIndex;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;

    event Opened(uint256 indexed id, address indexed owner, bool isLong, uint256 size, uint256 margin, uint256 price);
    event Closed(uint256 indexed id, int256 pnl, int256 funding, uint256 payout);
    event Liquidated(uint256 indexed id, address indexed liquidator, uint256 fee);
    event FundingAccrued(int256 fundingIndex);
    event RiskParamsSet();

    error OracleUnsafe();
    error LeverageTooHigh();
    error UtilizationTooHigh();
    error NotOwner();
    error NotLiquidatable();
    error ZeroAmount();
    error DeadlinePassed();

    constructor(
        address admin,
        IERC20 asset_,
        INAVOracle nav_,
        IDepegMonitor depeg_,
        LiquidityPool pool_,
        address market_
    ) {
        asset = asset_;
        nav = nav_;
        depeg = depeg_;
        pool = pool_;
        market = market_;
        lastFundingTime = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PERP_ADMIN, admin);
    }

    /// @notice Set risk parameters.
    /// @dev SECURITY: PERP_ADMIN only.
    function setRiskParams(
        uint256 _maxLeverage,
        uint16 _maintenanceMarginBps,
        uint16 _openFeeBps,
        uint16 _liquidationFeeBps,
        uint16 _maxUtilizationBps,
        int256 _fundingCoefBpsPerYear
    ) external onlyRole(PERP_ADMIN) {
        if (_maxLeverage < WAD || _maintenanceMarginBps > BPS || _maxUtilizationBps > BPS) revert ZeroAmount();
        maxLeverage = _maxLeverage;
        maintenanceMarginBps = _maintenanceMarginBps;
        openFeeBps = _openFeeBps;
        liquidationFeeBps = _liquidationFeeBps;
        maxUtilizationBps = _maxUtilizationBps;
        fundingCoefBpsPerYear = _fundingCoefBpsPerYear;
        emit RiskParamsSet();
    }

    /// @notice Seed the insurance fund with stable.
    function fundInsurance(uint256 amount) external nonReentrant {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        insuranceFund += amount;
    }

    // --------------------------------------------------------------------- //
    //                                 Mark                                  //
    // --------------------------------------------------------------------- //

    /// @notice Current mark price (NAV fair value); reverts if the oracle is stale.
    function markPrice() public view returns (uint256 price, bool afterHours) {
        INAVOracle.PriceData memory d = nav.getPriceData(market);
        if (d.isStale || d.price == 0) revert OracleUnsafe();
        return (d.price, d.afterHours);
    }

    // --------------------------------------------------------------------- //
    //                                Funding                                //
    // --------------------------------------------------------------------- //

    /// @notice Accrue the funding index from the current skew.
    /// @dev SECURITY: permissionless poke. Skew-proportional rate; +ve index => longs pay the pool.
    function accrueFunding() public {
        uint256 elapsed = block.timestamp - lastFundingTime;
        if (elapsed == 0) return;
        uint256 totalOI = oiLong + oiShort;
        if (totalOI > 0) {
            int256 skew = int256(oiLong) - int256(oiShort);
            // rate (1e18 fraction/yr) = coef(bps) * skew/totalOI
            int256 ratePerYear = (fundingCoefBpsPerYear * skew * int256(WAD)) / (int256(BPS) * int256(totalOI));
            fundingIndex += (ratePerYear * int256(elapsed)) / int256(YEAR);
        }
        lastFundingTime = block.timestamp;
        emit FundingAccrued(fundingIndex);
    }

    // --------------------------------------------------------------------- //
    //                               Positions                               //
    // --------------------------------------------------------------------- //

    /// @notice Open an isolated-margin perpetual position.
    /// @dev SECURITY: nonReentrant. Requires fresh oracle + `isTradingSafe(market)`. Enforces leverage
    ///      and pool-utilization caps. Open fee accrues to the insurance fund.
    function open(uint256 margin, uint256 size, bool isLong, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (margin == 0 || size == 0) revert ZeroAmount();
        if (!depeg.isTradingSafe(market)) revert OracleUnsafe();
        accrueFunding();

        (uint256 price,) = markPrice();
        uint256 notional = (size * price) / WAD;

        uint256 fee = (notional * openFeeBps) / BPS;
        asset.safeTransferFrom(msg.sender, address(this), margin);
        if (fee >= margin) revert LeverageTooHigh();
        uint256 netMargin = margin - fee;
        insuranceFund += fee;

        if (notional > (netMargin * maxLeverage) / WAD) revert LeverageTooHigh();

        // Utilization check on the side being added.
        uint256 newOI = (isLong ? oiLong : oiShort) + notional;
        uint256 otherOI = isLong ? oiShort : oiLong;
        uint256 poolAssets = pool.totalAssets();
        if (poolAssets == 0 || (newOI + otherOI) * BPS > poolAssets * maxUtilizationBps) revert UtilizationTooHigh();

        id = nextId++;
        positions[id] = Position({
            owner: msg.sender,
            isLong: isLong,
            size: size,
            margin: netMargin,
            entryPrice: price,
            entryNotional: notional,
            entryFundingIndex: fundingIndex
        });
        if (isLong) oiLong += notional;
        else oiShort += notional;

        emit Opened(id, msg.sender, isLong, size, netMargin, price);
    }

    /// @notice Close an owned position at the current mark.
    /// @dev SECURITY: nonReentrant, owner-only. Settles PnL and funding against the pool; returns the
    ///      residual margin to the trader. Bad debt beyond margin draws on the insurance fund.
    function close(uint256 id) external nonReentrant returns (uint256 payout) {
        Position memory pos = positions[id];
        if (pos.owner != msg.sender) revert NotOwner();
        accrueFunding();
        payout = _settle(id, pos, msg.sender, 0);
        emit Closed(id, _pnl(pos, _price()), _funding(pos), payout);
    }

    /// @notice Liquidate an under-margined position.
    /// @dev SECURITY: nonReentrant. Allowed only when the oracle is fresh AND `isTradingSafe` (no
    ///      liquidation during a halt) and equity < maintenance margin. A fee is paid to the liquidator.
    function liquidate(uint256 id) external nonReentrant {
        Position memory pos = positions[id];
        if (pos.owner == address(0)) revert NotOwner();
        if (!depeg.isTradingSafe(market)) revert OracleUnsafe();
        accrueFunding();

        uint256 price = _price();
        int256 equity = int256(pos.margin) + _pnl(pos, price) - _funding(pos);
        uint256 notionalNow = (pos.size * price) / WAD;
        uint256 maintenance = (notionalNow * maintenanceMarginBps) / BPS;
        if (equity >= int256(maintenance)) revert NotLiquidatable();

        uint256 fee = (notionalNow * liquidationFeeBps) / BPS;
        _settle(id, pos, pos.owner, fee);
        if (fee > 0) {
            uint256 pay = fee <= insuranceFund ? fee : insuranceFund;
            insuranceFund -= pay;
            asset.safeTransfer(msg.sender, pay);
        }
        emit Liquidated(id, msg.sender, fee);
    }

    /// @dev Settle position `id` held by `pos`, paying the residual to `to`. `liqFeeReserved` is held
    ///      back from the trader payout (consumed by the liquidator). Returns the trader payout.
    function _settle(uint256 id, Position memory pos, address to, uint256 liqFeeReserved)
        internal
        returns (uint256 payout)
    {
        uint256 price = _price();
        int256 pnl = _pnl(pos, price);
        int256 funding = _funding(pos);

        // Remove open interest.
        if (pos.isLong) oiLong = oiLong > pos.entryNotional ? oiLong - pos.entryNotional : 0;
        else oiShort = oiShort > pos.entryNotional ? oiShort - pos.entryNotional : 0;
        delete positions[id];

        // Pool settlement: pool pays (pnl - funding) when positive, else receives.
        int256 poolToTrader = pnl - funding;
        if (poolToTrader > 0) {
            pool.payOut(address(this), uint256(poolToTrader));
        } else if (poolToTrader < 0) {
            _payPool(uint256(-poolToTrader), pos.margin);
        }

        int256 net = int256(pos.margin) + pnl - funding;
        uint256 traderValue = net > 0 ? uint256(net) : 0;
        // Liquidation fee is taken out of the trader's residual first.
        if (liqFeeReserved > 0) {
            insuranceFund += liqFeeReserved <= traderValue ? liqFeeReserved : traderValue;
            traderValue = traderValue > liqFeeReserved ? traderValue - liqFeeReserved : 0;
        }
        payout = traderValue;
        if (payout > 0) asset.safeTransfer(to, payout);
    }

    /// @dev Send `owe` to the pool, drawing first on this position's margin, then the insurance fund.
    function _payPool(uint256 owe, uint256 margin) internal {
        uint256 fromMargin = owe <= margin ? owe : margin;
        uint256 shortfall = owe > margin ? owe - margin : 0;
        uint256 fromInsurance = shortfall <= insuranceFund ? shortfall : insuranceFund;
        insuranceFund -= fromInsurance;
        uint256 total = fromMargin + fromInsurance;
        if (total > 0) asset.safeTransfer(address(pool), total);
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //

    /// @notice Signed PnL (USD) of a position at `price`.
    function _pnl(Position memory pos, uint256 price) internal pure returns (int256) {
        int256 diff = int256(price) - int256(pos.entryPrice);
        int256 raw = (int256(pos.size) * diff) / int256(WAD);
        return pos.isLong ? raw : -raw;
    }

    /// @notice Signed funding owed by a position (positive => trader pays the pool).
    function _funding(Position memory pos) internal view returns (int256) {
        int256 delta = fundingIndex - pos.entryFundingIndex;
        int256 f = (int256(pos.entryNotional) * delta) / int256(WAD);
        return pos.isLong ? f : -f;
    }

    function _price() internal view returns (uint256) {
        (uint256 p,) = markPrice();
        return p;
    }

    /// @notice Health: equity vs maintenance margin (1e18 = at threshold). type(uint).max if no debt.
    function healthFactor(uint256 id) external view returns (uint256) {
        Position memory pos = positions[id];
        if (pos.owner == address(0)) return type(uint256).max;
        uint256 price = _price();
        int256 equity = int256(pos.margin) + _pnl(pos, price) - _funding(pos);
        uint256 notionalNow = (pos.size * price) / WAD;
        uint256 maintenance = (notionalNow * maintenanceMarginBps) / BPS;
        if (maintenance == 0) return type(uint256).max;
        if (equity <= 0) return 0;
        return (uint256(equity) * WAD) / maintenance;
    }

    /// @notice Pool utilization in bps (open interest / pool assets).
    function utilizationBps() external view returns (uint256) {
        uint256 assets = pool.totalAssets();
        if (assets == 0) return 0;
        return ((oiLong + oiShort) * BPS) / assets;
    }
}
