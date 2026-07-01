// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Chainlink Automation's compatible interface (defined locally to avoid a new dependency). A
///      custom-logic upkeep calls `checkUpkeep` off-chain and, when it returns true, `performUpkeep` on-chain.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

interface IEmissionsMinterLike {
    function mintable() external view returns (uint256);
    function emitTo(address to) external returns (uint256);
}

interface IGaugeDistributorLike {
    function undistributed() external view returns (uint256);
    function distribute() external returns (uint256);
}

/// @title EmissionsAutomation
/// @notice Chainlink-Automation adapter that pushes the STRAT emissions schedule on-chain: when the minter
///         has accrued at least `minMintable`, it mints to `recipient` and (optionally) splits across gauges.
/// @dev ADDITIVE. Deploy this, then grant it `EMISSIONS_ADMIN` on the live EmissionsMinter so it may call
///      `emitTo` (which is role-gated). Register it as a Chainlink custom-logic upkeep; the registry calls
///      `checkUpkeep` (view) each block and `performUpkeep` when it returns true. Funds are LINK on the
///      upkeep. Nothing here can mint more than the minter's own schedule allows — it only relays the call.
///
///      `performUpkeep` re-checks the threshold on-chain (never trust `checkData`) and is a safe no-op when
///      nothing is due, so an unauthorized caller can at worst trigger the exact action the keeper would
///      (mint the scheduled amount to the fixed recipient). Optionally set `forwarder` to the Chainlink
///      Automation forwarder after registration to restrict `performUpkeep` to it.
contract EmissionsAutomation is AutomationCompatibleInterface, AccessControl {
    /// @notice Role allowed to tune the adapter (recipient, threshold, forwarder).
    bytes32 public constant KEEPER_ADMIN = keccak256("KEEPER_ADMIN");

    /// @notice The live EmissionsMinter.
    IEmissionsMinterLike public immutable minter;
    /// @notice Who receives the minted STRAT (the GaugeDistributor for per-gauge splitting).
    address public recipient;
    /// @notice Optional GaugeDistributor; if set, `distribute()` is called after minting.
    IGaugeDistributorLike public distributor;
    /// @notice Skip a mint below this many wei of accrued emissions (dust guard).
    uint256 public minMintable;
    /// @notice Optional Chainlink Automation forwarder; if set, only it may call `performUpkeep`.
    address public forwarder;

    event RecipientSet(address recipient);
    event DistributorSet(address distributor);
    event MinMintableSet(uint256 minMintable);
    event ForwarderSet(address forwarder);
    event Performed(uint256 minted, bool distributed);

    error ZeroAddress();
    error NotForwarder();

    constructor(address admin, IEmissionsMinterLike minter_, address recipient_, IGaugeDistributorLike distributor_, uint256 minMintable_) {
        if (admin == address(0) || address(minter_) == address(0) || recipient_ == address(0)) revert ZeroAddress();
        minter = minter_;
        recipient = recipient_;
        distributor = distributor_;
        minMintable = minMintable_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ADMIN, admin);
    }

    function setRecipient(address recipient_) external onlyRole(KEEPER_ADMIN) {
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    function setDistributor(IGaugeDistributorLike distributor_) external onlyRole(KEEPER_ADMIN) {
        distributor = distributor_;
        emit DistributorSet(address(distributor_));
    }

    function setMinMintable(uint256 minMintable_) external onlyRole(KEEPER_ADMIN) {
        minMintable = minMintable_;
        emit MinMintableSet(minMintable_);
    }

    function setForwarder(address forwarder_) external onlyRole(KEEPER_ADMIN) {
        forwarder = forwarder_;
        emit ForwarderSet(forwarder_);
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev Off-chain view. Upkeep needed once accrued emissions reach the threshold.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 m = minter.mintable();
        upkeepNeeded = m > 0 && m >= minMintable;
        performData = "";
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev On-chain. Re-checks the threshold (never trusts performData); safe no-op if nothing is due.
    function performUpkeep(bytes calldata) external {
        if (forwarder != address(0) && msg.sender != forwarder) revert NotForwarder();
        uint256 m = minter.mintable();
        if (m == 0 || m < minMintable) return; // conditions changed since checkUpkeep; no-op
        uint256 minted = minter.emitTo(recipient);
        bool distributed;
        IGaugeDistributorLike d = distributor;
        if (address(d) != address(0) && d.undistributed() > 0) {
            d.distribute();
            distributed = true;
        }
        emit Performed(minted, distributed);
    }
}
