// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {MarketTradingData, Side} from "../interfaces/Types.sol";

/**
 * @title LibMarkPriceService
 * @notice On-chain mark-price waterfall used by external read views (e.g.
 *         `OrderBookFacet.getMarkPrice`) and by the upcoming market-take
 *         service for resolving the slippage anchor at facet entry.
 *
 *         Waterfall (binary markets only — the protocol's only supported shape):
 *           1. Implied YES midpoint via top-of-book on BOTH outcomes:
 *                impliedBid = max(directYesBid, fullTicks - otherAsk)   // via merge complement
 *                impliedAsk = min(directYesAsk, fullTicks - otherBid)   // via mint complement
 *              If both sides exist, the implied book is not crossed, and the
 *              implied spread ≤ MAX_SPREAD_TICKS (scaled by tickSize), return the midpoint.
 *           2. Otherwise fall back to `lastTradeTick` on the queried outcome,
 *              or the complement of the other outcome's last trade.
 *           3. Otherwise return (0, false) — caller must handle "undefined."
 *
 *         The spread threshold defaults to $0.10 at the standard 1e16 tick size
 *         and auto-scales with tick size so finer venues (1e15) get a 100-tick
 *         window for the same $0.10 absolute spread.
 */
library LibMarkPriceService {
    /// @dev $0.10 spread at the standard 1e16 tick size. Scales linearly with
    ///      tick size via {getMaxSpreadTicks}.
    uint256 internal constant BASE_MAX_SPREAD_TICKS = 10;
    uint256 internal constant STANDARD_TICK_SIZE = 1e16;

    /// @dev Returns the absolute spread threshold in *tick* units for the
    ///      given tick size. e.g. tickSize=1e16 → 10 ticks ($0.10);
    ///      tickSize=1e15 → 100 ticks ($0.10); tickSize=2e16 → 5 ticks ($0.10).
    function getMaxSpreadTicks(uint256 tickSize) internal pure returns (uint256) {
        if (tickSize == 0) return BASE_MAX_SPREAD_TICKS;
        return (BASE_MAX_SPREAD_TICKS * STANDARD_TICK_SIZE) / tickSize;
    }

    /// @dev Implied top-of-book on `outcomeId` accounting for cross-outcome
    ///      complement via the mint and merge paths.
    ///        - impliedBid: highest tick someone could *buy* at = max of the
    ///          direct YES bid and the merge complement of NO's ask.
    ///        - impliedAsk: lowest tick someone could *sell* at = min of the
    ///          direct YES ask and the mint complement of NO's bid.
    ///      Both return 0 when no candidate exists (caller treats as "absent").
    function getImpliedTopOfBook(uint256 marketId, uint256 outcomeId)
        internal
        view
        returns (uint256 impliedBid, uint256 impliedAsk)
    {
        MarketTradingData storage td = LibMarketTradingStorage.getMarketTradingData(marketId);
        uint256 tickSize = td.tickSize;
        if (tickSize == 0) return (0, 0);
        uint256 fullTicks = 1e18 / tickSize;

        uint256 otherIdx = outcomeId == 0 ? 1 : 0;

        uint256 directBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
        uint256 directAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
        uint256 otherBid  = LibOrderBookStorage.getTopOfBook(marketId, otherIdx,  Side.BUY);
        uint256 otherAsk  = LibOrderBookStorage.getTopOfBook(marketId, otherIdx,  Side.SELL);

        // Implied bid: direct bid OR merge-complement of opposite ask, take the higher.
        impliedBid = directBid;
        if (otherAsk > 0 && otherAsk < fullTicks) {
            uint256 mergeComplement = fullTicks - otherAsk;
            if (mergeComplement > impliedBid) impliedBid = mergeComplement;
        }

        // Implied ask: direct ask OR mint-complement of opposite bid, take the lower.
        // Use 0 as "no candidate"; on output 0 means "no implied ask exists."
        impliedAsk = directAsk;
        if (otherBid > 0 && otherBid < fullTicks) {
            uint256 mintComplement = fullTicks - otherBid;
            if (impliedAsk == 0 || mintComplement < impliedAsk) {
                impliedAsk = mintComplement;
            }
        }
    }

    /// @notice Resolve a mark-price tick for `outcomeId` of `marketId`.
    /// @return priceTick The mark price tick (in tick units, multiply by tickSize to get a decimal price).
    /// @return isDefined False when the protocol can't honestly produce a reference price
    ///                   (wide spread + no trades). Callers MUST handle this case and not
    ///                   substitute a default value silently.
    function getMarkPriceTick(uint256 marketId, uint256 outcomeId)
        internal
        view
        returns (uint256 priceTick, bool isDefined)
    {
        MarketTradingData storage td = LibMarketTradingStorage.getMarketTradingData(marketId);
        uint256 tickSize = td.tickSize;
        if (tickSize == 0) return (0, false);
        uint256 fullTicks = 1e18 / tickSize;

        // 1. Implied midpoint via cross-outcome complement, gated by spread threshold.
        (uint256 impliedBid, uint256 impliedAsk) = getImpliedTopOfBook(marketId, outcomeId);
        if (impliedBid > 0 && impliedAsk > 0 && impliedAsk >= impliedBid) {
            uint256 spread = impliedAsk - impliedBid;
            if (spread <= getMaxSpreadTicks(tickSize)) {
                return ((impliedBid + impliedAsk) / 2, true);
            }
        }

        // 2. Last-trade fallback. Prefer the queried outcome's tick; otherwise
        //    use the complement of the other outcome's last trade.
        uint256 otherIdx = outcomeId == 0 ? 1 : 0;
        uint256 lastSelf  = td.lastTradeTick[outcomeId];
        uint256 lastOther = td.lastTradeTick[otherIdx];

        if (lastSelf > 0) return (lastSelf, true);
        if (lastOther > 0 && lastOther < fullTicks) return (fullTicks - lastOther, true);

        // 3. No reliable reference price. Honest "undefined."
        return (0, false);
    }
}
