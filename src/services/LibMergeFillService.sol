// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookAggregate} from "../aggregates/LibOrderBookAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultPositionService} from "./LibVaultPositionService.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";
import {LibFillAggregate} from "../aggregates/LibFillAggregate.sol";
import {Order, Side, MarketTradingData, MarketFees, FeeBreakdown, SettlementPath} from "../interfaces/Types.sol";

/**
 * @title LibMergeFillService
 * @notice Merge-to-fill matching strategy: when YES and NO sell asks together cost ≤ 1.0 collateral,
 *         the Diamond merges its pooled outcome tokens into collateral and pays each seller at their
 *         respective ask price.
 *         Volume is NOT recorded (sellers are exiting positions, not acquiring).
 */
library LibMergeFillService {
    event SurplusRouted(uint256 indexed marketId, uint256 indexed fillId, uint256 amount);

    event MergeFill(
        uint256 indexed marketId,
        uint256 qty,
        uint256 yesOrderId,
        uint256 noOrderId,
        uint256 yesTick,
        uint256 noTick
    );

    // Maximum inline expiry retries per tryFill call (guards against degenerate all-expired books)
    uint256 constant MAX_INLINE_EXPIRY_RETRIES = 10;

    /// @dev Heads + ask ticks for a maker-vs-maker merge cross.
    struct MergeFillContext {
        uint256 marketId;
        bytes32 conditionId;
        uint256 yesHead;
        uint256 noHead;
        uint256 yesAsk;
        uint256 noAsk;
    }

    /**
     * @notice Attempt a merge-to-fill.
     *         Returns true if a fill was executed.
     *         Returns false if the feasibility condition is not met, or if a head order was expired
     *         (cleaned up inline; caller should retry).
     * @param conditionId  CTF condition for this market (used by mergePositions).
     */
    function tryFill(uint256 marketId, bytes32 conditionId, MarketTradingData storage md)
        internal
        returns (bool filled)
    {
        for (uint256 retries = 0; retries < MAX_INLINE_EXPIRY_RETRIES; retries++) {
            uint256 yesAsk = LibOrderBookStorage.getTopOfBook(marketId, 0, Side.SELL);
            uint256 noAsk  = LibOrderBookStorage.getTopOfBook(marketId, 1, Side.SELL);

            if (yesAsk == 0 || noAsk == 0) return false;

            // Fee-aware feasibility: asks must not exceed 1.0 - fees
            MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
            if (!LibFeeCalculatorService.checkMergeFeasibility(yesAsk, noAsk, md.tickSize, fees)) return false;

            uint256 yesHead = LibOrderBookStorage.getTickLevel(marketId, 0, Side.SELL, yesAsk).headOrderId;
            uint256 noHead  = LibOrderBookStorage.getTickLevel(marketId, 1, Side.SELL, noAsk).headOrderId;

            if (yesHead == 0 || noHead == 0) return false;

            if (LibOrderExpiryService.expireOrderInline(yesHead, md)) continue;
            if (LibOrderExpiryService.expireOrderInline(noHead, md)) continue;

            _executeFill(
                MergeFillContext({
                    marketId: marketId,
                    conditionId: conditionId,
                    yesHead: yesHead,
                    noHead: noHead,
                    yesAsk: yesAsk,
                    noAsk: noAsk
                }),
                fees,
                md
            );
            return true;
        } // end retry loop
        return false;
    }

    // -------------------------------------------------------------------------
    // Market-taker merge primitive — taker SELL against an opposite-outcome
    // SELL resting maker. Used by `LibMarketTakeService` to convert the
    // user's outcome tokens back into collateral via the CTF merge path.
    // -------------------------------------------------------------------------

    struct MarketFillResult {
        uint256 fillQty;        // shares of taker's outcome consumed
        uint256 grossProceeds;  // taker's gross per-fill payout (pre-fee)
        uint256 netProceeds;    // taker's net per-fill payout (post-fee)
        uint256 fillId;
    }

    struct MarketTakerMergeParams {
        uint256 marketId;
        bytes32 conditionId;
        uint256 outcomeId;                // taker's outcome (they sell these)
        uint256 oppositeMakerSellOrderId; // resting SELL head on the opposite outcome
        uint256 oppositeAskTick;          // maker's ask tick
        address taker;
        uint256 remainingQty;             // taker's remaining tokens
    }

    /// @notice Execute a single merge-to-fill cross where the taker is a market
    ///         SELL order and the maker is an opposite-outcome resting SELL.
    ///         Diamond merges qty YES + qty NO into qty collateral, pays maker
    ///         their ask price (no fee — they're the maker), pays taker the
    ///         complementary price net of fees.
    function executeMarketTakerMerge(
        MarketTakerMergeParams memory params,
        MarketFees memory fees,
        MarketTradingData storage md
    ) internal returns (MarketFillResult memory r) {
        Order storage makerOrder = LibOrderStorage.getOrder(params.oppositeMakerSellOrderId);
        if (makerOrder.id == 0) return r;

        uint256 fullTicks = 1e18 / md.tickSize;
        if (params.oppositeAskTick == 0 || params.oppositeAskTick >= fullTicks) return r;

        uint256 fillQty = params.remainingQty < makerOrder.qty ? params.remainingQty : makerOrder.qty;
        if (fillQty == 0) return r;

        uint256 takerTick = fullTicks - params.oppositeAskTick;
        uint256 makerPayout = (fillQty * params.oppositeAskTick * md.tickSize) / 1e18;
        uint256 takerGross  = (fillQty * takerTick * md.tickSize) / 1e18;

        // Merge: CTF consumes the diamond's qty YES + qty NO and returns qty collateral.
        LibVaultPositionService.mergePositions(address(md.collateralToken), params.conditionId, fillQty);

        // Fees on the merge notional (qty).
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(fillQty, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;
        uint256 takerNet = takerGross > feeTotal ? takerGross - feeTotal : 0;

        // Payouts (must happen before order deletion which zeroes maker.owner).
        LibVaultCollateralService.transferCollateral(address(md.collateralToken), makerOrder.owner, makerPayout);
        if (takerNet > 0) {
            LibVaultCollateralService.transferCollateral(address(md.collateralToken), params.taker, takerNet);
        }

        // Update maker order on its book.
        uint256 otherIdx = params.outcomeId == 0 ? 1 : 0;
        LibOrderBookAggregate.recordFillOnBook(params.marketId, otherIdx, Side.SELL, params.oppositeAskTick, fillQty);
        uint256 newQty = LibOrderAggregate.reduceOrderQty(params.oppositeMakerSellOrderId, fillQty);
        if (newQty == 0) {
            LibOrderBookService.dequeueOrder(params.oppositeMakerSellOrderId);
            LibOrderAggregate.deleteOrder(params.oppositeMakerSellOrderId);
        }

        // Volume is NOT recorded for merge — sellers are exiting, not acquiring.
        // (Parity with the matching-engine merge path.)

        // Map taker outcome to MergeFill event's (yesOrderId, noOrderId, yesTick, noTick) ordering.
        uint256 yesOrderId; uint256 noOrderId; uint256 yesTick; uint256 noTick;
        if (params.outcomeId == 0) {
            yesOrderId = 0;
            noOrderId = params.oppositeMakerSellOrderId;
            yesTick = takerTick;
            noTick = params.oppositeAskTick;
        } else {
            yesOrderId = params.oppositeMakerSellOrderId;
            noOrderId = 0;
            yesTick = params.oppositeAskTick;
            noTick = takerTick;
        }

        r.fillId = LibFillAggregate.recordFill(
            params.marketId, SettlementPath.MERGE, yesOrderId, noOrderId, fillQty, yesTick
        );

        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, params.marketId, r.fillId
        );

        emit MergeFill(params.marketId, fillQty, yesOrderId, noOrderId, yesTick, noTick);

        r.fillQty = fillQty;
        r.grossProceeds = takerGross;
        r.netProceeds = takerNet;
    }

    /**
     * @dev Execute a merge cross between two resting SELL heads (one per outcome).
     *      Both heads must reference live, unexpired orders. Splits the original
     *      `tryFill` body verbatim — no behavior change.
     */
    function _executeFill(MergeFillContext memory ctx, MarketFees memory fees, MarketTradingData storage md)
        private
    {
        Order storage yesOrder = LibOrderStorage.getOrder(ctx.yesHead);
        Order storage noOrder  = LibOrderStorage.getOrder(ctx.noHead);

        uint256 qty = yesOrder.qty < noOrder.qty ? yesOrder.qty : noOrder.qty;

        // Merge the Diamond's pooled outcome tokens to release collateral
        LibVaultPositionService.mergePositions(address(md.collateralToken), ctx.conditionId, qty);

        // Pay each seller: maker gets full ask payout, taker pays all fees
        uint256 yesCollateral = (qty * ctx.yesAsk * md.tickSize) / 1e18;
        uint256 noCollateral  = (qty * ctx.noAsk  * md.tickSize) / 1e18;

        // Fee calculation: fee base is qty (notional = 1.0 per token set)
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(qty, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;

        // Maker/taker payout (must happen before order deletion which zeroes owner)
        {
            bool yesIsTaker = (ctx.yesHead > ctx.noHead);
            // Guard: cap fee deduction at taker's collateral to prevent underflow
            uint256 takerCol = yesIsTaker ? yesCollateral : noCollateral;
            uint256 takerFeeDeduction = feeTotal > takerCol ? takerCol : feeTotal;
            if (yesIsTaker) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), yesOrder.owner, yesCollateral - takerFeeDeduction);
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), noOrder.owner,  noCollateral);
            } else {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), yesOrder.owner, yesCollateral);
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), noOrder.owner,  noCollateral - takerFeeDeduction);
            }
        }

        // Update YES order; always decrement totalQty first, then dequeue/delete fully-filled orders
        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, 0, Side.SELL, ctx.yesAsk, qty);
        uint256 newYesQty = LibOrderAggregate.reduceOrderQty(ctx.yesHead, qty);
        if (newYesQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.yesHead);
            LibOrderAggregate.deleteOrder(ctx.yesHead);
        }

        // Update NO order
        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, 1, Side.SELL, ctx.noAsk, qty);
        uint256 newNoQty = LibOrderAggregate.reduceOrderQty(ctx.noHead, qty);
        if (newNoQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.noHead);
            LibOrderAggregate.deleteOrder(ctx.noHead);
        }

        // Volume NOT recorded: merge-to-fill is sellers exiting, not buyers acquiring

        // Record fill
        uint256 fillId = LibFillAggregate.recordFill(
            ctx.marketId, SettlementPath.MERGE, ctx.yesHead, ctx.noHead, qty, ctx.yesAsk
        );

        // Distribute fees from remaining collateral after seller payouts (no-op if fees are zero)
        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, ctx.marketId, fillId
        );

        // Route surplus collateral (rounding dust from tick-price discretization) to protocol treasury
        uint256 totalConsumed = yesCollateral + noCollateral + feeTotal;
        if (qty > totalConsumed) {
            uint256 surplus = qty - totalConsumed;
            if (fees.protocolTreasury != address(0)) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), fees.protocolTreasury, surplus);
                emit SurplusRouted(ctx.marketId, fillId, surplus);
            }
        }

        emit MergeFill(ctx.marketId, qty, ctx.yesHead, ctx.noHead, ctx.yesAsk, ctx.noAsk);
    }
}
