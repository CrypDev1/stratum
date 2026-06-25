// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { STRAT } from "./STRAT.sol";

/// @title EmissionsMinter
/// @notice Linear STRAT emission schedule with optional periodic decay. Mints accrued emissions to a
///         recipient (the GaugeController) and can NEVER exceed the schedule.
/// @dev `mintable()` = rate · elapsed since last mint. The STRAT cap is the ultimate ceiling. Governance
///      can change the rate (e.g. to apply a decay step) but cannot retroactively mint past emissions.
contract EmissionsMinter is AccessControl {
    bytes32 public constant EMISSIONS_ADMIN = keccak256("EMISSIONS_ADMIN");

    /// @notice The STRAT token.
    STRAT public immutable strat;
    /// @notice Emission rate in tokens per second.
    uint256 public ratePerSecond;
    /// @notice Timestamp emissions were last minted.
    uint256 public lastMint;
    /// @notice Total emitted so far.
    uint256 public totalEmitted;

    event RateSet(uint256 ratePerSecond);
    event Emitted(address indexed to, uint256 amount);

    error ZeroAddress();

    constructor(address admin, STRAT strat_, uint256 ratePerSecond_) {
        if (address(strat_) == address(0)) revert ZeroAddress();
        strat = strat_;
        ratePerSecond = ratePerSecond_;
        lastMint = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMISSIONS_ADMIN, admin);
    }

    /// @notice Set the emission rate (decay step / schedule change).
    /// @dev SECURITY: EMISSIONS_ADMIN only. Settles pending emissions at the old rate first so the
    ///      change is not retroactive.
    function setRate(uint256 ratePerSecond_, address to) external onlyRole(EMISSIONS_ADMIN) {
        _emit(to);
        ratePerSecond = ratePerSecond_;
        emit RateSet(ratePerSecond_);
    }

    /// @notice Emissions accrued since the last mint.
    function mintable() public view returns (uint256) {
        return ratePerSecond * (block.timestamp - lastMint);
    }

    /// @notice Mint accrued emissions to `to`.
    /// @dev SECURITY: EMISSIONS_ADMIN only (the keeper). Mints exactly `mintable()`; never more than the
    ///      schedule. The STRAT cap may clip the final mint.
    function emitTo(address to) external onlyRole(EMISSIONS_ADMIN) returns (uint256 amount) {
        return _emit(to);
    }

    function _emit(address to) internal returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = mintable();
        lastMint = block.timestamp;
        if (amount == 0) return 0;
        totalEmitted += amount;
        strat.mint(to, amount);
        emit Emitted(to, amount);
    }
}
