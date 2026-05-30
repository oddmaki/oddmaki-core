// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";
import {LibDpmAggregate} from "../aggregates/LibDpmAggregate.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketOracleAggregate} from "../aggregates/LibMarketOracleAggregate.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {MarketOracleData} from "../interfaces/Types.sol";

/**
 * @title LibDpmOutcomeService
 * @notice Adds a late outcome to a live DPM market (e.g. a candidate who enters the race after the
 *         market opened). DPM is uniquely suited to this: it holds no CTF outcome tokens, so there
 *         is nothing to split / migrate — adding an outcome is pure bookkeeping plus a fresh CTF
 *         condition.
 *
 *         The CTF `conditionId = keccak(oracle, questionId, slotCount)`, so the slot count is baked
 *         into the id; growing the outcome set means preparing an (N+1)-slot condition and re-pointing
 *         the oracle at it. The `questionId` is stable, so UMA assertions are unaffected. The new
 *         outcome starts at M = N = 0 (par-until-contested for its first backer); intent placed on it
 *         before openTime seeds normally. Only permitted while trading is live (before closeTime).
 */
library LibDpmOutcomeService {
    /// @notice Emitted when a late outcome is added. Carries the new conditionId because it CHANGES
    ///         (the slot count grew) — the indexer must re-point the market at it.
    event DpmOutcomeAdded(
        uint256 indexed marketId, uint256 outcomeIndex, string label, bytes32 newConditionId, uint256 newOutcomeCount
    );

    /// @notice Append `label` as a new outcome on `marketId`. Caller authorization is enforced by the facet.
    function addOutcome(uint256 marketId, string calldata label) internal returns (uint256 newIndex) {
        LibDpmValidator.requireIsDpmMarket(marketId);
        LibDpmValidator.requireBeforeClose(marketId);
        if (bytes(label).length == 0) revert LibDpmValidator.EmptyOutcomeLabel();

        uint256 oldCount = LibDpmStorage.getDpmMarket(marketId).outcomeCount;
        uint256 newCount = oldCount + 1;
        LibDpmValidator.requireValidOutcomeCount(newCount); // enforces the MAX_OUTCOMES ceiling

        bytes32 questionId = LibMarketRegistryStorage.getMarketRegistryData(marketId).questionId;
        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(questionId);

        // Reject a duplicate label — two identical strings would alias on the resolution string match.
        bytes32 labelHash = keccak256(bytes(label));
        for (uint256 i = 0; i < oldCount; i++) {
            if (keccak256(bytes(oracle.outcomes[i])) == labelHash) revert LibDpmValidator.DuplicateOutcome();
        }

        // Prepare the larger CTF condition and re-point the oracle at it. address(this) is the Diamond
        // (delegatecall), which is the registered oracle.
        IConditionalTokens ctf = IConditionalTokens(LibVaultStorage.getCtf());
        ctf.prepareCondition(address(this), questionId, newCount);
        bytes32 newConditionId = ctf.getConditionId(address(this), questionId, newCount);

        LibMarketOracleAggregate.appendOutcome(questionId, newConditionId, newCount, label);
        LibDpmAggregate.setOutcomeCount(marketId, newCount);

        newIndex = oldCount; // the appended outcome's index
        emit DpmOutcomeAdded(marketId, newIndex, label, newConditionId, newCount);
    }
}
