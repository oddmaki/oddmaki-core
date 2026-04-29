// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibBatchOrderService} from "../services/LibBatchOrderService.sol";
import {LibOrderCancellationService} from "../services/LibOrderCancellationService.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {BatchOrderParams} from "../interfaces/IBatchOrders.sol";
import {Side} from "../interfaces/Types.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title BatchOrdersFacet
 * @author OddMaki Protocol
 * @notice Batch order management: place, cancel, and cancel-and-replace multiple
 *         limit orders atomically in a single transaction.
 */
contract BatchOrdersFacet is ReentrancyGuard {
    error MarketNotActive();
    error BatchTooLarge();
    error EmptyBatch();

    uint256 constant MAX_BATCH_PLACE = 20;
    uint256 constant MAX_BATCH_CANCEL = 100;

    /**
     * @notice Place multiple limit orders on the same market atomically.
     * @param marketId  The market (must be active, unpaused, venue active).
     * @param orders    Array of order parameters (max 20).
     * @return orderIds Array of allocated order IDs (same length and order as input).
     */
    function batchPlaceOrders(
        uint256 marketId,
        BatchOrderParams[] calldata orders
    ) external nonReentrant returns (uint256[] memory orderIds) {
        uint256 len = orders.length;
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_PLACE) revert BatchTooLarge();

        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);

        orderIds = LibBatchOrderService.batchPlaceOrders(msg.sender, marketId, orders);
    }

    /**
     * @notice Cancel multiple orders atomically. Orders can span markets.
     * @param orderIds Array of order IDs to cancel (max 100). Must be owned by msg.sender.
     * @return cancelledCount Number of orders cancelled.
     */
    function batchCancelOrders(
        uint256[] calldata orderIds
    ) external nonReentrant returns (uint256 cancelledCount) {
        uint256 len = orderIds.length;
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_CANCEL) revert BatchTooLarge();

        for (uint256 i; i < len; i++) {
            LibOrderCancellationService.cancelOrder(msg.sender, orderIds[i]);
            cancelledCount++;
        }
    }

    /**
     * @notice Atomically cancel stale orders then place new ones on the same market.
     * @param marketId       The market for new orders.
     * @param cancelOrderIds Orders to cancel (max 100). Must be owned by msg.sender.
     * @param newOrders      New orders to place (max 20).
     * @return cancelledCount Number of orders cancelled.
     * @return newOrderIds    Array of allocated order IDs for the new orders.
     */
    function cancelAndReplace(
        uint256 marketId,
        uint256[] calldata cancelOrderIds,
        BatchOrderParams[] calldata newOrders
    ) external nonReentrant returns (uint256 cancelledCount, uint256[] memory newOrderIds) {
        if (cancelOrderIds.length > MAX_BATCH_CANCEL) revert BatchTooLarge();
        if (newOrders.length > MAX_BATCH_PLACE) revert BatchTooLarge();
        if (cancelOrderIds.length == 0 && newOrders.length == 0) revert EmptyBatch();

        // Phase 1: Cancel existing orders
        for (uint256 i; i < cancelOrderIds.length; i++) {
            LibOrderCancellationService.cancelOrder(msg.sender, cancelOrderIds[i]);
            cancelledCount++;
        }

        // Phase 2: Place new orders
        if (newOrders.length > 0) {
            if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
            LibMarketTradingValidator.requireMarketNotPaused(marketId);
            LibVenueValidator.requireActiveVenueForMarket(marketId);
            LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);

            newOrderIds = LibBatchOrderService.batchPlaceOrders(msg.sender, marketId, newOrders);
        } else {
            newOrderIds = new uint256[](0);
        }
    }
}
