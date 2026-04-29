// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibResolutionStorage} from "../storage/LibResolutionStorage.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {MarketOracleData, MarketRegistryData, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title LibResolutionValidator
 * @notice Resolution validation logic and errors. Read-only — no mutations.
 *         Used by ResolutionFacet and LibResolutionAggregate to enforce resolution invariants.
 */
library LibResolutionValidator {
    // ---- Errors: oracle state ----
    error OracleNotInitialized();
    error AssertionActiveOrResolved();
    error AssertionNotFound();
    error AssertionNotSettled();

    // ---- Errors: market state ----
    error MarketNotActive();
    error MarketNotFound();

    // ---- Errors: input validation ----
    error OutcomeMismatch();

    // ---- Errors: access control ----
    error OnlyUmaOracle();

    // ---- Errors: configuration ----
    error UmaOracleNotSet();
    error UmaIdentifierNotSet();

    // ---- Precondition checks ----

    function requireOracleInitialized(bytes32 questionId) internal view {
        if (!LibMarketOracleStorage.marketOracleDataExists(questionId)) revert OracleNotInitialized();
    }

    function requireNoActiveAssertion(bytes32 questionId) internal view {
        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(questionId);
        if (oracle.activeAssertionId != bytes32(0)) revert AssertionActiveOrResolved();
    }

    function requireAssertionExists(bytes32 assertionId) internal view {
        if (!LibResolutionStorage.assertionExists(assertionId)) revert AssertionNotFound();
    }

    function requireAssertionSettled(bytes32 assertionId) internal view {
        if (!LibResolutionStorage.getAssertionData(assertionId).settled) revert AssertionNotSettled();
    }

    function requireActiveMarket(uint256 marketId) internal view {
        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (reg.marketId == 0) revert MarketNotFound();
        if (reg.status != MarketStatus.Active) revert MarketNotActive();
    }

    /// @notice Require the market linked to `questionId` to be in Active status.
    ///         Used by the UMA resolution entry points to block re-resolution once
    ///         another resolution path (e.g. Pyth) has already finalised the market.
    function requireActiveMarketByQuestionId(bytes32 questionId) internal view {
        uint256 marketId = LibMarketRegistryStorage.getMarketIdByQuestionId(questionId);
        if (marketId == 0) revert MarketNotFound();
        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (reg.status != MarketStatus.Active) revert MarketNotActive();
    }

    function requireUmaOracle(address caller) internal view {
        if (caller != LibProtocolStorage.getUmaOracle()) revert OnlyUmaOracle();
    }

    function requireUmaOracleConfigured() internal view {
        if (LibProtocolStorage.getUmaOracle() == address(0)) revert UmaOracleNotSet();
        if (LibProtocolStorage.getUmaIdentifier() == bytes32(0)) revert UmaIdentifierNotSet();
    }

    function requireOutcomeMatch(string memory expected, string calldata provided) internal pure {
        if (keccak256(bytes(expected)) != keccak256(bytes(provided))) revert OutcomeMismatch();
    }
}
