// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IVToken } from "../interfaces/external/IVToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @title MockVToken
/// @notice Compound-fork vToken test double whose exchange rate grows linearly at a settable APR.
/// @dev Mints the interest shortfall on redemption (infinite-liquidity mock). underlying = vBal · rate.
///      TODO(integration): replaced by the real Venus vToken on testnet/mainnet.
contract MockVToken is IVToken {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    address public immutable underlying;
    uint256 public rateBps; // supply APR
    uint256 public blocksPerYear;

    uint256 internal _rate = WAD; // exchange rate (underlying per vToken, 1e18 mantissa)
    uint256 internal _lastUpdate;
    mapping(address => uint256) internal _vBal;

    constructor(address underlying_, uint256 rateBps_, uint256 blocksPerYear_) {
        underlying = underlying_;
        rateBps = rateBps_;
        blocksPerYear = blocksPerYear_;
        _lastUpdate = block.timestamp;
    }

    function setRateBps(uint256 bps) external {
        _accrue();
        rateBps = bps;
    }

    function _currentRate() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - _lastUpdate;
        if (elapsed == 0 || rateBps == 0) return _rate;
        return _rate + (_rate * rateBps * elapsed) / (BPS * YEAR);
    }

    function _accrue() internal {
        _rate = _currentRate();
        _lastUpdate = block.timestamp;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        _accrue();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), mintAmount);
        _vBal[msg.sender] += (mintAmount * WAD) / _rate;
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        _accrue();
        uint256 vBurn = (redeemAmount * WAD + _rate - 1) / _rate; // round up
        uint256 bal = _vBal[msg.sender];
        if (vBurn > bal) vBurn = bal;
        _vBal[msg.sender] = bal - vBurn;

        uint256 have = IERC20(underlying).balanceOf(address(this));
        if (have < redeemAmount) MockERC20(underlying).mint(address(this), redeemAmount - have);
        IERC20(underlying).safeTransfer(msg.sender, redeemAmount);
        return 0;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _vBal[owner];
    }

    function exchangeRateStored() external view returns (uint256) {
        return _currentRate();
    }

    function balanceOfUnderlying(address owner) external returns (uint256) {
        _accrue();
        return (_vBal[owner] * _rate) / WAD;
    }

    function supplyRatePerBlock() external view returns (uint256) {
        // rateBps/BPS annual, spread across blocksPerYear, as a 1e18 mantissa per-block rate.
        return (rateBps * WAD) / (BPS * blocksPerYear);
    }
}
