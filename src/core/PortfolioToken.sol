// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PortfolioToken
/// @notice The tradeable BEP-20 share of a Stratum portfolio. 18 decimals.
/// @dev Mint/burn are restricted to the immutable `manager` (the PortfolioBase that deployed it),
///      so supply can only change through NAV-fair mint/redeem accounting.
contract PortfolioToken is ERC20 {
    /// @notice The portfolio manager allowed to mint/burn.
    address public immutable manager;

    error OnlyManager();

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param manager_ The portfolio authorized to mint/burn.
    constructor(string memory name_, string memory symbol_, address manager_) ERC20(name_, symbol_) {
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    /// @notice Mint `amount` shares to `to`.
    /// @dev SECURITY: manager-only; manager enforces NAV-fairness before calling.
    function mint(address to, uint256 amount) external onlyManager {
        _mint(to, amount);
    }

    /// @notice Burn `amount` shares from `from`.
    /// @dev SECURITY: manager-only; called during redeem after pro-rata assets are computed.
    function burn(address from, uint256 amount) external onlyManager {
        _burn(from, amount);
    }
}
