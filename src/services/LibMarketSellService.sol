// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookAggregate} from "../aggregates/LibOrderBookAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";
import {LibFillAggregate} from "../aggregates/LibFillAggregate.sol";
import {LibMarketOrderValidator} from "../validators/LibMarketOrderValidator.sol";
import {Order, Side, MarketTradingData, MarketFees, FeeBreakdown, SettlementPath, MarketOrderType, MarketSellResult} from "../interfaces/Types.sol";

/**
 * @title LibMarketSellService
 * @notice Market sell execution: walks the orderbook buy side consuming bid liquidity.
 *         Only uses Normal Fill (no mint/merge). Supports FOK and FAK semantics.
 */
library LibMarketSellService {
    event MarketSellExecuted(
        address indexed seller,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 tokensSold,
        uint256 collateralReceived,
        uint256 avgPrice,
        uint256 unsoldTokens
    );

    /**
     * @notice Execute a market sell order: deposit outcome tokens, walk the buy side, fill at best bid prices.
     * @param marketId      Market to sell in.
     * @param outcomeId     Outcome to sell (0=YES, 1=NO).
     * @param tokenAmount   Total outcome tokens to sell.
     * @param minPriceTick  Minimum price tick willing to accept.
     * @param orderType     FOK (revert if not fully sold) or FAK (return unsold tokens).
     * @return result       Execution summary.
     */
    function placeMarketSell(
        uint256 marketId,
        uint256 outcomeId,
        uint256 tokenAmount,
        uint256 minPriceTick,
        MarketOrderType orderType
    ) internal returns (MarketSellResult memory result) {
        LibMarketOrderValidator.validateMarketSellParams(tokenAmount, minPriceTick, outcomeId);

        MarketTradingData storage md = LibMarketTradingStorage.getMarketTradingData(marketId);

        // Deposit all outcome tokens upfront
        LibVaultOutcomeTokenService.depositOutcomeTokens(md.positionIds[outcomeId], msg.sender, tokenAmount);

        uint256 remainingTokens = tokenAmount;
        uint256 totalProceeds = 0;
        uint256 totalNetCollateral = 0;

        for (uint256 i = 0; i < LibMarketOrderValidator.MAX_ITERATIONS && remainingTokens > 0; i++) {
            // Get best bid price
            uint256 bestBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
            if (bestBid == 0 || bestBid < minPriceTick) break;

            // Get FIFO head at this tick
            uint256 headOrderId = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.BUY, bestBid).headOrderId;
            if (headOrderId == 0) break;

            // Clean up expired head orders (retry up to MAX_EXPIRY_RETRIES)
            bool expired = true;
            for (uint256 r = 0; r < LibMarketOrderValidator.MAX_EXPIRY_RETRIES && expired; r++) {
                expired = LibOrderExpiryService.expireOrderInline(headOrderId, md);
                if (expired) {
                    // Refresh after expiry cleanup
                    bestBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
                    if (bestBid == 0 || bestBid < minPriceTick) break;
                    headOrderId = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.BUY, bestBid).headOrderId;
                    if (headOrderId == 0) break;
                }
            }
            // If still expired after retries, or book drained, stop
            if (bestBid == 0 || bestBid < minPriceTick || headOrderId == 0) break;

            Order storage buyOrder = LibOrderStorage.getOrder(headOrderId);
            if (buyOrder.id == 0) break;

            // Calculate fill quantity (exact — no division, no rounding dust)
            uint256 fillQty = remainingTokens < buyOrder.qty ? remainingTokens : buyOrder.qty;
            if (fillQty == 0) break;

            // Calculate proceeds (collateral from buyer's locked funds)
            uint256 pricePerToken = bestBid * md.tickSize;
            uint256 proceeds = (fillQty * pricePerToken) / 1e18;
            if (proceeds == 0) break;

            // Fee calculation
            MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
            FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(proceeds, fees);

            // Settlement: seller gets proceeds minus fees, buyer gets outcome tokens
            uint256 sellerPayout = proceeds - breakdown.totalFee - breakdown.remainder;
            LibVaultCollateralService.transferCollateral(address(md.collateralToken), msg.sender, sellerPayout);
            LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[outcomeId], buyOrder.owner, fillQty);

            // Record fill (order1Id = resting buy order, order2Id = 0 indicates market sell taker)
            uint256 fillId = LibFillAggregate.recordFill(
                marketId, SettlementPath.NORMAL, headOrderId, 0, fillQty, bestBid
            );

            // Distribute fees
            LibFeeDistributionService.distributeFees(
                address(md.collateralToken), breakdown, fees, marketId, fillId
            );

            // Update buy order; always decrement totalQty first, then dequeue/delete fully-filled orders
            LibOrderBookAggregate.recordFillOnBook(marketId, outcomeId, Side.BUY, bestBid, fillQty);
            uint256 newQty = LibOrderAggregate.reduceOrderQty(headOrderId, fillQty);
            if (newQty == 0) {
                LibOrderBookService.dequeueOrder(headOrderId);
                LibOrderAggregate.deleteOrder(headOrderId);
            }

            // Track volume and last trade
            LibMarketTradingAggregate.recordTotalVolume(marketId, outcomeId, proceeds);
            LibMarketTradingAggregate.recordLastTradeTick(marketId, outcomeId, bestBid);

            remainingTokens -= fillQty;
            totalProceeds += proceeds;
            totalNetCollateral += sellerPayout;
        }

        // Revert if nothing was filled (empty book or all orders expired/out of range)
        if (totalProceeds == 0) {
            revert LibMarketOrderValidator.NoLiquidityAvailable();
        }

        // Handle remaining tokens
        if (remainingTokens > 0) {
            if (orderType == MarketOrderType.FOK) {
                revert LibMarketOrderValidator.InsufficientLiquidityForFOK();
            }
            // Return unsold tokens (FAK remainder)
            LibVaultOutcomeTokenService.withdrawOutcomeTokens(md.positionIds[outcomeId], msg.sender, remainingTokens);
        }

        uint256 tokensSold = tokenAmount - remainingTokens;
        uint256 avgPrice = tokensSold > 0 ? (totalProceeds * 1e18) / tokensSold : 0;

        emit MarketSellExecuted(
            msg.sender, marketId, outcomeId, tokensSold, totalNetCollateral, avgPrice, remainingTokens
        );

        result = MarketSellResult({
            tokensSold: tokensSold,
            avgPrice: avgPrice,
            collateralReceived: totalNetCollateral,
            unsoldTokens: remainingTokens
        });
    }
}
