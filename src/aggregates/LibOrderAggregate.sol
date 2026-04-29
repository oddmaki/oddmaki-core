// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {Order, Side} from "../interfaces/Types.sol";

/**
 * @title LibOrderAggregate
 * @notice Order domain writes. All order mutations go through here; no external orderId for creation.
 * - createOrder: allocates id internally, validates, stores, returns Order (single creation path).
 * - reduceOrderQty: partial fills (clearing).
 * - updateOrderQueuePointers: order book enqueue/dequeue (next/prev links).
 * - deleteOrder: remove order (cancel, expire, or fully filled).
 * Read-only access via LibOrderStorage.
 */
library LibOrderAggregate {
    event OrderCreated(uint256 indexed orderId, address indexed owner, uint256 marketId);
    event OrderDeleted(uint256 indexed orderId);

    // -------------------------------------------------------------------------
    // Creation (single path; orderId is always allocated inside)
    // -------------------------------------------------------------------------

    /// @notice Create a new order. Allocates orderId internally; caller never passes orderId.
    /// @return newOrder The created order (includes orderId as newOrder.id).
    function createOrder(
        address owner,
        uint256 qty,
        uint256 tick,
        Side side,
        uint256 outcomeId,
        uint256 marketId,
        uint256 expiry,
        uint256 tickSize
    ) internal returns (Order memory newOrder) {
        _validateOrderParams(outcomeId, tick, qty, expiry, tickSize);

        uint256 orderId = _allocateOrderId();

        newOrder = Order({
            id: orderId,
            owner: owner,
            qty: qty,
            originalQty: qty,
            tick: tick,
            side: side,
            outcomeId: outcomeId,
            marketId: marketId,
            expiry: expiry,
            salt: uint256(keccak256(abi.encodePacked(owner, block.timestamp, orderId))),
            nextOrderId: 0,
            prevOrderId: 0
        });

        LibOrderStorage.getStorage().orders[orderId] = newOrder;

        emit OrderCreated(orderId, owner, marketId);

        return newOrder;
    }

    /// @notice Reduce remaining qty (e.g. after a fill). Caller must dequeue/delete when qty becomes 0.
    /// @return newQty Remaining qty after reduction.
    function reduceOrderQty(uint256 orderId, uint256 amount) internal returns (uint256 newQty) {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");
        require(order.qty >= amount, "Insufficient order qty");
        order.qty -= amount;
        return order.qty;
    }

    /// @notice Set only the next pointer for an order (FIFO forward link).
    function setNextOrderId(uint256 orderId, uint256 nextId) internal {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");
        order.nextOrderId = nextId;
    }

    /// @notice Set only the prev pointer for an order (FIFO backward link).
    function setPrevOrderId(uint256 orderId, uint256 prevId) internal {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");
        order.prevOrderId = prevId;
    }

    /// @notice Remove order from storage (cancel, expire, or fully filled). Emits OrderDeleted.
    function deleteOrder(uint256 orderId) internal {
        require(LibOrderStorage.orderExists(orderId), "Order not found");
        delete LibOrderStorage.getStorage().orders[orderId];
        emit OrderDeleted(orderId);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _allocateOrderId() private returns (uint256 orderId) {
        LibOrderStorage.Storage storage s = LibOrderStorage.getStorage();
        orderId = s.nextOrderId;
        if (orderId == 0) {
            orderId = 1;
            s.nextOrderId = 2;
        } else {
            require(orderId != type(uint256).max, "OrderId overflow");
            s.nextOrderId = orderId + 1;
        }
        return orderId;
    }

    function _validateOrderParams(
        uint256 outcomeId,
        uint256 tick,
        uint256 qty,
        uint256 expiry,
        uint256 tickSize
    ) private view {
        if (outcomeId > 1) revert InvalidOutcome();
        if (qty == 0) revert InvalidQuantity();

        uint256 maxTick = 1e18 / tickSize;
        if (tick == 0 || tick > maxTick) revert InvalidTick();

        if (expiry != 0 && expiry <= block.timestamp) revert OrderExpired();

        // M-6/L-1: Prevent dust orders that round to zero collateral value.
        // tick * qty * tickSize / 1e18 must be >= 1 (at least 1 unit of collateral).
        if (tick * qty * tickSize < 1e18) revert OrderTooSmall();
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InvalidOutcome();
    error InvalidQuantity();
    error InvalidTick();
    error OrderExpired();
    error OrderTooSmall();
}
