// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Hook a controller can implement to be notified on token movements (for yield settlement).
interface ITransferHook {
    function onTokenTransfer(address token, address from, address to) external;
}

/// @title ControlledToken
/// @notice Minimal ERC20 whose mint/burn are restricted to a controller; optionally notifies the
///         controller on every transfer so it can settle per-holder accounting (e.g. YT yield).
/// @dev Used for PT/YT (YieldSplitter) and Senior/Junior (TrancheVault) tokens.
contract ControlledToken is ERC20 {
    /// @notice The controller (the structured-product contract) allowed to mint/burn.
    address public immutable controller;
    /// @notice Whether to call `controller.onTokenTransfer` on each balance change.
    bool public immutable notifyTransfers;

    error OnlyController();

    constructor(string memory name_, string memory symbol_, address controller_, bool notifyTransfers_)
        ERC20(name_, symbol_)
    {
        controller = controller_;
        notifyTransfers = notifyTransfers_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    /// @notice Mint `amount` to `to`.
    /// @dev SECURITY: controller-only.
    function mint(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from`.
    /// @dev SECURITY: controller-only.
    function burn(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }

    /// @dev Notify the controller so it can settle yield before balances change.
    function _update(address from, address to, uint256 value) internal override {
        if (notifyTransfers && msg.sender != controller) {
            // settle holders on user-initiated transfers; mints/burns are settled by the controller itself
            ITransferHook(controller).onTokenTransfer(address(this), from, to);
        }
        super._update(from, to, value);
    }
}
