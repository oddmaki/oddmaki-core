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
import {Order, Side, MarketTradingData, MarketFees, FeeBreakdown, SettlementPath, MarketOrderType, MarketBuyResult} from "../interfaces/Types.sol";

/**
 * @title LibMarketOrderService
 * @notice Market order execution: walks the orderbook sell side consuming liquidity.
 *         Only uses Normal Fill (no mint/merge). Supports FOK and FAK semantics.
 */
library LibMarketOrderService {
    event MarketOrderExecuted(
        address indexed buyer,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 collateralSpent,
        uint256 tokensReceived,
        uint256 avgPrice,
        uint256 unusedCollateral
    );

    /**
     * @notice Execute a market buy order: deposit collateral, walk the sell side, fill at best prices.
     * @param marketId   Market to buy in.
     * @param outcomeId  Outcome to acquire (0=YES, 1=NO).
     * @param collateralAmount Total collateral to spend.
     * @param maxPriceTick     Maximum price tick willing to pay.
     * @param orderType  FOK (revert if not fully spent) or FAK (return remainder).
     * @return result    Execution summary.
     */
    function placeMarketOrder(
        uint256 marketId,
        uint256 outcomeId,
        uint256 collateralAmount,
        uint256 maxPriceTick,
        MarketOrderType orderType
    ) internal returns (MarketBuyResult memory result) {
        LibMarketOrderValidator.validateMarketOrderParams(collateralAmount, maxPriceTick, outcomeId);

        MarketTradingData storage md = LibMarketTradingStorage.getMarketTradingData(marketId);

        // Deposit all collateral upfront
        LibVaultCollateralService.depositCollateral(address(md.collateralToken), msg.sender, collateralAmount);

        uint256 remaining = collateralAmount;
        uint256 totalTokens = 0;

        for (uint256 i = 0; i < LibMarketOrderValidator.MAX_ITERATIONS && remaining > 0; i++) {
            // Get best ask price
            uint256 bestAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
            if (bestAsk == 0 || bestAsk > maxPriceTick) break;

            // Get FIFO head at this tick
            uint256 headOrderId = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.SELL, bestAsk).headOrderId;
            if (headOrderId == 0) break;

            // Clean up expired head orders (retry up to MAX_EXPIRY_RETRIES)
            bool expired = true;
            for (uint256 r = 0; r < LibMarketOrderValidator.MAX_EXPIRY_RETRIES && expired; r++) {
                expired = LibOrderExpiryService.expireOrderInline(headOrderId, md);
                if (expired) {
                    // Refresh after expiry cleanup
                    bestAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
                    if (bestAsk == 0 || bestAsk > maxPriceTick) break;
                    headOrderId = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.SELL, bestAsk).headOrderId;
                    if (headOrderId == 0) break;
                }
            }
            // If still expired after retries, or book drained, stop
            if (bestAsk == 0 || bestAsk > maxPriceTick || headOrderId == 0) break;

            Order storage sellOrder = LibOrderStorage.getOrder(headOrderId);
            if (sellOrder.id == 0) break;

            // Calculate fill quantity
            uint256 pricePerToken = bestAsk * md.tickSize;
            uint256 affordableQty = (remaining * 1e18) / pricePerToken;
            uint256 fillQty = affordableQty < sellOrder.qty ? affordableQty : sellOrder.qty;
            if (fillQty == 0) break;

            // Calculate cost
            uint256 cost = (fillQty * pricePerToken) / 1e18;
            if (cost == 0) break;

            // Fee calculation
            MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
            FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(cost, fees);

            // Settlement: seller (maker) gets full cost, buyer (taker) pays fees from remaining
            LibVaultCollateralService.transferCollateral(address(md.collateralToken), sellOrder.owner, cost);
            LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[outcomeId], msg.sender, fillQty);

            // Record fill (order1Id = 0 indicates market order taker)
            uint256 fillId = LibFillAggregate.recordFill(
                marketId, SettlementPath.NORMAL, 0, headOrderId, fillQty, bestAsk
            );

            // Distribute fees
            LibFeeDistributionService.distributeFees(
                address(md.collateralToken), breakdown, fees, marketId, fillId
            );

            // Update sell order; always decrement totalQty first, then dequeue/delete fully-filled orders
            LibOrderBookAggregate.recordFillOnBook(marketId, outcomeId, Side.SELL, bestAsk, fillQty);
            uint256 newQty = LibOrderAggregate.reduceOrderQty(headOrderId, fillQty);
            if (newQty == 0) {
                LibOrderBookService.dequeueOrder(headOrderId);
                LibOrderAggregate.deleteOrder(headOrderId);
            }

            // Track volume and last trade
            LibMarketTradingAggregate.recordTotalVolume(marketId, outcomeId, cost);
            LibMarketTradingAggregate.recordLastTradeTick(marketId, outcomeId, bestAsk);

            remaining -= cost;
            remaining -= (breakdown.totalFee + breakdown.remainder);
            totalTokens += fillQty;
        }

        // Revert if nothing was filled (empty book or all orders expired/out of range)
        if (totalTokens == 0) {
            revert LibMarketOrderValidator.NoLiquidityAvailable();
        }

        // Handle remaining collateral
        if (remaining > 0) {
            if (orderType == MarketOrderType.FOK && remaining > md.tickSize) {
                revert LibMarketOrderValidator.InsufficientLiquidityForFOK();
            }
            // Return unused collateral (FAK remainder or FOK rounding dust)
            LibVaultCollateralService.withdrawCollateral(address(md.collateralToken), msg.sender, remaining);
        }

        uint256 collateralSpent = collateralAmount - remaining;
        uint256 avgPrice = totalTokens > 0 ? (collateralSpent * 1e18) / totalTokens : 0;

        emit MarketOrderExecuted(
            msg.sender, marketId, outcomeId, collateralSpent, totalTokens, avgPrice, remaining
        );

        result = MarketBuyResult({
            tokensReceived: totalTokens,
            avgPrice: avgPrice,
            collateralSpent: collateralSpent,
            unusedCollateral: remaining
        });
    }
}
