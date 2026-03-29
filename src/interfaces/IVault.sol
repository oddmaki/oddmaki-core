// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVault
/// @notice Custody interface used by the Diamond for collateral and outcome tokens
interface IVault {
    /// @notice Pull collateral tokens from a depositor into the vault.
    /// @param token the ERC-20 collateral token address.
    /// @param from the depositor address.
    /// @param amount the amount to deposit.
    function depositCollateral(address token, address from, uint256 amount) external;

    /// @notice Send collateral tokens from the vault to a recipient.
    /// @param token the ERC-20 collateral token address.
    /// @param to the recipient address.
    /// @param amount the amount to withdraw.
    function withdrawCollateral(address token, address to, uint256 amount) external;

    /// @notice Pull outcome tokens (ERC-1155) from a depositor into the vault.
    /// @param positionId the CTF position ID (ERC-1155 token ID).
    /// @param from the depositor address.
    /// @param amount the amount to deposit.
    function depositOutcomeTokens(uint256 positionId, address from, uint256 amount) external;

    /// @notice Send outcome tokens from the vault to a recipient.
    /// @param positionId the CTF position ID (ERC-1155 token ID).
    /// @param to the recipient address.
    /// @param amount the amount to withdraw.
    function withdrawOutcomeTokens(uint256 positionId, address to, uint256 amount) external;
}
