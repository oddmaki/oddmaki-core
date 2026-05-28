// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibFillStorage} from "../storage/LibFillStorage.sol";
import {LibMatchingPreviewService} from "../services/LibMatchingPreviewService.sol";
import {LibMarkPriceService} from "../services/LibMarkPriceService.sol";
import {Side, TickLevel, Fill, MatchPreview} from "../interfaces/Types.sol";

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

    /// @notice Get the mark price for an outcome. Uses an *implied* midpoint that
    ///         accounts for cross-outcome liquidity (mint/merge complement) when the
    ///         implied spread is within the per-tick-size threshold (default ~$0.10).
    ///         Falls back to the last trade tick (queried outcome, or complement of
    ///         the other outcome's last trade), then returns undefined.
    /// @dev    Delegates to {LibMarkPriceService} so the matching engine, market-take
    ///         service, and external readers all share one canonical implementation.
    /// @param marketId  the market to query.
    /// @param outcomeId the outcome (0 = YES, 1 = NO).
    /// @return priceTick the mark price tick.
    /// @return isDefined true if a mark price could be determined.
    function getMarkPrice(uint256 marketId, uint256 outcomeId)
        external
        view
        returns (uint256 priceTick, bool isDefined)
    {
        return LibMarkPriceService.getMarkPriceTick(marketId, outcomeId);
    }

    /// @notice Implied top-of-book for an outcome, accounting for cross-outcome
    ///         liquidity via the mint/merge complement.
    /// @dev Useful for SDK previews ("what's the cheapest price I could BUY at?")
    ///      without recomputing the cross-outcome math client-side.
    /// @return impliedBid Highest tick at which the outcome can be bought (0 if none).
    /// @return impliedAsk Lowest tick at which the outcome can be sold (0 if none).
    function getImpliedTopOfBook(uint256 marketId, uint256 outcomeId)
        external
        view
        returns (uint256 impliedBid, uint256 impliedAsk)
    {
        return LibMarkPriceService.getImpliedTopOfBook(marketId, outcomeId);
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
