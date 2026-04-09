// SPDX-License-Identifier: MIT
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

        Order storage yesOrder = LibOrderStorage.getOrder(yesHead);
        Order storage noOrder  = LibOrderStorage.getOrder(noHead);

        uint256 qty = yesOrder.qty < noOrder.qty ? yesOrder.qty : noOrder.qty;

        // Merge the Diamond's pooled outcome tokens to release collateral
        LibVaultPositionService.mergePositions(address(md.collateralToken), conditionId, qty);

        // Pay each seller: maker gets full ask payout, taker pays all fees
        uint256 yesCollateral = (qty * yesAsk * md.tickSize) / 1e18;
        uint256 noCollateral  = (qty * noAsk  * md.tickSize) / 1e18;

        // Fee calculation: fee base is qty (notional = 1.0 per token set)
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(qty, fees);
        uint256 feeTotal = breakdown.totalFee + breakdown.remainder;

        // Maker/taker payout (must happen before order deletion which zeroes owner)
        {
            bool yesIsTaker = (yesHead > noHead);
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
        LibOrderBookAggregate.recordFillOnBook(marketId, 0, Side.SELL, yesAsk, qty);
        uint256 newYesQty = LibOrderAggregate.reduceOrderQty(yesHead, qty);
        if (newYesQty == 0) {
            LibOrderBookService.dequeueOrder(yesHead);
            LibOrderAggregate.deleteOrder(yesHead);
        }

        // Update NO order
        LibOrderBookAggregate.recordFillOnBook(marketId, 1, Side.SELL, noAsk, qty);
        uint256 newNoQty = LibOrderAggregate.reduceOrderQty(noHead, qty);
        if (newNoQty == 0) {
            LibOrderBookService.dequeueOrder(noHead);
            LibOrderAggregate.deleteOrder(noHead);
        }

        // Volume NOT recorded: merge-to-fill is sellers exiting, not buyers acquiring

        // Record fill
        uint256 fillId = LibFillAggregate.recordFill(
            marketId, SettlementPath.MERGE, yesHead, noHead, qty, yesAsk
        );

        // Distribute fees from remaining collateral after seller payouts (no-op if fees are zero)
        LibFeeDistributionService.distributeFees(
            address(md.collateralToken), breakdown, fees, marketId, fillId
        );

        // Route surplus collateral (rounding dust from tick-price discretization) to protocol treasury
        uint256 totalConsumed = yesCollateral + noCollateral + feeTotal;
        if (qty > totalConsumed) {
            uint256 surplus = qty - totalConsumed;
            if (fees.protocolTreasury != address(0)) {
                LibVaultCollateralService.transferCollateral(address(md.collateralToken), fees.protocolTreasury, surplus);
                emit SurplusRouted(marketId, fillId, surplus);
            }
        }

        emit MergeFill(marketId, qty, yesHead, noHead, yesAsk, noAsk);
        return true;
        } // end retry loop
        return false;
    }
}
