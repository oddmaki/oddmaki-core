// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibProtocolAggregate} from "../aggregates/LibProtocolAggregate.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";

/**
 * @title ProtocolFacet
 * @author OddMaki Protocol
 * @notice Owner-only protocol-wide configuration: treasury, fee bps, UMA oracle,
 *         UMA identifier, and collateral whitelist.
 */
contract ProtocolFacet {
    event ProtocolTreasuryUpdated(address indexed treasury);
    event ProtocolFeeBpsUpdated(uint256 bps);
    event UmaOracleUpdated(address indexed oracle);
    event UmaIdentifierUpdated(bytes32 identifier);
    event CollateralWhitelistUpdated(address indexed token, bool whitelisted);

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
}
