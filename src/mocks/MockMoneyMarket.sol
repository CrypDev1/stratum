// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IMoneyMarket } from "../interfaces/IMoneyMarket.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @title MockMoneyMarket
/// @notice Interest-bearing lending market for tests; index grows linearly at a settable APR.
/// @dev Mints the interest shortfall on redemption (infinite-liquidity mock). TODO(integration):
///      replace with the real Venus/Lista market contract.
contract MockMoneyMarket is IMoneyMarket {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    address public immutable underlying;
    uint256 public rateBps; // supply APR

    uint256 internal _index = WAD; // accrual index
    uint256 internal _lastUpdate;
    mapping(address => uint256) internal _scaled; // account => scaled balance

    constructor(address underlying_, uint256 rateBps_) {
        underlying = underlying_;
        rateBps = rateBps_;
        _lastUpdate = block.timestamp;
    }

    /// @notice Set the supply APR (bps).
    function setRateBps(uint256 bps) external {
        _accrue();
        rateBps = bps;
    }

    function _currentIndex() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - _lastUpdate;
        if (elapsed == 0 || rateBps == 0) return _index;
        return _index + (_index * rateBps * elapsed) / (BPS * YEAR);
    }

    function _accrue() internal {
        _index = _currentIndex();
        _lastUpdate = block.timestamp;
    }

    /// @inheritdoc IMoneyMarket
    function supply(uint256 amount) external {
        _accrue();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        _scaled[msg.sender] += (amount * WAD) / _index;
    }

    /// @inheritdoc IMoneyMarket
    function redeemUnderlying(uint256 amount) external {
        _accrue();
        uint256 scaledBurn = (amount * WAD + _index - 1) / _index; // round up burn
        uint256 bal = _scaled[msg.sender];
        if (scaledBurn > bal) scaledBurn = bal;
        _scaled[msg.sender] = bal - scaledBurn;

        uint256 have = IERC20(underlying).balanceOf(address(this));
        if (have < amount) {
            // mint the interest shortfall
            MockERC20(underlying).mint(address(this), amount - have);
        }
        IERC20(underlying).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IMoneyMarket
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return (_scaled[account] * _currentIndex()) / WAD;
    }

    /// @inheritdoc IMoneyMarket
    function supplyRatePerYearBps() external view returns (uint256) {
        return rateBps;
    }
}
