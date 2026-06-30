// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Mock4626
/// @notice Minimal ERC-4626 vault for tests. Yield is simulated by transferring extra underlying into the
///         vault (a donation), which raises `convertToAssets` for existing share holders.
/// @dev TODO(integration): replaced by the real Lista ERC-4626 vault on testnet/mainnet.
contract Mock4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Vault", "mVLT") ERC4626(asset_) { }
}
