// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {Order, Side, MarketTradingData} from "../interfaces/Types.sol";

/**
 * @title LibOrderExpiryService
 * @notice Order expiry: batch cleanup (expireOrders) and inline cleanup during matching (expireOrderInline).
 *         Full collateral / outcome-token refund to the order owner; no penalty.
 */
library LibOrderExpiryService {
    uint256 constant MAX_EXPIRE_BATCH = 100;

    error BatchTooLarge();

    event OrderExpired(uint256 indexed orderId, address indexed owner, uint256 qty);

    /**
     * @notice Expire a batch of orders for `marketId`.
     *         Orders that are not expired, belong to a different market, or are already
     *         removed are silently skipped.
     * @param marketId  Market the orders belong to (used for validation + market data lookup).
     * @param orderIds  Caller-supplied list of order IDs to attempt to expire.
     * @return expiredCount Number of orders actually expired and refunded.
     */
    function expireOrders(uint256 marketId, uint256[] calldata orderIds)
        internal
        returns (uint256 expiredCount)
    {
        if (orderIds.length > MAX_EXPIRE_BATCH) revert BatchTooLarge();

        LibOrderStorage.Storage storage os = LibOrderStorage.getStorage();

        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            Order storage order = os.orders[orderId];

            // Skip: not found, wrong market, already removed, or not yet expired
            if (order.id == 0) continue;
            if (order.marketId != marketId) continue;
            if (order.qty == 0) continue;
            if (order.expiry == 0 || order.expiry > block.timestamp) continue;

            // Cache fields we need after deletion
            address owner = order.owner;
            uint256 qty = order.qty;
            Side side = order.side;
            uint256 tick = order.tick;
            uint256 outcomeId = order.outcomeId;

            // Load market data (collateralToken, tickSize, positionIds)
            MarketTradingData memory md = LibMarketTradingStorage.getMarketTradingData(marketId);

            // Refund locked assets to owner
            if (side == Side.BUY) {
                uint256 collateralLocked = (qty * tick * md.tickSize) / 1e18;
                LibVaultCollateralService.withdrawCollateral(address(md.collateralToken), owner, collateralLocked);
            } else {
                LibVaultOutcomeTokenService.withdrawOutcomeTokens(md.positionIds[outcomeId], owner, qty);
            }

            // Remove from order book (reads order storage — must happen before delete)
            LibOrderBookService.dequeueOrder(orderId);

            // Delete order record
            delete os.orders[orderId];

            emit OrderExpired(orderId, owner, qty);
            expiredCount++;
        }
    }

    /**
     * @notice Expire a single order inline during matching.
     *         Called when the FIFO head is found to be past its expiry before a fill is attempted.
     *         Full refund; no penalty. Returns true if the order was expired and removed.
     * @param orderId  Order to check and potentially expire.
     * @param md       Trading data for the order's market (collateralToken, tickSize, positionIds).
     */
    function expireOrderInline(uint256 orderId, MarketTradingData storage md)
        internal
        returns (bool wasExpired)
    {
        Order storage order = LibOrderStorage.getStorage().orders[orderId];

        if (order.id == 0) return false;
        if (order.expiry == 0 || order.expiry > block.timestamp) return false;

        address owner = order.owner;
        uint256 qty = order.qty;
        Side side = order.side;
        uint256 tick = order.tick;
        uint256 outcomeId = order.outcomeId;

        if (side == Side.BUY) {
            uint256 collateralLocked = (qty * tick * md.tickSize) / 1e18;
            LibVaultCollateralService.withdrawCollateral(address(md.collateralToken), owner, collateralLocked);
        } else {
            LibVaultOutcomeTokenService.withdrawOutcomeTokens(md.positionIds[outcomeId], owner, qty);
        }

        LibOrderBookService.dequeueOrder(orderId);
        delete LibOrderStorage.getStorage().orders[orderId];

        emit OrderExpired(orderId, owner, qty);
        return true;
    }
}
