// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {MarketTradingData, Order, Side} from "../interfaces/Types.sol";

/**
 * @title LibOrderCancellationService
 * @notice Saga: cancel a limit order (dequeue, delete order, refund collateral/outcome tokens).
 */
library LibOrderCancellationService {
    event OrderCancelled(uint256 indexed orderId);

    function cancelOrder(address caller, uint256 orderId) internal {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");
        require(order.owner == caller, "Unauthorized cancel");

        uint256 marketId = order.marketId;
        uint256 qty = order.qty;
        if (qty > 0) {
            MarketTradingData memory config = LibMarketTradingStorage.getMarketTradingData(marketId);
            if (order.side == Side.BUY) {
                uint256 collateralAmount = (order.tick * qty * config.tickSize) / 1e18;
                LibVaultCollateralService.withdrawCollateral(address(config.collateralToken), order.owner, collateralAmount);
            } else {
                LibVaultOutcomeTokenService.withdrawOutcomeTokens(config.positionIds[order.outcomeId], order.owner, qty);
            }
        }

        LibOrderBookService.dequeueOrder(orderId);
        LibOrderAggregate.deleteOrder(orderId);

        emit OrderCancelled(orderId);
    }

    /**
     * @notice Cancel a single order on a resolved market. Permissionless — no owner check.
     *         Silently skips already-deleted orders (returns false) to handle race conditions.
     * @param orderId  Order to cancel.
     * @param marketId Expected market (must match order's marketId).
     * @return cancelled True if order was cancelled, false if already deleted.
     */
    function cancelOrderOnResolvedMarket(uint256 orderId, uint256 marketId) internal returns (bool cancelled) {
        Order storage order = LibOrderStorage.getOrder(orderId);
        if (order.id == 0) return false;
        require(order.marketId == marketId, "Order not in market");

        uint256 qty = order.qty;
        if (qty > 0) {
            MarketTradingData memory config = LibMarketTradingStorage.getMarketTradingData(marketId);
            if (order.side == Side.BUY) {
                uint256 collateralAmount = (order.tick * qty * config.tickSize) / 1e18;
                LibVaultCollateralService.withdrawCollateral(address(config.collateralToken), order.owner, collateralAmount);
            } else {
                LibVaultOutcomeTokenService.withdrawOutcomeTokens(config.positionIds[order.outcomeId], order.owner, qty);
            }
        }

        LibOrderBookService.dequeueOrder(orderId);
        LibOrderAggregate.deleteOrder(orderId);

        emit OrderCancelled(orderId);
        return true;
    }
}
