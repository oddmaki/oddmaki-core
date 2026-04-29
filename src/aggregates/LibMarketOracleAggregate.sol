// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {MarketOracleData} from "../interfaces/Types.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title LibMarketOracleAggregate
 * @notice Writes for market oracle: create oracle row, update ancillaryData/activeAssertionId.
 */
library LibMarketOracleAggregate {
    error OracleAlreadyExists();
    error OracleNotInitialized();

    function createOracle(
        bytes32 questionId,
        bytes32 conditionId,
        uint256 outcomeSlotCount,
        IERC20 currency,
        uint256 reward,
        uint256 requiredBond,
        uint64 liveness,
        bytes memory ancillaryData,
        string[] memory outcomes
    ) internal returns (MarketOracleData memory data) {
        LibMarketOracleStorage.Storage storage s = LibMarketOracleStorage.getStorage();
        if (s.byQuestionId[questionId].initialized) revert OracleAlreadyExists();

        data = MarketOracleData({
            questionId: questionId,
            conditionId: conditionId,
            outcomeSlotCount: outcomeSlotCount,
            currency: currency,
            reward: reward,
            requiredBond: requiredBond,
            liveness: liveness,
            initialized: true,
            activeAssertionId: bytes32(0),
            ancillaryData: ancillaryData,
            outcomes: outcomes
        });
        s.byQuestionId[questionId] = data;
        return data;
    }

    function setAncillaryData(bytes32 questionId, bytes memory ancillaryData) internal {
        MarketOracleData storage o = LibMarketOracleStorage.getMarketOracleData(questionId);
        if (!o.initialized) revert OracleNotInitialized();
        o.ancillaryData = ancillaryData;
    }

    function setActiveAssertionId(bytes32 questionId, bytes32 assertionId) internal {
        MarketOracleData storage o = LibMarketOracleStorage.getMarketOracleData(questionId);
        if (!o.initialized) revert OracleNotInitialized();
        o.activeAssertionId = assertionId;
    }
}
