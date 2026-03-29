// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";

/**
 * @title LibMarketContextService
 * @notice Cross-layer market context reads. Composes data from Registry, Oracle, and Trading
 *         storage into the fields that execution-layer services need in a single call.
 *         Reusable by any facet or service that needs to resolve market parameters.
 */
library LibMarketContextService {
    error MarketNotFound();
    error MarketNotActive();

    /**
     * @notice Returns the execution context for a market: collateral token, CTF conditionId,
     *         and YES / NO position IDs. Reverts if the market does not exist or is not active.
     */
    function getMarketTradingContext(uint256 marketId)
        internal
        view
        returns (address collateralToken, bytes32 conditionId, uint256[2] memory positionIds)
    {
        LibMarketTradingStorage.Storage storage ts = LibMarketTradingStorage.getStorage();
        if (ts.byMarketId[marketId].marketId == 0) revert MarketNotFound();
        if (!ts.byMarketId[marketId].active) revert MarketNotActive();

        collateralToken = address(ts.byMarketId[marketId].collateralToken);
        positionIds = ts.byMarketId[marketId].positionIds;

        bytes32 questionId = LibMarketRegistryStorage.getStorage().byMarketId[marketId].questionId;
        conditionId = LibMarketOracleStorage.getStorage().byQuestionId[questionId].conditionId;
    }
}
