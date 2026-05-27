// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibMarkPriceService} from "./LibMarkPriceService.sol";
import {LibNormalFillService} from "./LibNormalFillService.sol";
import {LibMintFillService} from "./LibMintFillService.sol";
import {LibMergeFillService} from "./LibMergeFillService.sol";
import {Side, MarketTradingData, MarketFees} from "../interfaces/Types.sol";

/**
 * @title LibMarketTakeService
 * @notice Multi-path market-order execution. Walks both books simultaneously,
 *         picking the cheapest crossable path (normal-fill vs mint-fill for
 *         BUY; normal-fill vs merge-fill for SELL) at each step, bounded by a
 *         slippage cap anchored to the pre-trade mark price.
 *
 *         The slippage cap is computed ONCE at entry. It does not move with
 *         the price the take itself causes — anchoring it pre-trade is what
 *         makes the user's stated tolerance enforceable.
 */
library LibMarketTakeService {
    /// @dev Maximum fill iterations per call (per-side step budget).
    uint256 internal constant MAX_TAKE_STEPS = 20;

    /// @dev Maximum inline expiry retries per step before giving up on a head.
    uint256 internal constant MAX_EXPIRY_RETRIES = 5;

    /// @dev Hard cap on user-supplied slippage to avoid degenerate-cap abuse.
    uint256 internal constant MAX_SLIPPAGE_BPS = 2000; // 20%

    error NoReferencePrice();
    error SlippageTooHigh();
    error NoLiquidityWithinSlippage();

    struct TakeBuyResult {
        uint256 filledQty;
        uint256 consumedBudget;
        uint256 remainingBudget;
        uint256 fillCount;
        uint256 markTick;       // pre-trade reference (informational)
        uint256 maxEffTick;     // resolved slippage cap (informational)
    }

    struct TakeSellResult {
        uint256 soldQty;
        uint256 grossProceeds;
        uint256 netProceeds;
        uint256 remainingQty;
        uint256 fillCount;
        uint256 markTick;
        uint256 minEffTick;
    }

    /// @dev Convenience reader for the (questionId → conditionId) link.
    function _conditionId(uint256 marketId) private view returns (bytes32) {
        bytes32 questionId = LibMarketRegistryStorage.getStorage().byMarketId[marketId].questionId;
        return LibMarketOracleStorage.getStorage().byQuestionId[questionId].conditionId;
    }

    /// @dev Computes the slippage cap from the resolved mark tick (BUY side).
    ///      maxEffTick = markTick + ceil(markTick * slippageBps / BPS), clipped to fullTicks.
    function _buyCap(uint256 markTick, uint256 slippageBps, uint256 fullTicks) private pure returns (uint256) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 bump = (markTick * slippageBps + BPS - 1) / BPS; // ceil
        uint256 cap = markTick + bump;
        return cap > fullTicks ? fullTicks : cap;
    }

    /// @dev Lower bound for SELL: minEffTick = markTick - ceil(markTick * slippageBps / BPS),
    ///      floored at 1 to leave room for fees.
    function _sellFloor(uint256 markTick, uint256 slippageBps) private pure returns (uint256) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 drop = (markTick * slippageBps + BPS - 1) / BPS;
        return markTick > drop ? markTick - drop : 1;
    }

    // -------------------------------------------------------------------------
    // BUY
    // -------------------------------------------------------------------------

    /// @notice Take liquidity on the BUY side: consumes `budget` collateral
    ///         already deposited by the taker, fills the user's outcome via
    ///         normal and/or mint paths, picks cheapest per step, capped by
    ///         the slippage cap derived from the on-chain mark price.
    /// @dev Caller is responsible for depositing `budget` collateral before
    ///      calling and refunding `result.remainingBudget` after.
    function takeMarketBuy(
        uint256 marketId,
        uint256 outcomeId,
        address taker,
        uint256 budget,
        uint256 slippageBps,
        MarketTradingData storage md
    ) internal returns (TakeBuyResult memory result) {
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();

        (uint256 markTick, bool defined) = LibMarkPriceService.getMarkPriceTick(marketId, outcomeId);
        if (!defined) revert NoReferencePrice();

        uint256 fullTicks = 1e18 / md.tickSize;
        uint256 maxEffTick = _buyCap(markTick, slippageBps, fullTicks);

        result.markTick = markTick;
        result.maxEffTick = maxEffTick;
        result.remainingBudget = budget;

        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        bytes32 conditionId; // lazy resolution if we need it for mint
        uint256 otherIdx = outcomeId == 0 ? 1 : 0;

        for (uint256 step = 0; step < MAX_TAKE_STEPS && result.remainingBudget > 0; step++) {
            uint256 sameAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
            uint256 otherBid = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.BUY);

            if (sameAsk == 0 && otherBid == 0) break;

            // Effective per-token cost in tick units (rounded up).
            uint256 normalCost = sameAsk == 0
                ? type(uint256).max
                : (sameAsk * (LibFeeCalculatorService.BPS_DENOMINATOR + totalFeeBps)
                    + LibFeeCalculatorService.BPS_DENOMINATOR - 1)
                  / LibFeeCalculatorService.BPS_DENOMINATOR;

            // Mint taker cost in tick units = (fullTicks - otherBid) + ceil(fullTicks * feeBps / BPS).
            uint256 mintCost = (otherBid == 0 || otherBid >= fullTicks)
                ? type(uint256).max
                : (fullTicks - otherBid)
                  + (fullTicks * totalFeeBps + LibFeeCalculatorService.BPS_DENOMINATOR - 1)
                    / LibFeeCalculatorService.BPS_DENOMINATOR;

            bool useNormal = normalCost <= mintCost;
            uint256 chosenCost = useNormal ? normalCost : mintCost;
            if (chosenCost == type(uint256).max || chosenCost > maxEffTick) break;

            if (useNormal) {
                if (!_takeNormalBuyStep(marketId, outcomeId, sameAsk, taker, fees, md, result)) break;
            } else {
                if (conditionId == bytes32(0)) conditionId = _conditionId(marketId);
                if (!_takeMintBuyStep(marketId, outcomeId, otherBid, otherIdx, conditionId, taker, fees, md, result)) break;
            }
        }
    }

    /// @dev Execute one normal-fill step on the BUY take loop. Returns false to
    ///      signal the loop should stop (no fill possible at this state).
    function _takeNormalBuyStep(
        uint256 marketId,
        uint256 outcomeId,
        uint256 sameAsk,
        address taker,
        MarketFees memory fees,
        MarketTradingData storage md,
        TakeBuyResult memory result
    ) private returns (bool) {
        uint256 makerHead = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.SELL, sameAsk).headOrderId;
        if (makerHead == 0) return false;

        // Clear expired heads inline (bounded retries) before executing.
        bool stillExpired = true;
        for (uint256 r = 0; r < MAX_EXPIRY_RETRIES && stillExpired; r++) {
            stillExpired = LibOrderExpiryService.expireOrderInline(makerHead, md);
            if (stillExpired) {
                uint256 freshAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
                if (freshAsk != sameAsk || freshAsk == 0) return true; // re-evaluate from outer loop
                makerHead = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.SELL, freshAsk).headOrderId;
                if (makerHead == 0) return false;
            }
        }
        if (stillExpired) return false;

        LibNormalFillService.MarketFillResult memory fr = LibNormalFillService.executeMarketTakerBuy(
            LibNormalFillService.MarketTakerBuyParams({
                marketId: marketId,
                outcomeId: outcomeId,
                makerSellOrderId: makerHead,
                askTick: sameAsk,
                taker: taker,
                remainingBudget: result.remainingBudget
            }),
            fees,
            md
        );
        if (fr.fillQty == 0) return false;
        result.filledQty += fr.fillQty;
        result.remainingBudget -= fr.collateralConsumed;
        result.consumedBudget += fr.collateralConsumed;
        result.fillCount += 1;
        return true;
    }

    /// @dev Execute one mint-fill step on the BUY take loop.
    function _takeMintBuyStep(
        uint256 marketId,
        uint256 outcomeId,
        uint256 otherBid,
        uint256 otherIdx,
        bytes32 conditionId,
        address taker,
        MarketFees memory fees,
        MarketTradingData storage md,
        TakeBuyResult memory result
    ) private returns (bool) {
        uint256 makerHead = LibOrderBookStorage.getTickLevel(marketId, otherIdx, Side.BUY, otherBid).headOrderId;
        if (makerHead == 0) return false;

        bool stillExpired = true;
        for (uint256 r = 0; r < MAX_EXPIRY_RETRIES && stillExpired; r++) {
            stillExpired = LibOrderExpiryService.expireOrderInline(makerHead, md);
            if (stillExpired) {
                uint256 freshBid = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.BUY);
                if (freshBid != otherBid || freshBid == 0) return true;
                makerHead = LibOrderBookStorage.getTickLevel(marketId, otherIdx, Side.BUY, freshBid).headOrderId;
                if (makerHead == 0) return false;
            }
        }
        if (stillExpired) return false;

        LibMintFillService.MarketFillResult memory fr = LibMintFillService.executeMarketTakerMint(
            LibMintFillService.MarketTakerMintParams({
                marketId: marketId,
                conditionId: conditionId,
                outcomeId: outcomeId,
                oppositeMakerBuyOrderId: makerHead,
                oppositeBidTick: otherBid,
                taker: taker,
                remainingBudget: result.remainingBudget
            }),
            fees,
            md
        );
        if (fr.fillQty == 0) return false;
        result.filledQty += fr.fillQty;
        result.remainingBudget -= fr.collateralConsumed;
        result.consumedBudget += fr.collateralConsumed;
        result.fillCount += 1;
        return true;
    }

    // -------------------------------------------------------------------------
    // SELL
    // -------------------------------------------------------------------------

    /// @notice Take liquidity on the SELL side: taker provides `sharesIn`
    ///         outcome tokens (already deposited), sells via normal and/or
    ///         merge paths, picks highest net taker tick per step.
    function takeMarketSell(
        uint256 marketId,
        uint256 outcomeId,
        address taker,
        uint256 sharesIn,
        uint256 slippageBps,
        MarketTradingData storage md
    ) internal returns (TakeSellResult memory result) {
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();

        (uint256 markTick, bool defined) = LibMarkPriceService.getMarkPriceTick(marketId, outcomeId);
        if (!defined) revert NoReferencePrice();

        uint256 fullTicks = 1e18 / md.tickSize;
        uint256 minEffTick = _sellFloor(markTick, slippageBps);

        result.markTick = markTick;
        result.minEffTick = minEffTick;
        result.remainingQty = sharesIn;

        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        bytes32 conditionId;
        uint256 otherIdx = outcomeId == 0 ? 1 : 0;

        for (uint256 step = 0; step < MAX_TAKE_STEPS && result.remainingQty > 0; step++) {
            uint256 sameBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
            uint256 otherAsk = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.SELL);

            if (sameBid == 0 && otherAsk == 0) break;

            // Net taker tick per path (higher = better payout for taker).
            uint256 normalTick = sameBid == 0
                ? 0
                : (sameBid * (LibFeeCalculatorService.BPS_DENOMINATOR - totalFeeBps))
                  / LibFeeCalculatorService.BPS_DENOMINATOR;

            uint256 feeTicksOnNotional = (fullTicks * totalFeeBps)
                / LibFeeCalculatorService.BPS_DENOMINATOR;
            uint256 mergeGross = (otherAsk == 0 || otherAsk >= fullTicks) ? 0 : fullTicks - otherAsk;
            uint256 mergeTick = mergeGross > feeTicksOnNotional ? mergeGross - feeTicksOnNotional : 0;

            bool useNormal = normalTick >= mergeTick;
            uint256 chosenTick = useNormal ? normalTick : mergeTick;
            if (chosenTick == 0 || chosenTick < minEffTick) break;

            if (useNormal) {
                if (!_takeNormalSellStep(marketId, outcomeId, sameBid, taker, fees, md, result)) break;
            } else {
                if (conditionId == bytes32(0)) conditionId = _conditionId(marketId);
                if (!_takeMergeSellStep(marketId, outcomeId, otherAsk, otherIdx, conditionId, taker, fees, md, result)) break;
            }
        }
    }

    function _takeNormalSellStep(
        uint256 marketId,
        uint256 outcomeId,
        uint256 sameBid,
        address taker,
        MarketFees memory fees,
        MarketTradingData storage md,
        TakeSellResult memory result
    ) private returns (bool) {
        uint256 makerHead = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.BUY, sameBid).headOrderId;
        if (makerHead == 0) return false;

        bool stillExpired = true;
        for (uint256 r = 0; r < MAX_EXPIRY_RETRIES && stillExpired; r++) {
            stillExpired = LibOrderExpiryService.expireOrderInline(makerHead, md);
            if (stillExpired) {
                uint256 freshBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
                if (freshBid != sameBid || freshBid == 0) return true;
                makerHead = LibOrderBookStorage.getTickLevel(marketId, outcomeId, Side.BUY, freshBid).headOrderId;
                if (makerHead == 0) return false;
            }
        }
        if (stillExpired) return false;

        LibNormalFillService.MarketFillResult memory fr = LibNormalFillService.executeMarketTakerSell(
            LibNormalFillService.MarketTakerSellParams({
                marketId: marketId,
                outcomeId: outcomeId,
                makerBuyOrderId: makerHead,
                bidTick: sameBid,
                taker: taker,
                remainingQty: result.remainingQty
            }),
            fees,
            md
        );
        if (fr.fillQty == 0) return false;

        // For the normal-sell path the executeMarketTakerSell primitive packs
        // the share count into `collateralConsumed`. Track gross/net proceeds
        // here at the take-service level using the bid tick + fee math, to
        // keep the primitive's return shape uniform across paths.
        uint256 gross = (fr.fillQty * sameBid * md.tickSize) / 1e18;
        uint256 net = _normalSellNet(gross, fees);

        result.soldQty += fr.fillQty;
        result.remainingQty -= fr.fillQty;
        result.grossProceeds += gross;
        result.netProceeds += net;
        result.fillCount += 1;
        return true;
    }

    function _normalSellNet(uint256 gross, MarketFees memory fees) private pure returns (uint256) {
        uint256 totalFee = (gross * LibFeeCalculatorService.getTotalFeeBps(fees))
            / LibFeeCalculatorService.BPS_DENOMINATOR;
        return gross > totalFee ? gross - totalFee : 0;
    }

    function _takeMergeSellStep(
        uint256 marketId,
        uint256 outcomeId,
        uint256 otherAsk,
        uint256 otherIdx,
        bytes32 conditionId,
        address taker,
        MarketFees memory fees,
        MarketTradingData storage md,
        TakeSellResult memory result
    ) private returns (bool) {
        uint256 makerHead = LibOrderBookStorage.getTickLevel(marketId, otherIdx, Side.SELL, otherAsk).headOrderId;
        if (makerHead == 0) return false;

        bool stillExpired = true;
        for (uint256 r = 0; r < MAX_EXPIRY_RETRIES && stillExpired; r++) {
            stillExpired = LibOrderExpiryService.expireOrderInline(makerHead, md);
            if (stillExpired) {
                uint256 freshAsk = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.SELL);
                if (freshAsk != otherAsk || freshAsk == 0) return true;
                makerHead = LibOrderBookStorage.getTickLevel(marketId, otherIdx, Side.SELL, freshAsk).headOrderId;
                if (makerHead == 0) return false;
            }
        }
        if (stillExpired) return false;

        LibMergeFillService.MarketFillResult memory fr = LibMergeFillService.executeMarketTakerMerge(
            LibMergeFillService.MarketTakerMergeParams({
                marketId: marketId,
                conditionId: conditionId,
                outcomeId: outcomeId,
                oppositeMakerSellOrderId: makerHead,
                oppositeAskTick: otherAsk,
                taker: taker,
                remainingQty: result.remainingQty
            }),
            fees,
            md
        );
        if (fr.fillQty == 0) return false;

        result.soldQty += fr.fillQty;
        result.remainingQty -= fr.fillQty;
        result.grossProceeds += fr.grossProceeds;
        result.netProceeds += fr.netProceeds;
        result.fillCount += 1;
        return true;
    }
}
