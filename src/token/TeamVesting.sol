// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TeamVesting
/// @notice Simple cliff + linear vesting of the team STRAT allocation. Tokens are fully locked until the
///         cliff, then vest linearly to a single beneficiary over `duration`, reaching 100% at
///         `start + cliff + duration`.
/// @dev The vesting amount is anchored to everything ever deposited (current balance + already released),
///      so the full allocation is sent to this contract once at deploy and nothing else is needed.
contract TeamVesting {
    using SafeERC20 for IERC20;

    /// @notice The vesting token (STRAT).
    IERC20 public immutable token;
    /// @notice Recipient of vested tokens.
    address public immutable beneficiary;
    /// @notice Vesting start (deploy timestamp).
    uint256 public immutable start;
    /// @notice Cliff duration after `start`: tokens are fully locked until `start + cliff`.
    uint256 public immutable cliff;
    /// @notice Linear vesting duration after the cliff: fully vested at `start + cliff + duration`.
    uint256 public immutable duration;
    /// @notice Total amount already released to the beneficiary.
    uint256 public released;

    event Released(uint256 amount);

    error ZeroAddress();
    error NothingToRelease();

    /// @param token_ Vesting token (STRAT).
    /// @param beneficiary_ Recipient of vested tokens.
    /// @param cliff_ Cliff duration (e.g. 90 days for a 3-month cliff).
    /// @param duration_ Linear vesting duration after the cliff (e.g. 730 days for 24 months).
    constructor(IERC20 token_, address beneficiary_, uint256 cliff_, uint256 duration_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        token = token_;
        beneficiary = beneficiary_;
        start = block.timestamp;
        cliff = cliff_;
        duration = duration_;
    }

    /// @notice Total tokens under vesting management (unreleased balance + already released).
    function total() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    /// @notice Amount vested by `timestamp` — zero before the cliff, then linear to the full total.
    function vestedAmount(uint256 timestamp) public view returns (uint256) {
        uint256 cliffEnd = start + cliff;
        if (timestamp < cliffEnd) return 0;
        uint256 vestingEnd = cliffEnd + duration;
        uint256 t = total();
        if (timestamp >= vestingEnd) return t;
        return (t * (timestamp - cliffEnd)) / duration;
    }

    /// @notice Amount currently releasable to the beneficiary.
    function releasable() public view returns (uint256) {
        return vestedAmount(block.timestamp) - released;
    }

    /// @notice Release all currently-vested tokens to the beneficiary. Callable by anyone.
    function release() external returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        emit Released(amount);
        token.safeTransfer(beneficiary, amount);
    }
}
