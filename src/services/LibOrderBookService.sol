// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookAggregate} from "../aggregates/LibOrderBookAggregate.sol";
import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {Order, Side} from "../interfaces/Types.sol";

/**
 * @title LibOrderBookService
 * @notice Cross-domain coordination for order book enqueue/dequeue.
 *         Reads Order data, delegates tick-level management to LibOrderBookAggregate,
 *         and links FIFO pointers via LibOrderAggregate.
 */
library LibOrderBookService {
    /// @notice Add an order to the book at its tick, linking FIFO pointers.
    function enqueueOrder(uint256 orderId) internal {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");

        uint256 oldTailOrderId = LibOrderBookAggregate.addOrderToLevel(
            order.marketId, order.outcomeId, order.side, order.tick, orderId, order.qty
        );

        // Link FIFO pointers if level had existing orders
        if (oldTailOrderId != 0) {
            LibOrderAggregate.setNextOrderId(oldTailOrderId, orderId);
            LibOrderAggregate.setPrevOrderId(orderId, oldTailOrderId);
        }
    }

    /// @notice Remove an order from the book, re-linking neighbor pointers.
    function dequeueOrder(uint256 orderId) internal {
        Order storage order = LibOrderStorage.getOrder(orderId);
        require(order.id != 0, "Order not found");

        uint256 prevId = order.prevOrderId;
        uint256 nextId = order.nextOrderId;

        LibOrderBookAggregate.removeOrderFromLevel(
            order.marketId, order.outcomeId, order.side, order.tick,
            orderId, order.qty, prevId, nextId
        );

        // Re-link neighbor pointers
        if (prevId != 0) {
            LibOrderAggregate.setNextOrderId(prevId, nextId);
        }
        if (nextId != 0) {
            LibOrderAggregate.setPrevOrderId(nextId, prevId);
        }
    }
}
