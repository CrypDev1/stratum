// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Freely-mintable ERC20 with configurable decimals, standing in for bStocks/stablecoins in tests.
/// @dev TODO(integration): on BNB Chain these are the real BEP-20 bStock tokens and USDT/USDC.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` to `to` (test helper).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` (test helper).
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
