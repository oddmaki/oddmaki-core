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
import {LibVaultPositionService} from "./LibVaultPositionService.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";
import {LibFillAggregate} from "../aggregates/LibFillAggregate.sol";
import {Order, Side, MarketTradingData, MarketFees, FeeBreakdown, SettlementPath} from "../interfaces/Types.sol";

/**
 * @title LibMintFillService
 * @notice Mint-to-fill matching strategy: when YES and NO buy bids together cover 1.0 collateral,
 *         the Diamond splits its pooled collateral to mint both outcome tokens and delivers them
 *         to the respective buyers.
 */
library LibMintFillService {
    event MintFill(
        uint256 indexed marketId,
        uint256 qty,
        uint256 yesOrderId,
        uint256 noOrderId,
        uint256 yesTick,
        uint256 noTick
    );

    event SurplusRouted(uint256 indexed marketId, uint256 indexed fillId, uint256 amount);

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

    /// @dev Heads + price ticks for a maker-vs-maker mint cross. Packed to keep
    ///      `_executeFill` argument lists from blowing the via_ir budget.
    struct MintFillContext {
        uint256 marketId;
        bytes32 conditionId;
        uint256 yesHead;
        uint256 noHead;
        uint256 yesBid;
        uint256 noBid;
    }

    /**
     * @notice Attempt a mint-to-fill.
     *         Returns true if a fill was executed.
     *         Returns false if the feasibility condition is not met, or if a head order was expired
     *         (cleaned up inline; caller should retry).
     * @param conditionId  CTF condition for this market (used by splitPosition).
     */
    function tryFill(uint256 marketId, bytes32 conditionId, MarketTradingData storage md)
        internal
        returns (bool filled)
    {
        for (uint256 retries = 0; retries < MAX_INLINE_EXPIRY_RETRIES; retries++) {
            uint256 yesBid = LibOrderBookStorage.getTopOfBook(marketId, 0, Side.BUY);
            uint256 noBid  = LibOrderBookStorage.getTopOfBook(marketId, 1, Side.BUY);

            if (yesBid == 0 || noBid == 0) return false;

            // Fee-aware feasibility: bids must cover 1.0 + fees
            MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
            if (!LibFeeCalculatorService.checkMintFeasibility(yesBid, noBid, md.tickSize, fees)) return false;

            uint256 yesHead = LibOrderBookStorage.getTickLevel(marketId, 0, Side.BUY, yesBid).headOrderId;
            uint256 noHead  = LibOrderBookStorage.getTickLevel(marketId, 1, Side.BUY, noBid).headOrderId;

            if (yesHead == 0 || noHead == 0) return false;

            if (LibOrderExpiryService.expireOrderInline(yesHead, md)) continue;
            if (LibOrderExpiryService.expireOrderInline(noHead, md)) continue;

            _executeFill(
                MintFillContext({
                    marketId: marketId,
                    conditionId: conditionId,
                    yesHead: yesHead,
                    noHead: noHead,
                    yesBid: yesBid,
                    noBid: noBid
                }),
                fees,
                md
            );
            return true;
        } // end retry loop
        return false;
    }

    // -------------------------------------------------------------------------
    // Market-taker mint primitive — taker BUY against an opposite-outcome BUY
    // resting maker. Used by `LibMarketTakeService` to fill the user's outcome
    // by splitting collateral with a counterparty on the other outcome.
    // -------------------------------------------------------------------------

    /// @dev Outcome of executing a single market-taker mint fill.
    struct MarketFillResult {
        uint256 fillQty;
        uint256 collateralConsumed;  // taker's budget deducted (deposit + fee)
        uint256 fillId;
    }

    struct MarketTakerMintParams {
        uint256 marketId;
        bytes32 conditionId;
        uint256 outcomeId;               // taker's outcome (gets these tokens)
        uint256 oppositeMakerBuyOrderId; // resting BUY head on the OPPOSITE outcome
        uint256 oppositeBidTick;         // maker's bid tick
        address taker;
        uint256 remainingBudget;
    }

    /// @notice Execute a single mint-to-fill cross where the taker is a market
    ///         BUY order and the maker is an opposite-outcome resting BUY.
    ///         Splits CTF collateral; taker gets `params.outcomeId` tokens,
    ///         maker gets the other outcome's tokens.
    /// @dev Affordable qty derived from the taker's remaining budget:
    ///         B = qty * complementTick * tickSize / 1e18 + qty * feeBps / BPS
    ///       The maker's deposit (already locked) + the taker's deposit
    ///       exactly cover the CTF split + fees; there is no surplus to route.
    function executeMarketTakerMint(
        MarketTakerMintParams memory params,
        MarketFees memory fees,
        MarketTradingData storage md
    ) internal returns (MarketFillResult memory r) {
        Order storage makerOrder = LibOrderStorage.getOrder(params.oppositeMakerBuyOrderId);
        if (makerOrder.id == 0) return r;

        uint256 fullTicks = 1e18 / md.tickSize;
        if (params.oppositeBidTick == 0 || params.oppositeBidTick >= fullTicks) return r;
        uint256 takerTick = fullTicks - params.oppositeBidTick;
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);

        // Affordable qty = B * 1e18 * BPS / (takerTick * tickSize * BPS + 1e18 * feeBps)
        uint256 denom = takerTick * md.tickSize * LibFeeCalculatorService.BPS_DENOMINATOR
            + 1e18 * totalFeeBps;
        if (denom == 0) return r;
        uint256 affordableQty = (params.remainingBudget * 1e18 * LibFeeCalculatorService.BPS_DENOMINATOR) / denom;
        uint256 fillQty = affordableQty < makerOrder.qty ? affordableQty : makerOrder.qty;
        if (fillQty == 0) return r;

        // Mint: CTF.splitPosition consumes `fillQty` collateral from the diamond's pool
        //       (taker deposit + maker deposit already in the pool), producing
        //       fillQty YES + fillQty NO tokens.
        LibVaultPositionService.splitPosition(address(md.collateralToken), params.conditionId, fillQty);

        uint256 otherIdx = params.outcomeId == 0 ? 1 : 0;

        // Deliver outcome tokens — taker gets their outcome, maker gets the other.
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[params.outcomeId], params.taker, fillQty);
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[otherIdx], makerOrder.owner, fillQty);

        // Update maker (opposite-outcome BUY) order on its book.
        LibOrderBookAggregate.recordFillOnBook(params.marketId, otherIdx, Side.BUY, params.oppositeBidTick, fillQty);
        uint256 newQty = LibOrderAggregate.reduceOrderQty(params.oppositeMakerBuyOrderId, fillQty);
        if (newQty == 0) {
            LibOrderBookService.dequeueOrder(params.oppositeMakerBuyOrderId);
            LibOrderAggregate.deleteOrder(params.oppositeMakerBuyOrderId);
        }

        // Volume + last-trade tick on both outcomes.
        uint256 takerDeposit = (fillQty * takerTick * md.tickSize) / 1e18;
        uint256 makerDeposit = (fillQty * params.oppositeBidTick * md.tickSize) / 1e18;
        LibMarketTradingAggregate.recordTotalVolume(params.marketId, params.outcomeId, takerDeposit);
        LibMarketTradingAggregate.recordTotalVolume(params.marketId, otherIdx, makerDeposit);
        LibMarketTradingAggregate.recordLastTradeTick(params.marketId, params.outcomeId, takerTick);
        LibMarketTradingAggregate.recordLastTradeTick(params.marketId, otherIdx, params.oppositeBidTick);

        // Fee math + distribution (notional = qty per mint convention).
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(fillQty, fees);

        // Map taker outcome to MintFill event's (yesOrderId, noOrderId, yesTick, noTick) ordering.
        uint256 yesOrderId; uint256 noOrderId; uint256 yesTick; uint256 noTick;
        if (params.outcomeId == 0) {
            yesOrderId = 0;
            noOrderId = params.oppositeMakerBuyOrderId;
            yesTick = takerTick;
            noTick = params.oppositeBidTick;
        } else {
            yesOrderId = params.oppositeMakerBuyOrderId;
            noOrderId = 0;
            yesTick = params.oppositeBidTick;
            noTick = takerTick;
        }

        r.fillId = LibFillAggregate.recordFill(
            params.marketId, SettlementPath.MINT, yesOrderId, noOrderId, fillQty, yesTick
        );

        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, params.marketId, r.fillId
        );

        emit MintFill(params.marketId, fillQty, yesOrderId, noOrderId, yesTick, noTick);
        emit TradeExecuted(params.marketId, 0, r.fillId, yesTick, fillQty, md.totalVolume[0], block.timestamp);
        emit TradeExecuted(params.marketId, 1, r.fillId, noTick, fillQty, md.totalVolume[1], block.timestamp);

        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;
        r.fillQty = fillQty;
        r.collateralConsumed = takerDeposit + feeTotal;
    }

    /**
     * @dev Execute a mint cross between two resting BUY heads (one per outcome).
     *      Both heads must reference live, unexpired orders. Splits the original
     *      `tryFill` body verbatim — no behavior change.
     */
    function _executeFill(MintFillContext memory ctx, MarketFees memory fees, MarketTradingData storage md)
        private
    {
        Order storage yesOrder = LibOrderStorage.getOrder(ctx.yesHead);
        Order storage noOrder  = LibOrderStorage.getOrder(ctx.noHead);

        uint256 qty = yesOrder.qty < noOrder.qty ? yesOrder.qty : noOrder.qty;

        // Split the Diamond's pooled collateral to mint YES + NO tokens (delivered to Diamond)
        LibVaultPositionService.splitPosition(address(md.collateralToken), ctx.conditionId, qty);

        // Deliver tokens to each buyer
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[0], yesOrder.owner, qty);
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[1], noOrder.owner, qty);

        // Update YES order; always decrement totalQty first, then dequeue/delete fully-filled orders
        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, 0, Side.BUY, ctx.yesBid, qty);
        uint256 newYesQty = LibOrderAggregate.reduceOrderQty(ctx.yesHead, qty);
        if (newYesQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.yesHead);
            LibOrderAggregate.deleteOrder(ctx.yesHead);
        }

        // Update NO order
        LibOrderBookAggregate.recordFillOnBook(ctx.marketId, 1, Side.BUY, ctx.noBid, qty);
        uint256 newNoQty = LibOrderAggregate.reduceOrderQty(ctx.noHead, qty);
        if (newNoQty == 0) {
            LibOrderBookService.dequeueOrder(ctx.noHead);
            LibOrderAggregate.deleteOrder(ctx.noHead);
        }

        // Record volume for both outcomes (both buyers are acquiring)
        uint256 yesCollateral = (qty * ctx.yesBid * md.tickSize) / 1e18;
        uint256 noCollateral  = (qty * ctx.noBid  * md.tickSize) / 1e18;
        LibMarketTradingAggregate.recordTotalVolume(ctx.marketId, 0, yesCollateral);
        LibMarketTradingAggregate.recordTotalVolume(ctx.marketId, 1, noCollateral);

        // Record last trade tick for both outcomes (both buyers are acquiring at their bid prices)
        LibMarketTradingAggregate.recordLastTradeTick(ctx.marketId, 0, ctx.yesBid);
        LibMarketTradingAggregate.recordLastTradeTick(ctx.marketId, 1, ctx.noBid);

        // Fee calculation: fee base is qty (notional = 1.0 per token set)
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(qty, fees);

        // Record fill
        uint256 fillId = LibFillAggregate.recordFill(
            ctx.marketId, SettlementPath.MINT, ctx.yesHead, ctx.noHead, qty, ctx.yesBid
        );

        // Distribute fees from surplus collateral (no-op if fees are zero)
        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, ctx.marketId, fillId
        );

        // Route surplus collateral (rounding dust from tick-price discretization) to protocol treasury
        uint256 totalDeposited = yesCollateral + noCollateral;
        uint256 totalConsumed = qty + breakdown.totalFee + breakdown.remainder;
        if (totalDeposited > totalConsumed) {
            uint256 surplus = totalDeposited - totalConsumed;
            if (fees.protocolTreasury != address(0)) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), fees.protocolTreasury, surplus);
                emit SurplusRouted(ctx.marketId, fillId, surplus);
            }
        }

        emit MintFill(ctx.marketId, qty, ctx.yesHead, ctx.noHead, ctx.yesBid, ctx.noBid);
        emit TradeExecuted(ctx.marketId, 0, fillId, ctx.yesBid, qty, md.totalVolume[0], block.timestamp);
        emit TradeExecuted(ctx.marketId, 1, fillId, ctx.noBid, qty, md.totalVolume[1], block.timestamp);
    }
}
