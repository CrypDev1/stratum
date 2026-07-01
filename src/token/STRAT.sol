// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Capped } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title STRAT
/// @notice Capped-supply governance/utility token of the Stratum protocol.
/// @dev Minting is restricted to MINTER holders (the EmissionsMinter), and hard-capped by ERC20Capped.
///      The cap is a hardcoded constant — exactly 1,000,000,000 STRAT — so it can never be misconfigured
///      at deploy and STRAT is never mintable beyond it.
contract STRAT is ERC20Capped, AccessControl {
    bytes32 public constant MINTER = keccak256("MINTER");

    /// @notice Fixed hard supply cap: 1,000,000,000 STRAT (18 decimals). Immutable and uncrossable.
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    /// @param admin Token admin (grants MINTER to the emissions minter, distributes allocations).
    /// @param initialMint Amount minted to `admin` at genesis (used only for the local/test default; the
    ///        production deploy mints 0 here and distributes via the MINTER role instead).
    constructor(address admin, uint256 initialMint) ERC20("Stratum", "STRAT") ERC20Capped(MAX_SUPPLY) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (initialMint > 0) _mint(admin, initialMint);
    }

    /// @notice Mint `amount` to `to`.
    /// @dev SECURITY: MINTER-only; ERC20Capped enforces the hard cap.
    function mint(address to, uint256 amount) external onlyRole(MINTER) {
        _mint(to, amount);
    }
}
