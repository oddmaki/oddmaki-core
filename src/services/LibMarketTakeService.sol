// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibOrderExpiryService} from "./LibOrderExpiryService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibNormalFillService} from "./LibNormalFillService.sol";
import {LibMintFillService} from "./LibMintFillService.sol";
import {LibMergeFillService} from "./LibMergeFillService.sol";
import {Side, MarketTradingData, MarketFees} from "../interfaces/Types.sol";

/**
 * @title LibMarketTakeService
 * @notice Multi-path market-order execution. Walks both books simultaneously,
 *         picking the cheapest crossable path (normal-fill vs mint-fill for
 *         BUY; normal-fill vs merge-fill for SELL) at each step.
 *
 *         Slippage anchor is the **first-step crossing tick** — i.e. whatever
 *         the cheapest crossable price the loop sees on iteration 0. This
 *         matches Polymarket's "Buy Yes 80¢" semantics: the displayed best
 *         price IS the anchor; tolerance is expressed as a percentage above
 *         it. The anchor is snapshotted on step 0 and held constant for the
 *         rest of the loop, so the cap is locked relative to pre-trade book
 *         state regardless of how deep the user walks.
 *
 *         No mark-price dependency — a market order anchors against the book
 *         it's about to take, not against a midpoint that may or may not be
 *         defined. When the book has any takeable supply on the user's side
 *         (including via mint/merge complement on the opposite outcome), the
 *         take starts. When it doesn't, it reverts cleanly.
 */
