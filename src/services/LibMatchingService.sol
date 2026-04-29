// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibNormalFillService} from "./LibNormalFillService.sol";
import {LibMintFillService} from "./LibMintFillService.sol";
import {LibMergeFillService} from "./LibMergeFillService.sol";
import {MarketTradingData} from "../interfaces/Types.sol";

/**
 * @title LibMatchingService
 * @notice Orchestrates the three matching strategies in priority order for each step:
 *         1. Normal fill (for each outcome)
 *         2. Mint-to-fill (YES+NO buy cross)
 *         3. Merge-to-fill (YES+NO sell cross)
 *         Delegates all fill logic to the dedicated strategy services.
 */
library LibMatchingService {
    /**
     * @notice Run up to `maxSteps` matching iterations for `marketId`.
     *         Each step attempts fills in priority order and stops when no progress is made.
     * @return fillCount Number of fills executed.
     */
    function matchOrders(uint256 marketId, uint256 maxSteps)
        internal
        returns (uint256 fillCount)
    {
        MarketTradingData storage md = LibMarketTradingStorage.getMarketTradingData(marketId);

        // Resolve conditionId once (marketId → questionId → conditionId)
        bytes32 questionId = LibMarketRegistryStorage.getStorage().byMarketId[marketId].questionId;
        bytes32 conditionId = LibMarketOracleStorage.getStorage().byQuestionId[questionId].conditionId;

        uint256 stepsRemaining = maxSteps;

        while (stepsRemaining > 0) {
            bool stepMade = false;

            // Priority 1: normal fill (YES outcome first, then NO)
            if (LibNormalFillService.tryFill(marketId, 0, md)) {
                fillCount++;
                stepMade = true;
            } else if (LibNormalFillService.tryFill(marketId, 1, md)) {
                fillCount++;
                stepMade = true;
            }

            // Priority 2: mint-to-fill
            if (!stepMade && LibMintFillService.tryFill(marketId, conditionId, md)) {
                fillCount++;
                stepMade = true;
            }

            // Priority 3: merge-to-fill
            if (!stepMade && LibMergeFillService.tryFill(marketId, conditionId, md)) {
                fillCount++;
                stepMade = true;
            }

            if (!stepMade) break;
            stepsRemaining--;
        }
    }
}
