// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Capped } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title STRAT
/// @notice Capped-supply governance/utility token of the Stratum protocol.
/// @dev Minting is restricted to MINTER holders (the EmissionsMinter), and hard-capped by ERC20Capped.
contract STRAT is ERC20Capped, AccessControl {
    bytes32 public constant MINTER = keccak256("MINTER");

    /// @param admin Token admin (grants MINTER to the emissions minter).
    /// @param cap_ Hard supply cap.
    /// @param initialMint Amount minted to `admin` at genesis (e.g. for liquidity/airdrop).
    constructor(address admin, uint256 cap_, uint256 initialMint) ERC20("Stratum", "STRAT") ERC20Capped(cap_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (initialMint > 0) _mint(admin, initialMint);
    }

    /// @notice Mint `amount` to `to`.
    /// @dev SECURITY: MINTER-only; ERC20Capped enforces the hard cap.
    function mint(address to, uint256 amount) external onlyRole(MINTER) {
        _mint(to, amount);
    }
}