library LibMarketTakeService {
    /// @dev Maximum fill iterations per call (per-side step budget).
    uint256 internal constant MAX_TAKE_STEPS = 20;

    /// @dev Maximum inline expiry retries per step before giving up on a head.
    uint256 internal constant MAX_EXPIRY_RETRIES = 5;

    /// @dev Hard cap on user-supplied slippage to avoid degenerate-cap abuse.
    uint256 internal constant MAX_SLIPPAGE_BPS = 2000; // 20%

    error SlippageTooHigh();

    struct TakeBuyResult {
        uint256 filledQty;
        uint256 consumedBudget;
        uint256 remainingBudget;
        uint256 fillCount;
        /// @dev First-step anchor tick (= cheapest crossable on iteration 0).
        ///      Informational, useful for event emission and UI debug.
        uint256 anchorTick;
        /// @dev Slippage cap = anchorTick + ceil(anchorTick × slippageBps / BPS).
        uint256 maxEffTick;
    }

    struct TakeSellResult {
        uint256 soldQty;
        uint256 grossProceeds;
        uint256 netProceeds;
        uint256 remainingQty;
        uint256 fillCount;
        uint256 anchorTick;
        uint256 minEffTick;
    }

    /// @dev Convenience reader for the (questionId → conditionId) link.
    function _conditionId(uint256 marketId) private view returns (bytes32) {
        bytes32 questionId = LibMarketRegistryStorage.getStorage().byMarketId[marketId].questionId;
        return LibMarketOracleStorage.getStorage().byQuestionId[questionId].conditionId;
    }

    /// @dev Upper bound for BUY: maxEffTick = anchor + ceil(anchor × slippageBps / BPS),
    ///      clipped to fullTicks.
    function _buyCap(uint256 anchorTick, uint256 slippageBps, uint256 fullTicks) private pure returns (uint256) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 bump = (anchorTick * slippageBps + BPS - 1) / BPS; // ceil
        uint256 cap = anchorTick + bump;
        return cap > fullTicks ? fullTicks : cap;
    }

    /// @dev Lower bound for SELL: minEffTick = anchor - ceil(anchor × slippageBps / BPS),
    ///      floored at 1 to leave room for fees.
    function _sellFloor(uint256 anchorTick, uint256 slippageBps) private pure returns (uint256) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 drop = (anchorTick * slippageBps + BPS - 1) / BPS;
        return anchorTick > drop ? anchorTick - drop : 1;
    }

    /// @dev Per-step BUY cost calculator: returns the cheapest takeable cost
    ///      in tick units (normal-fill at `sameAsk` with fee bump, or mint-fill
    ///      against `otherBid` with fee on $1 notional). `type(uint256).max`
    ///      means no liquidity on that path.
    function _buyCheapestCost(
        uint256 sameAsk,
        uint256 otherBid,
        uint256 fullTicks,
        uint256 totalFeeBps
    ) private pure returns (uint256 chosenCost, bool useNormal) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 normalCost = sameAsk == 0
            ? type(uint256).max
            : (sameAsk * (BPS + totalFeeBps) + BPS - 1) / BPS;
        uint256 mintCost = (otherBid == 0 || otherBid >= fullTicks)
            ? type(uint256).max
            : (fullTicks - otherBid) + (fullTicks * totalFeeBps + BPS - 1) / BPS;
        useNormal = normalCost <= mintCost;
        chosenCost = useNormal ? normalCost : mintCost;
    }

    /// @dev Per-step SELL tick calculator: returns the highest net taker tick
    ///      (normal-fill at `sameBid` minus taker fee, or merge-fill against
    ///      `otherAsk` with fee on $1 notional). Zero means no liquidity.
    function _sellHighestTick(
        uint256 sameBid,
        uint256 otherAsk,
        uint256 fullTicks,
        uint256 totalFeeBps
    ) private pure returns (uint256 chosenTick, bool useNormal) {
        uint256 BPS = LibFeeCalculatorService.BPS_DENOMINATOR;
        uint256 normalTick = sameBid == 0 ? 0 : (sameBid * (BPS - totalFeeBps)) / BPS;
        uint256 feeTicksOnNotional = (fullTicks * totalFeeBps) / BPS;
        uint256 mergeGross = (otherAsk == 0 || otherAsk >= fullTicks) ? 0 : fullTicks - otherAsk;
        uint256 mergeTick = mergeGross > feeTicksOnNotional ? mergeGross - feeTicksOnNotional : 0;
        useNormal = normalTick >= mergeTick;
        chosenTick = useNormal ? normalTick : mergeTick;
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

        uint256 fullTicks = 1e18 / md.tickSize;
        result.remainingBudget = budget;

        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        bytes32 conditionId; // lazy resolution if we need it for mint
        uint256 otherIdx = outcomeId == 0 ? 1 : 0;
        uint256 maxEffTick;

        for (uint256 step = 0; step < MAX_TAKE_STEPS && result.remainingBudget > 0; step++) {
            uint256 sameAsk = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.SELL);
            uint256 otherBid = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.BUY);

            if (sameAsk == 0 && otherBid == 0) break;

            (uint256 chosenCost, bool useNormal) =
                _buyCheapestCost(sameAsk, otherBid, fullTicks, totalFeeBps);

            if (chosenCost == type(uint256).max) break;

            // First step locks the anchor + slippage cap against the displayed
            // best price. Subsequent steps re-check the cap against the loop's
            // initial snapshot — the user cannot move the cap by self-filling.
            if (step == 0) {
                result.anchorTick = chosenCost;
                maxEffTick = _buyCap(chosenCost, slippageBps, fullTicks);
                result.maxEffTick = maxEffTick;
            }

            if (chosenCost > maxEffTick) break;

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

        uint256 fullTicks = 1e18 / md.tickSize;
        result.remainingQty = sharesIn;

        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        uint256 totalFeeBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        bytes32 conditionId;
        uint256 otherIdx = outcomeId == 0 ? 1 : 0;
        uint256 minEffTick;

        for (uint256 step = 0; step < MAX_TAKE_STEPS && result.remainingQty > 0; step++) {
            uint256 sameBid = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, Side.BUY);
            uint256 otherAsk = LibOrderBookStorage.getTopOfBook(marketId, otherIdx, Side.SELL);

            if (sameBid == 0 && otherAsk == 0) break;

            (uint256 chosenTick, bool useNormal) =
                _sellHighestTick(sameBid, otherAsk, fullTicks, totalFeeBps);

            if (chosenTick == 0) break;

            // First step locks the anchor + slippage floor against the displayed
            // best price the user could sell at right now.
            if (step == 0) {
                result.anchorTick = chosenTick;
                minEffTick = _sellFloor(chosenTick, slippageBps);
                result.minEffTick = minEffTick;
            }

            if (chosenTick < minEffTick) break;

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
