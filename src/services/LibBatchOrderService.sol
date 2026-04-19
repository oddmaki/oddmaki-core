// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {LibErc1155ReceiverValidator} from "../validators/LibErc1155ReceiverValidator.sol";
import {MarketTradingData, Order, Side} from "../interfaces/Types.sol";
import {BatchOrderParams} from "../interfaces/IBatchOrders.sol";

/**
 * @title LibBatchOrderService
 * @notice Gas-optimized batch order placement: validates market once, aggregates token
 *         transfers, then creates and enqueues each order individually.
 */
library LibBatchOrderService {
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256 qty,
        address indexed owner
    );

    function batchPlaceOrders(
        address user,
        uint256 marketId,
        BatchOrderParams[] calldata orders
    ) internal returns (uint256[] memory orderIds) {
        MarketTradingData memory config = LibMarketTradingStorage.getMarketTradingData(marketId);
        require(config.active, "Market not active");

        uint256 len = orders.length;
        orderIds = new uint256[](len);

        // Phase 1: Compute aggregated deposit amounts
        uint256 totalBuyCollateral;
        uint256 totalSellYes;
        uint256 totalSellNo;

        for (uint256 i; i < len; i++) {
            if (orders[i].side == Side.BUY) {
                totalBuyCollateral += (orders[i].tick * orders[i].qty * config.tickSize) / 1e18;
            } else {
                if (orders[i].outcomeId == 0) {
                    totalSellYes += orders[i].qty;
                } else {
                    totalSellNo += orders[i].qty;
                }
            }
        }

        // Phase 2: Aggregated transfers (max 3 instead of N)
        if (totalBuyCollateral > 0) {
            LibVaultCollateralService.depositCollateral(address(config.collateralToken), user, totalBuyCollateral);
        }
        if (totalSellYes > 0 || totalSellNo > 0) {
            // H-05: reject contract makers that cannot receive refunded outcome tokens.
            LibErc1155ReceiverValidator.requireCanReceiveErc1155(user);
        }
        if (totalSellYes > 0) {
            LibVaultOutcomeTokenService.depositOutcomeTokens(config.positionIds[0], user, totalSellYes);
        }
        if (totalSellNo > 0) {
            LibVaultOutcomeTokenService.depositOutcomeTokens(config.positionIds[1], user, totalSellNo);
        }

        // Phase 3: Create orders and enqueue on orderbook
        for (uint256 i; i < len; i++) {
            Order memory order = LibOrderAggregate.createOrder(
                user,
                orders[i].qty,
                orders[i].tick,
                orders[i].side,
                orders[i].outcomeId,
                marketId,
                orders[i].expiry,
                config.tickSize
            );
            orderIds[i] = order.id;

            LibOrderBookService.enqueueOrder(order.id);

            emit OrderPlaced(
                order.id,
                marketId,
                orders[i].outcomeId,
                orders[i].side,
                orders[i].tick,
                orders[i].qty,
                user
            );
        }
    }
}
