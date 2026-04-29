// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {LibProtocolAggregate} from "../aggregates/LibProtocolAggregate.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";

/**
 * @title ProtocolFacet
 * @author OddMaki Protocol
 * @notice Owner-only protocol-wide configuration: treasury, oracle settings,
 *         collateral whitelist, protocol pause, and venue suspension.
 */
contract ProtocolFacet {
    event ProtocolTreasuryUpdated(address indexed treasury);
    event ProtocolFeeBpsUpdated(uint256 bps);
    event UmaOracleUpdated(address indexed oracle);
    event UmaIdentifierUpdated(bytes32 identifier);
    event EthWithdrawn(address indexed recipient, uint256 amount);
    event ERC20Withdrawn(address indexed token, address indexed recipient, uint256 amount);
    event CollateralWhitelistUpdated(address indexed token, bool whitelisted);
    event ProtocolPausedEvent(address indexed caller);
    event ProtocolUnpausedEvent(address indexed caller);
    event VenueSuspendedEvent(uint256 indexed venueId, address indexed caller);
    event VenueUnsuspendedEvent(uint256 indexed venueId, address indexed caller);

    /// @notice Set the protocol treasury address for fee collection. Owner-only.
    /// @param treasury the new treasury address.
    /// @dev Setting to address(0) disables all protocol fees.
    function setProtocolTreasury(address treasury) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setProtocolTreasury(treasury);
        emit ProtocolTreasuryUpdated(treasury);
    }

    /// @notice Get the current protocol treasury address.
    function getProtocolTreasury() external view returns (address) {
        return LibProtocolStorage.getProtocolTreasury();
    }

    /// @notice Set the protocol fee in basis points. Owner-only. Max 200 bps (2%).
    /// @param bps the new protocol fee in basis points.
    function setProtocolFeeBps(uint256 bps) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setProtocolFeeBps(bps);
        emit ProtocolFeeBpsUpdated(bps);
    }

    /// @notice Get the current protocol fee in basis points.
    function getProtocolFeeBps() external view returns (uint256) {
        return LibProtocolStorage.getProtocolFeeBps();
    }

    /// @notice Set the UMA Optimistic Oracle V3 contract address. Owner-only.
    /// @param oracle the UMA oracle address.
    function setUmaOracle(address oracle) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setUmaOracle(oracle);
        emit UmaOracleUpdated(oracle);
    }

    /// @notice Get the current UMA Oracle address.
    function getUmaOracle() external view returns (address) {
        return LibProtocolStorage.getUmaOracle();
    }

    /// @notice Set the UMA price identifier used for assertions. Owner-only.
    /// @param identifier the UMA price identifier.
    function setUmaIdentifier(bytes32 identifier) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setUmaIdentifier(identifier);
        emit UmaIdentifierUpdated(identifier);
    }

    /// @notice Get the current UMA price identifier.
    function getUmaIdentifier() external view returns (bytes32) {
        return LibProtocolStorage.getUmaIdentifier();
    }

    /// @notice Add or remove a token from the collateral whitelist. Owner-only.
    /// @param token the ERC-20 token address.
    /// @param whitelisted true to whitelist, false to remove.
    function setCollateralWhitelisted(address token, bool whitelisted) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setCollateralWhitelisted(token, whitelisted);
        emit CollateralWhitelistUpdated(token, whitelisted);
    }

    /// @notice Check if a token is whitelisted as collateral.
    /// @param token the ERC-20 token address to check.
    function isCollateralWhitelisted(address token) external view returns (bool) {
        return LibProtocolStorage.isCollateralWhitelisted(token);
    }

    // ---- Moderation ----

    /// @notice Pause the entire protocol. Blocks all trading and market creation globally. Owner-only.
    function pauseProtocol() external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setProtocolPaused(true);
        emit ProtocolPausedEvent(msg.sender);
    }

    /// @notice Unpause the protocol. Owner-only.
    function unpauseProtocol() external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolAggregate.setProtocolPaused(false);
        emit ProtocolUnpausedEvent(msg.sender);
    }

    /// @notice Check if the protocol is currently paused.
    function getProtocolPaused() external view returns (bool) {
        return LibProtocolStorage.isProtocolPaused();
    }

    /// @notice Suspend a venue at the protocol level. Owner-only.
    /// @param venueId the venue to suspend.
    /// @dev Unlike venue-level pause, only the protocol owner can lift a suspension.
    function suspendVenue(uint256 venueId) external {
        LibDiamond.enforceIsContractOwner();
        if (!LibVenueStorage.venueExists(venueId)) revert LibVenueValidator.VenueNotFound();
        LibProtocolAggregate.setVenueSuspended(venueId, true);
        emit VenueSuspendedEvent(venueId, msg.sender);
    }

    /// @notice Unsuspend a previously suspended venue. Owner-only.
    /// @param venueId the venue to unsuspend.
    function unsuspendVenue(uint256 venueId) external {
        LibDiamond.enforceIsContractOwner();
        if (!LibVenueStorage.venueExists(venueId)) revert LibVenueValidator.VenueNotFound();
        LibProtocolAggregate.setVenueSuspended(venueId, false);
        emit VenueUnsuspendedEvent(venueId, msg.sender);
    }

    /// @notice Check if a venue is suspended by the protocol.
    /// @param venueId the venue to check.
    function getVenueSuspended(uint256 venueId) external view returns (bool) {
        return LibProtocolStorage.isVenueSuspended(venueId);
    }

    // ---- Rescue ----

    /// @notice Rescue any ETH accidentally sent to the Diamond. Owner-only.
    /// @param recipient the address to receive the ETH.
    function withdrawETH(address recipient) external {
        LibDiamond.enforceIsContractOwner();
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success,) = recipient.call{value: balance}("");
        require(success, "ETH transfer failed");
        emit EthWithdrawn(recipient, balance);
    }

    /// @notice Rescue ERC-20 tokens from the Diamond. Owner-only.
    /// @param token the ERC-20 token address.
    /// @param recipient the address to receive the tokens.
    /// @param amount the amount to withdraw.
    function withdrawERC20(address token, address recipient, uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        require(token != address(0), "Invalid token");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Zero amount");
        TransferHelper._transferErc20(token, recipient, amount);
        emit ERC20Withdrawn(token, recipient, amount);
    }
}
