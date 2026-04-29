// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibOrderBookStorage} from "../storage/LibOrderBookStorage.sol";
import {Side, TickLevel, TickList, TickNode} from "../interfaces/Types.sol";

/**
 * @title LibOrderBookAggregate
 * @notice Own-storage-only mutations for the OrderBook domain (LibOrderBookStorage).
 *         Manages tick levels, active tick lists, and top-of-book tracking.
 *         Cross-domain coordination (order pointer linking) lives in LibOrderBookService.
 */
library LibOrderBookAggregate {
    event TopOfBookChanged(uint256 indexed marketId, uint256 indexed outcomeId, Side side, uint256 bestTick);

    // -------------------------------------------------------------------------
    // Public write API
    // -------------------------------------------------------------------------

    /// @notice Add an order to its tick level. Returns old tail so caller can link FIFO pointers.
    /// @return oldTailOrderId Previous tail order ID (0 if level was empty).
    function addOrderToLevel(
        uint256 marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256 orderId,
        uint256 orderQty
    ) internal returns (uint256 oldTailOrderId) {
        TickLevel storage level = LibOrderBookStorage.getTickLevel(marketId, outcomeId, side, tick);

        if (level.depth == 0) {
            _addActiveTickToList(marketId, outcomeId, side, tick);
        }

        oldTailOrderId = level.tailOrderId;

        if (oldTailOrderId == 0) {
            level.headOrderId = orderId;
        }
        level.tailOrderId = orderId;

        level.depth++;
        level.totalQty += orderQty;

        _updateTopOfBook(marketId, outcomeId, side, tick);
    }

    /// @notice Remove an order from its tick level. Caller provides pointer info read from Order storage.
    function removeOrderFromLevel(
        uint256 marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256, /* orderId */
        uint256 orderQty,
        uint256 prevOrderId,
        uint256 nextOrderId
    ) internal {
        TickLevel storage level = LibOrderBookStorage.getTickLevel(marketId, outcomeId, side, tick);

        if (prevOrderId == 0) {
            level.headOrderId = nextOrderId;
        }

        if (nextOrderId == 0) {
            level.tailOrderId = prevOrderId;
        }

        level.depth--;
        level.totalQty -= orderQty;

        if (level.depth == 0) {
            _updateTopOfBookAfterRemoval(marketId, outcomeId, side, tick);
            _removeActiveTickFromList(marketId, outcomeId, side, tick);
        }
    }

    /// @notice Decrease level totalQty after a fill (partial or full). Does not dequeue.
    function recordFillOnBook(uint256 marketId, uint256 outcomeId, Side side, uint256 tick, uint256 filledQty)
        internal
    {
        TickLevel storage level = LibOrderBookStorage.getTickLevel(marketId, outcomeId, side, tick);
        level.totalQty -= filledQty;
    }

    // -------------------------------------------------------------------------
    // Top of book
    // -------------------------------------------------------------------------

    function _updateTopOfBook(uint256 marketId, uint256 outcomeId, Side side, uint256 tick) private {
        uint256 currentBest = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, side);
        bool shouldUpdate = false;

        if (currentBest == 0) {
            shouldUpdate = true;
        } else if (side == Side.BUY && tick > currentBest) {
            shouldUpdate = true;
        } else if (side == Side.SELL && tick < currentBest) {
            shouldUpdate = true;
        }

        if (shouldUpdate) {
            LibOrderBookStorage.getStorage().topOfBook[marketId][outcomeId][side] = tick;
            emit TopOfBookChanged(marketId, outcomeId, side, tick);
        }
    }

    function _updateTopOfBookAfterRemoval(uint256 marketId, uint256 outcomeId, Side side, uint256 removedTick)
        private
    {
        uint256 currentBest = LibOrderBookStorage.getTopOfBook(marketId, outcomeId, side);

        if (currentBest == removedTick) {
            uint256 newBest = LibOrderBookStorage.findNextBestTick(marketId, outcomeId, side, removedTick);
            LibOrderBookStorage.getStorage().topOfBook[marketId][outcomeId][side] = newBest;
            emit TopOfBookChanged(marketId, outcomeId, side, newBest);
        }
    }

    // -------------------------------------------------------------------------
    // Active tick list (sorted: BUY = highest first, SELL = lowest first)
    // -------------------------------------------------------------------------

    function _addActiveTickToList(uint256 marketId, uint256 outcomeId, Side side, uint256 tick) private {
        TickList storage list = LibOrderBookStorage.getActiveTickList(marketId, outcomeId, side);
        TickNode storage node = LibOrderBookStorage.getTickNode(marketId, outcomeId, side, tick);

        if (node.active) return;

        node.active = true;

        if (list.head == 0) {
            list.head = tick;
            list.tail = tick;
            return;
        }

        if (side == Side.BUY) {
            if (tick > list.head) {
                node.nextTick = list.head;
                LibOrderBookStorage.getTickNode(marketId, outcomeId, side, list.head).prevTick = tick;
                list.head = tick;
                return;
            }
            if (tick < list.tail) {
                node.prevTick = list.tail;
                LibOrderBookStorage.getTickNode(marketId, outcomeId, side, list.tail).nextTick = tick;
                list.tail = tick;
                return;
            }
            uint256 current = list.head;
            while (current != 0) {
                uint256 next = LibOrderBookStorage.getTickNode(marketId, outcomeId, side, current).nextTick;
                if (next == 0 || tick > next) {
                    node.prevTick = current;
                    node.nextTick = next;
                    LibOrderBookStorage.getTickNode(marketId, outcomeId, side, current).nextTick = tick;
                    if (next != 0) {
                        LibOrderBookStorage.getTickNode(marketId, outcomeId, side, next).prevTick = tick;
                    } else {
                        list.tail = tick;
                    }
                    break;
                }
                current = next;
            }
        } else {
            if (tick < list.head) {
                node.nextTick = list.head;
                LibOrderBookStorage.getTickNode(marketId, outcomeId, side, list.head).prevTick = tick;
                list.head = tick;
                return;
            }
            if (tick > list.tail) {
                node.prevTick = list.tail;
                LibOrderBookStorage.getTickNode(marketId, outcomeId, side, list.tail).nextTick = tick;
                list.tail = tick;
                return;
            }
            uint256 current = list.head;
            while (current != 0) {
                uint256 next = LibOrderBookStorage.getTickNode(marketId, outcomeId, side, current).nextTick;
                if (next == 0 || tick < next) {
                    node.prevTick = current;
                    node.nextTick = next;
                    LibOrderBookStorage.getTickNode(marketId, outcomeId, side, current).nextTick = tick;
                    if (next != 0) {
                        LibOrderBookStorage.getTickNode(marketId, outcomeId, side, next).prevTick = tick;
                    } else {
                        list.tail = tick;
                    }
                    break;
                }
                current = next;
            }
        }
    }

    function _removeActiveTickFromList(uint256 marketId, uint256 outcomeId, Side side, uint256 tick) private {
        TickList storage list = LibOrderBookStorage.getActiveTickList(marketId, outcomeId, side);
        TickNode storage node = LibOrderBookStorage.getTickNode(marketId, outcomeId, side, tick);

        if (!node.active) return;

        if (node.prevTick != 0) {
            LibOrderBookStorage.getTickNode(marketId, outcomeId, side, node.prevTick).nextTick = node.nextTick;
        } else {
            list.head = node.nextTick;
        }

        if (node.nextTick != 0) {
            LibOrderBookStorage.getTickNode(marketId, outcomeId, side, node.nextTick).prevTick = node.prevTick;
        } else {
            list.tail = node.prevTick;
        }

        delete LibOrderBookStorage.getStorage().tickNodes[marketId][outcomeId][side][tick];
    }
}
