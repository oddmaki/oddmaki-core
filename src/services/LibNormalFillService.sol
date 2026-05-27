// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookAggregate} from "../aggregates/LibOrderBookAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";
import {LibFillAggregate} from "../aggregates/LibFillAggregate.sol";
import {Order, Side, MarketTradingData, MarketFees, FeeBreakdown, SettlementPath} from "../interfaces/Types.sol";

/**
 * @title LibNormalFillService
 * @notice Normal-fill matching strategy: crosses a BUY and SELL order on the same outcome.
 *         Seller receives collateral at the ask price; buyer receives outcome tokens.
 */
library LibNormalFillService {
    event OrderFilled(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 qty,
        uint256 priceTick
    );

    event OrderAutoCancelled(uint256 indexed orderId, uint256 refundedCollateral);

    event TradeExecuted(
        uint256 indexed marketId,
        uint256 indexed outcomeId,
        uint256 indexed fillId,
        uint256 priceTick,
        uint256 quantity,
        uint256 cumulativeVolume,
        uint256 timestamp
    );

    // Maximum inline expiry retries per tryFill call (guards against degenerate all-expired books)
    uint256 constant MAX_INLINE_EXPIRY_RETRIES = 10;

    /// @dev Heads + price ticks for a maker-vs-maker normal cross. Reduces stack pressure
    ///      on `_executeFill` and keeps argument lists from blowing the via_ir budget.
    struct NormalFillContext {
        uint256 marketId;
        uint256 outcomeId;
        uint256 buyHead;
        uint256 sellHead;
        uint256 bestBid;
        uint256 bestAsk;
    }

    /**
     * @notice Attempt a normal fill on `outcomeId`.
     *         Returns true if a fill was executed (partial or full).
     *         Returns false if there is no cross, or if a head order was found to be expired
     *         (the expired order is cleaned up and the caller should retry).
     */
    function tryFill(uint256 marketId, uint256 outcomeId, MarketTradingData storage md)
        internal
        returns (bool filled)
    {
        // Retry loop: if the FIFO head is expired we clean it up and try the next head.
        // This ensures one expired head does not prevent a live order behind it from filling.
        for (uint256 retries = 0; retries < MAX_INLINE_EXPIRY_RETRIES; retries++) {
            uint256 bestBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
            uint256 bestAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);

            if (bestBid == 0 || bestAsk == 0 || bestBid < bestAsk) return false;

            uint256 buyHead  = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.BUY,  bestBid).headOrderId;
            uint256 sellHead = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.SELL, bestAsk).headOrderId;

            if (buyHead == 0 || sellHead == 0) return false;

            // Clean up expired head orders and retry if one was found
            if (LibOrderExpiryService.expireOrderInline(buyHead,  md)) continue;
            if (LibOrderExpiryService.expireOrderInline(sellHead, md)) continue;

            _executeFill(
                NormalFillContext({
                    marketId: marketId,
                    outcomeId: outcomeId,
                    buyHead: buyHead,
                    sellHead: sellHead,
                    bestBid: bestBid,
                    bestAsk: bestAsk
                }),
                md
            );
            return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Market-taker primitives — single-fill execution against a specific
    // resting maker order. Used by `LibMarketTakeService` (PR 3) to walk the
    // book step-by-step while deciding cheapest path per iteration.
    // -------------------------------------------------------------------------

    /// @dev Outcome of executing one market-taker fill on a specific maker order.
    struct MarketFillResult {
        uint256 fillQty;             // shares filled this step
        uint256 collateralConsumed;  // taker's budget deducted (cost + taker fee)
        uint256 fillId;              // fill record ID
    }

    /// @dev Inputs for executing a single market-taker BUY against a maker SELL head.
    struct MarketTakerBuyParams {
        uint256 marketId;
        uint256 outcomeId;
        uint256 makerSellOrderId;    // resting SELL head on `outcomeId`
        uint256 askTick;             // maker's ask tick (= current bestAsk on that level)
        address taker;               // market-order caller (gets the outcome tokens)
        uint256 remainingBudget;     // taker's unspent collateral
    }

    /// @notice Execute a single normal-fill cross where the taker is a market
    ///         BUY order (no resting taker order on the book). Returns 0
    ///         filledQty when the budget is too small to fill even one share
    ///         after fees.
    /// @dev Mirrors the per-iteration body of `LibMarketOrderService.placeMarketOrder`,
    ///      packaged so the multi-path take service can call it directly. Maker is
    ///      always the resting SELL head; taker is `params.taker` (no order ID, so
    ///      fills are recorded with `order1Id = 0`).
    function executeMarketTakerBuy(
        MarketTakerBuyParams memory params,
        MarketFees memory fees,
        MarketTradingData storage md
    ) internal returns (MarketFillResult memory r) {
        Order storage sellOrder = LibOrderStorage.getOrder(params.makerSellOrderId);
        if (sellOrder.id == 0) return r;

        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        uint256 pricePerToken = params.askTick * md.tickSize;
        // affordableQty = budget * 1e18 * BPS / (pricePerToken * (BPS + feeBps))
        uint256 affordableQty = (params.remainingBudget * 1e18 * LibFeeCalculatorService.BPS_DENOMINATOR)
            / (pricePerToken * (LibFeeCalculatorService.BPS_DENOMINATOR + totalFeeBps));
        uint256 fillQty = affordableQty < sellOrder.qty ? affordableQty : sellOrder.qty;
        if (fillQty == 0) return r;

        uint256 cost = (fillQty * pricePerToken) / 1e18;
        if (cost == 0) return r;

        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(cost, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;

        // Settlement: maker (resting seller) gets full cost; taker pays cost + fee.
        LibVaultCollateralService.transferCollateral(address(md.collateralToken), sellOrder.owner, cost);
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[params.outcomeId], params.taker, fillQty);

        // Record fill (order1Id = 0 → market-taker side).
        r.fillId = LibFillAggregate.recordFill(
            params.marketId, SettlementPath.NORMAL, 0, params.makerSellOrderId, fillQty, params.askTick
        );

        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, params.marketId, r.fillId
        );

        // Update sell order.
        LibOrderBookAggregate.recordFillOnBook(params.marketId, params.outcomeId, Side.SELL, params.askTick, fillQty);
        uint256 newQty = LibOrderAggregate.reduceOrderQty(params.makerSellOrderId, fillQty);
        if (newQty == 0) {
            LibOrderBookService.dequeueOrder(params.makerSellOrderId);
            LibOrderAggregate.deleteOrder(params.makerSellOrderId);
        }

        LibMarketTradingAggregate.recordTotalVolume(params.marketId, params.outcomeId, cost);
        LibMarketTradingAggregate.recordLastTradeTick(params.marketId, params.outcomeId, params.askTick);

        emit OrderFilled(0, params.makerSellOrderId, params.marketId, params.outcomeId, fillQty, params.askTick);
        emit TradeExecuted(
            params.marketId, params.outcomeId, r.fillId, params.askTick, fillQty,
            md.totalVolume[params.outcomeId], block.timestamp
        );

        r.fillQty = fillQty;
        r.collateralConsumed = cost + feeTotal;
    }

    /// @dev Inputs for executing a single market-taker SELL against a maker BUY head.
    struct MarketTakerSellParams {
        uint256 marketId;
        uint256 outcomeId;
        uint256 makerBuyOrderId;     // resting BUY head on `outcomeId`
        uint256 bidTick;             // maker's bid tick
        address taker;               // market-order caller (receives net proceeds)
        uint256 remainingQty;        // taker's unsold tokens
    }

    /// @notice Execute a single normal-fill cross where the taker is a market
    ///         SELL order. Maker (buyer) gets the outcome tokens at full
    ///         deposit; taker (seller) receives `proceeds - fee` collateral.
    function executeMarketTakerSell(
        MarketTakerSellParams memory params,
        MarketFees memory fees,
        MarketTradingData storage md
    ) internal returns (MarketFillResult memory r) {
        Order storage buyOrder = LibOrderStorage.getOrder(params.makerBuyOrderId);
        if (buyOrder.id == 0) return r;

        uint256 fillQty = params.remainingQty < buyOrder.qty ? params.remainingQty : buyOrder.qty;
        if (fillQty == 0) return r;

        uint256 pricePerToken = params.bidTick * md.tickSize;
        uint256 proceeds = (fillQty * pricePerToken) / 1e18;
        if (proceeds == 0) return r;

        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(proceeds, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;
        uint256 sellerNet = proceeds - feeTotal;

        // Settlement: taker gets proceeds net of fees; maker (buyer) gets outcome tokens.
        LibVaultCollateralService.transferCollateral(address(md.collateralToken), params.taker, sellerNet);
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[params.outcomeId], buyOrder.owner, fillQty);

        // Record fill (order2Id = 0 → market-taker side).
        r.fillId = LibFillAggregate.recordFill(
            params.marketId, SettlementPath.NORMAL, params.makerBuyOrderId, 0, fillQty, params.bidTick
        );

        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, params.marketId, r.fillId
        );

        LibOrderBookAggregate.recordFillOnBook(params.marketId, params.outcomeId, Side.BUY, params.bidTick, fillQty);
        uint256 newQty = LibOrderAggregate.reduceOrderQty(params.makerBuyOrderId, fillQty);
        if (newQty == 0) {
            LibOrderBookService.dequeueOrder(params.makerBuyOrderId);
            LibOrderAggregate.deleteOrder(params.makerBuyOrderId);
        }

        LibMarketTradingAggregate.recordTotalVolume(params.marketId, params.outcomeId, proceeds);
        LibMarketTradingAggregate.recordLastTradeTick(params.marketId, params.outcomeId, params.bidTick);

        emit OrderFilled(params.makerBuyOrderId, 0, params.marketId, params.outcomeId, fillQty, params.bidTick);
        emit TradeExecuted(
            params.marketId, params.outcomeId, r.fillId, params.bidTick, fillQty,
            md.totalVolume[params.outcomeId], block.timestamp
        );

        r.fillQty = fillQty;
        // Sell-side "collateralConsumed" means shares consumed from the taker's input. Cost
        // semantics differ — the take service uses the dedicated TakeSellResult shape.
        r.collateralConsumed = fillQty;
    }

    /**
     * @dev Execute the cross between `ctx.buyHead` (maker or taker) and `ctx.sellHead`
     *      (maker or taker) at the current top-of-book ticks. Both order IDs must reference
     *      live, unexpired orders. Maker/taker is resolved by FIFO order ID. Splits the
     *      original `tryFill` body verbatim — no behavior change.
     */
    function _executeFill(NormalFillContext memory ctx, MarketTradingData storage md) private {
        Order storage buyOrder = LibOrderStorage.getOrder(ctx.buyHead);
        Order storage sellOrder = LibOrderStorage.getOrder(ctx.sellHead);

        // Determine maker/taker: lower orderId placed first = maker (0% fee)
        bool buyerIsTaker = (buyOrder.id > sellOrder.id);
        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(ctx.marketId);
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);

        // Base qty limited by order sizes
        uint256 qty = buyOrder.qty < sellOrder.qty ? buyOrder.qty : sellOrder.qty;
        uint256 baseQty = qty; // save before affordable reduction for deposit calc

        // When buyer is taker: reduce qty so buyer's deposit covers trade + fee
        if (buyerIsTaker && totalFeeBps > 0) {
            // Buyer's available deposit for this fill = qty * bestBid (in collateral terms)
            // Each token costs bestAsk + fee = bestAsk * (BPS + totalFeeBps) / BPS
            // affordableQty = buyerDeposit / costPerToken (in tick math to avoid decimals)
            // = (qty * bestBid * BPS) / (bestAsk * (BPS + totalFeeBps))
            uint256 affordableQty = (qty * ctx.bestBid * LibFeeCalculatorService.BPS_DENOMINATOR)
                / (ctx.bestAsk * (LibFeeCalculatorService.BPS_DENOMINATOR + totalFeeBps));
            if (affordableQty < qty) {
                qty = affordableQty;
            }
            if (qty == 0) return;
        }

        uint256 collateral = (qty * ctx.bestAsk * md.tickSize) / 1e18;
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(collateral, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;

        // Settlement: maker gets full amount, taker pays fees
        if (buyerIsTaker) {
            // Seller (maker): gets full collateral
            LibVaultCollateralService.transferCollateral(address(md.collateralToken), sellOrder.owner, collateral);
            LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[ctx.outcomeId], buyOrder.owner, qty);
            // Buyer (taker): refund = deposit - trade - fee
            // Use baseQty (pre-reduction) for deposit since that's what buyer actually has at stake
            uint256 buyerDeposit = (baseQty * ctx.bestBid * md.tickSize) / 1e18;
            uint256 consumed = collateral + feeTotal;
            uint256 buyerRefund = buyerDeposit > consumed ? buyerDeposit - consumed : 0;
            if (buyerRefund > 0) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), buyOrder.owner, buyerRefund);
            }
        } else {
            // Seller (taker): pays fees from proceeds
            LibVaultCollateralService.transferCollateral(address(md.collateralToken), sellOrder.owner, collateral - feeTotal);
            LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[ctx.outcomeId], buyOrder.owner, qty);
            // Buyer (maker): full surplus refund
            if (ctx.bestBid > ctx.bestAsk) {
                uint256 buyerSurplus = (qty * (ctx.bestBid - ctx.bestAsk) * md.tickSize) / 1e18;
                if (buyerSurplus > 0) {
                    LibVaultCollateralService.transferCollateral(address(md.collateralToken), buyOrder.owner, buyerSurplus);
                }
            }
        }

        // Record fill
        uint256 fillId = LibFillAggregate.recordFill(
            ctx.marketId, SettlementPath.NORMAL, ctx.buyHead, ctx.sellHead, qty, ctx.bestAsk
        );

        // Distribute fees (no-op if fees are zero)
        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, ctx.marketId, fillId
        );

        // Update orders; always decrement totalQty first, then dequeue/delete fully-filled orders
        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, ctx.outcomeId, Side.BUY, ctx.bestBid, qty);
        uint256 newBuyQty = LibOrderAggregate.reduceOrderQty(ctx.buyHead, qty);
        if (newBuyQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.buyHead);
            LibOrderAggregate.deleteOrder(ctx.buyHead);
        } else if (buyerIsTaker && totalFeeBps > 0) {
            // Auto-cancel unfunded remainder: fee erosion means the remaining
            // collateral can't back the remainder at this bid price.
            // Underfunded when: bestBid * BPS < bestAsk * (BPS + totalFeeBps)
            uint256 bps = LibFeeCalculatorService.BPS_DENOMINATOR;
            if (ctx.bestBid * bps < ctx.bestAsk * (bps + totalFeeBps)) {
                // Refund the untouched escrow for the portion that was never attempted
                // in this fill. The buyer deposited (qty_initial * bestBid * tickSize / 1e18)
                // at placement. The buyerRefund above already released the baseQty
                // slice, so what remains in the vault for this order is
                // (qty_initial - baseQty) * bestBid * tickSize / 1e18, where
                // qty_initial = newBuyQty + qty.
                uint256 unattempted = newBuyQty + qty - baseQty;
                uint256 refund = (unattempted * ctx.bestBid * md.tickSize) / 1e18;
                if (refund > 0) {
                    LibVaultCollateralService.transferCollateral(
                        address(md.collateralToken), buyOrder.owner, refund
                    );
                }
                // Zero out qty before dequeue so removeOrderFromLevel subtracts 0 from totalQty
                // (totalQty was already decremented by recordFillOnBook above for the fill portion,
                //  and reduceOrderQty left newBuyQty in order.qty which we now zero)
                LibOrderAggregate.reduceOrderQty(ctx.buyHead, newBuyQty);
                LibOrderBookService.dequeueOrder(ctx.buyHead);
                LibOrderAggregate.deleteOrder(ctx.buyHead);
                emit OrderAutoCancelled(ctx.buyHead, refund);
            }
        }

        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, ctx.outcomeId, Side.SELL, ctx.bestAsk, qty);
        uint256 newSellQty = LibOrderAggregate.reduceOrderQty(ctx.sellHead, qty);
        if (newSellQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.sellHead);
            LibOrderAggregate.deleteOrder(ctx.sellHead);
        }

        LibMarketTradingAggregate.recordTotalVolume(ctx.marketId, ctx.outcomeId, collateral);
        LibMarketTradingAggregate.recordLastTradeTick(ctx.marketId, ctx.outcomeId, ctx.bestAsk);

        emit OrderFilled(ctx.buyHead, ctx.sellHead, ctx.marketId, ctx.outcomeId, qty, ctx.bestAsk);
        emit TradeExecuted(ctx.marketId, ctx.outcomeId, fillId, ctx.bestAsk, qty, md.totalVolume[ctx.outcomeId], block.timestamp);
    }
}
