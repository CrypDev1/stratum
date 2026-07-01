// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EarnVault } from "./EarnVault.sol";

/// @title EarnVaultFactory
/// @notice Deploys Stratum Earn ERC-4626 yield vaults as minimal-proxy clones, mirroring the core
///         {PortfolioFactory} style (implementation + `initialize`, registry for discovery).
/// @dev Additive to the live core — deploys nothing that touches or modifies existing core contracts. Each
///      vault is created without a strategy; a strategy (Venus/Lista/…) is deployed separately against the
///      new vault address and attached by the vault's admin via `EarnVault.setStrategy`, because a strategy
///      must be constructed with its owning vault's address (only known after the clone exists).
contract EarnVaultFactory is AccessControl {
    /// @notice Role allowed to update the vault implementation.
    bytes32 public constant FACTORY_ADMIN = keccak256("FACTORY_ADMIN");

    /// @notice EarnVault implementation cloned for new vaults.
    address public vaultImplementation;

    address[] public allVaults;
    mapping(address => bool) public isVault;

    /// @notice Emitted when an Earn vault is deployed.
    event VaultCreated(address indexed vault, address indexed creator, address indexed asset, address admin);
    /// @notice Emitted when the vault implementation changes.
    event ImplementationSet(address indexed implementation);

    error ZeroAddress();

    /// @param admin Factory admin.
    /// @param vaultImplementation_ EarnVault implementation (with initializers disabled).
    constructor(address admin, address vaultImplementation_) {
        if (admin == address(0) || vaultImplementation_ == address(0)) revert ZeroAddress();
        vaultImplementation = vaultImplementation_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FACTORY_ADMIN, admin);
        emit ImplementationSet(vaultImplementation_);
    }

    /// @notice Update the vault implementation used for future clones.
    /// @dev SECURITY: FACTORY_ADMIN only. Does not affect already-deployed vaults.
    function setImplementation(address vaultImplementation_) external onlyRole(FACTORY_ADMIN) {
        if (vaultImplementation_ == address(0)) revert ZeroAddress();
        vaultImplementation = vaultImplementation_;
        emit ImplementationSet(vaultImplementation_);
    }

    /// @notice Deploy a new Earn vault for `asset`, administered by `admin`.
    /// @dev SECURITY: permissionless. The vault starts with no strategy; `admin` attaches one afterwards.
    /// @param asset Base deposit asset (e.g. USDT).
    /// @param name Share token name.
    /// @param symbol Share token symbol.
    /// @param admin Vault admin (EARN_ADMIN + DEFAULT_ADMIN_ROLE).
    /// @return vault The deployed clone address.
    function createVault(address asset, string calldata name, string calldata symbol, address admin)
        external
        returns (address vault)
    {
        vault = Clones.clone(vaultImplementation);
        EarnVault(vault).initialize(EarnVault.InitParams({ asset: asset, name: name, symbol: symbol, admin: admin }));
        allVaults.push(vault);
        isVault[vault] = true;
        emit VaultCreated(vault, msg.sender, asset, admin);
    }

    /// @notice Number of vaults deployed.
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
