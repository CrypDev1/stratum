// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPortfolio
/// @notice Common surface for Index and Vault portfolios: a fully-backed basket minting BEP-20 shares.
interface IPortfolio {
    /// @notice A basket component and its target weight.
    struct Component {
        address asset;
        uint256 weightBps; // target weight; components sum to 10_000
    }

    /// @notice The ERC20 share token representing portfolio ownership.
    function shareToken() external view returns (address);

    /// @notice The quote/deposit asset (e.g. USDC) used to mint.
    function quoteAsset() external view returns (address);

    /// @notice Total USD value (18-dec) of all underlying holdings.
    function totalNAV() external view returns (uint256);

    /// @notice USD value (18-dec) of one share. Equals 1e18 when supply is zero.
    function navPerShare() external view returns (uint256);

    /// @notice Deposit `quoteAmountIn` of the quote asset, allocate into components, receive shares.
    /// @param quoteAmountIn Quote asset amount to deposit.
    /// @param minSharesOut Minimum shares to mint (slippage bound).
    /// @param deadline Unix timestamp after which the call reverts.
    /// @return shares Shares minted to the caller.
    function mint(uint256 quoteAmountIn, uint256 minSharesOut, uint256 deadline) external returns (uint256 shares);

    /// @notice Burn `shares` and receive pro-rata underlying components in kind.
    /// @param shares Shares to burn.
    /// @return assets The component assets returned.
    /// @return amounts The amount of each component returned.
    function redeem(uint256 shares) external returns (address[] memory assets, uint256[] memory amounts);
}
