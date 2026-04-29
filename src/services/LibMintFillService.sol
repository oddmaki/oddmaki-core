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

        Order storage yesOrder = LibOrderStorage.getOrder(yesHead);
        Order storage noOrder  = LibOrderStorage.getOrder(noHead);

        uint256 qty = yesOrder.qty < noOrder.qty ? yesOrder.qty : noOrder.qty;

        // Split the Diamond's pooled collateral to mint YES + NO tokens (delivered to Diamond)
        LibVaultPositionService.splitPosition(address(md.collateralToken), conditionId, qty);

        // Deliver tokens to each buyer
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[0], yesOrder.owner, qty);
        LibVaultOutcomeTokenService.transferOutcomeTokens(md.positionIds[1], noOrder.owner, qty);

        // Update YES order; always decrement totalQty first, then dequeue/delete fully-filled orders
        LibOrderBookAggregate.recordFillOnBook(marketId, 0, Side.BUY, yesBid, qty);
        uint256 newYesQty = LibOrderAggregate.reduceOrderQty(yesHead, qty);
        if (newYesQty == 0) {
            LibOrderBookService.dequeueOrder(yesHead);
            LibOrderAggregate.deleteOrder(yesHead);
        }

        // Update NO order
        LibOrderBookAggregate.recordFillOnBook(marketId, 1, Side.BUY, noBid, qty);
        uint256 newNoQty = LibOrderAggregate.reduceOrderQty(noHead, qty);
        if (newNoQty == 0) {
            LibOrderBookService.dequeueOrder(noHead);
            LibOrderAggregate.deleteOrder(noHead);
        }

        // Record volume for both outcomes (both buyers are acquiring)
        uint256 yesCollateral = (qty * yesBid * md.tickSize) / 1e18;
        uint256 noCollateral  = (qty * noBid  * md.tickSize) / 1e18;
        LibMarketTradingAggregate.recordTotalVolume(marketId, 0, yesCollateral);
        LibMarketTradingAggregate.recordTotalVolume(marketId, 1, noCollateral);

        // Record last trade tick for both outcomes (both buyers are acquiring at their bid prices)
        LibMarketTradingAggregate.recordLastTradeTick(marketId, 0, yesBid);
        LibMarketTradingAggregate.recordLastTradeTick(marketId, 1, noBid);

        // Fee calculation: fee base is qty (notional = 1.0 per token set)
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(qty, fees);

        // Record fill
        uint256 fillId = LibFillAggregate.recordFill(
            marketId, SettlementPath.MINT, yesHead, noHead, qty, yesBid
        );

        // Distribute fees from surplus collateral (no-op if fees are zero)
        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, marketId, fillId
        );

        // Route surplus collateral (rounding dust from tick-price discretization) to protocol treasury
        uint256 totalDeposited = yesCollateral + noCollateral;
        uint256 totalConsumed = qty + breakdown.totalFee + breakdown.remainder;
        if (totalDeposited > totalConsumed) {
            uint256 surplus = totalDeposited - totalConsumed;
            if (fees.protocolTreasury != address(0)) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), fees.protocolTreasury, surplus);
                emit SurplusRouted(marketId, fillId, surplus);
            }
        }

        emit MintFill(marketId, qty, yesHead, noHead, yesBid, noBid);
        emit TradeExecuted(marketId, 0, fillId, yesBid, qty, md.totalVolume[0], block.timestamp);
        emit TradeExecuted(marketId, 1, fillId, noBid, qty, md.totalVolume[1], block.timestamp);
        return true;
        } // end retry loop
        return false;
    }
}
