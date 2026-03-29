// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Side, MatchPreview, MarketFees, Order} from "../interfaces/Types.sol";
import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";

/**
 * @title LibMatchingPreviewService
 * @notice Read-only preview of whether matchable orders exist for a market.
 *         Checks all three fill paths (normal, mint-to-fill, merge-to-fill)
 *         using the top-of-book cache and fee config.
 */
library LibMatchingPreviewService {
    function previewMatch(uint256 marketId) internal view returns (MatchPreview memory p) {
        // Read top-of-book for all 4 slots
        p.yesBestBid = LibOrderBookStorage.getTopOfBook(marketId, 0, Side.BUY);
        p.yesBestAsk = LibOrderBookStorage.getTopOfBook(marketId, 0, Side.SELL);
        p.noBestBid  = LibOrderBookStorage.getTopOfBook(marketId, 1, Side.BUY);
        p.noBestAsk  = LibOrderBookStorage.getTopOfBook(marketId, 1, Side.SELL);

        // Check normal fill crossing for each outcome
        p.normalYesCross = p.yesBestBid > 0 && p.yesBestAsk > 0 && p.yesBestBid >= p.yesBestAsk;
        p.normalNoCross  = p.noBestBid  > 0 && p.noBestAsk  > 0 && p.noBestBid  >= p.noBestAsk;

        // Check mint/merge feasibility (requires fee config + tickSize)
        uint256 tickSize = LibMarketTradingStorage.getMarketTradingData(marketId).tickSize;
        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);

        if (p.yesBestBid > 0 && p.noBestBid > 0) {
            p.mintFeasible = LibFeeCalculatorService.checkMintFeasibility(
                p.yesBestBid, p.noBestBid, tickSize, fees
            );
        }

        if (p.yesBestAsk > 0 && p.noBestAsk > 0) {
            p.mergeFeasible = LibFeeCalculatorService.checkMergeFeasibility(
                p.yesBestAsk, p.noBestAsk, tickSize, fees
            );
        }

        // Check head order expiry for each relevant top-of-book tick
        if (p.yesBestBid > 0) {
            p.yesBidHeadExpired = _isHeadExpired(marketId, 0, Side.BUY, p.yesBestBid);
        }
        if (p.yesBestAsk > 0) {
            p.yesAskHeadExpired = _isHeadExpired(marketId, 0, Side.SELL, p.yesBestAsk);
        }
        if (p.noBestBid > 0) {
            p.noBidHeadExpired = _isHeadExpired(marketId, 1, Side.BUY, p.noBestBid);
        }
        if (p.noBestAsk > 0) {
            p.noAskHeadExpired = _isHeadExpired(marketId, 1, Side.SELL, p.noBestAsk);
        }

        // anyMatchable: OR of all crossing conditions
        // We include crossings even when head is expired (false negatives are worse than false positives)
        p.anyMatchable = p.normalYesCross || p.normalNoCross || p.mintFeasible || p.mergeFeasible;
    }

    function _isHeadExpired(uint256 marketId, uint256 outcomeId, Side side, uint256 tick)
        private
        view
        returns (bool)
    {
        uint256 headId = LibOrderBookStorage.getTickLevel(marketId, outcomeId, side, tick).headOrderId;
        if (headId == 0) return false;
        Order storage order = LibOrderStorage.getOrder(headId);
        return order.expiry != 0 && order.expiry <= block.timestamp;
    }
}
