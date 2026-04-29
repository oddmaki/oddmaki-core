// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibFillStorage} from "../storage/LibFillStorage.sol";
import {LibMatchingPreviewService} from "../services/LibMatchingPreviewService.sol";
import {Side, TickLevel, MarketTradingData, Fill, MatchPreview} from "../interfaces/Types.sol";

/**
 * @title OrderBookFacet
 * @author OddMaki Protocol
 * @notice Read-only views for the order book, mark price, matching preview, and fill records.
 */
contract OrderBookFacet {
    /// @notice Get the best price tick for a side of an outcome's order book.
    /// @param marketId  the market to query.
    /// @param outcomeId the outcome (0 = YES, 1 = NO).
    /// @param side      BUY or SELL.
    function getTopOfBook(uint256 marketId, uint256 outcomeId, Side side) external view returns (uint256) {
        return LibOrderBookStorage.getTopOfBook(marketId, outcomeId, side);
    }

    /// @notice Get the order queue at a specific tick level.
    /// @param marketId  the market to query.
    /// @param outcomeId the outcome (0 = YES, 1 = NO).
    /// @param side      BUY or SELL.
    /// @param tick      the price tick to inspect.
    function getTickLevel(uint256 marketId, uint256 outcomeId, Side side, uint256 tick)
        external
        view
        returns (TickLevel memory)
    {
        return LibOrderBookStorage.getTickLevel(marketId, outcomeId, side, tick);
    }

    /// @notice Get the mark price for an outcome. Uses midpoint if spread <= 10 ticks,
    ///         falls back to the last trade tick, or returns undefined.
    /// @param marketId  the market to query.
    /// @param outcomeId the outcome (0 = YES, 1 = NO).
    /// @return priceTick the mark price tick.
    /// @return isDefined true if a mark price could be determined.
    function getMarkPrice(uint256 marketId, uint256 outcomeId)
        external
        view
        returns (uint256 priceTick, bool isDefined)
    {
        uint256 bestBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
        uint256 bestAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);

        if (bestBid > 0 && bestAsk > 0 && (bestAsk - bestBid) <= 10) {
            return ((bestBid + bestAsk) / 2, true);
        }

        uint256 lastTrade = LibMarketTradingStorage.getMarketTradingData(marketId).lastTradeTick[outcomeId];
        if (lastTrade > 0) {
            return (lastTrade, true);
        }

        return (0, false);
    }

    /// @notice Check whether any orders are matchable in the given market.
    ///         Returns a preview of which fill paths (normal, mint, merge) have crossing conditions,
    ///         plus top-of-book snapshot and head-order expiry flags.
    /// @param marketId the market to check.
    /// @dev Free off-chain via eth_call. Bots should call this before submitting matchOrders transactions.
    function canMatchOrders(uint256 marketId) external view returns (MatchPreview memory) {
        return LibMatchingPreviewService.previewMatch(marketId);
    }

    /// @notice Get a fill execution record by ID.
    /// @param fillId the fill to query.
    function getFill(uint256 fillId) external view returns (Fill memory) {
        return LibFillStorage.getFill(fillId);
    }

    /// @notice Get the next fill ID that will be allocated.
    function getNextFillId() external view returns (uint256) {
        return LibFillStorage.getNextFillId();
    }
}
