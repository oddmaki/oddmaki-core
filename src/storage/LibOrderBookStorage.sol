// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Side, TickLevel, TickList, TickNode} from "../interfaces/Types.sol";

/**
 * @title LibOrderBookStorage
 * @notice Order book domain storage: tick levels, top of book, active tick list, tick nodes.
 * Read-only accessors here; writes (enqueue, dequeue, recordFill, top/active updates) in LibOrderBookAggregate.
 */
library LibOrderBookStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.orderbook");

    struct Storage {
        // marketId => outcomeId => side => tick => TickLevel
        mapping(uint256 => mapping(uint256 => mapping(Side => mapping(uint256 => TickLevel)))) tickLevels;
        // marketId => outcomeId => side => bestTick
        mapping(uint256 => mapping(uint256 => mapping(Side => uint256))) topOfBook;
        // marketId => outcomeId => side => TickList
        mapping(uint256 => mapping(uint256 => mapping(Side => TickList))) activeTicks;
        // marketId => outcomeId => side => tick => TickNode
        mapping(uint256 => mapping(uint256 => mapping(Side => mapping(uint256 => TickNode)))) tickNodes;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    // -------------------------------------------------------------------------
    // Read-only accessors
    // -------------------------------------------------------------------------

    function getTickLevel(uint256 marketId, uint256 outcomeId, Side side, uint256 tick)
        internal
        view
        returns (TickLevel storage)
    {
        return getStorage().tickLevels[marketId][outcomeId][side][tick];
    }

    function getTopOfBook(uint256 marketId, uint256 outcomeId, Side side) internal view returns (uint256) {
        return getStorage().topOfBook[marketId][outcomeId][side];
    }

    function getActiveTickList(uint256 marketId, uint256 outcomeId, Side side)
        internal
        view
        returns (TickList storage)
    {
        return getStorage().activeTicks[marketId][outcomeId][side];
    }

    function getTickNode(uint256 marketId, uint256 outcomeId, Side side, uint256 tick)
        internal
        view
        returns (TickNode storage)
    {
        return getStorage().tickNodes[marketId][outcomeId][side][tick];
    }

    /// @notice Next best tick after emptyTick (O(1) via linked list). Returns 0 if none.
    function findNextBestTick(uint256 marketId, uint256 outcomeId, Side side, uint256 emptyTick)
        internal
        view
        returns (uint256)
    {
        return getTickNode(marketId, outcomeId, side, emptyTick).nextTick;
    }
}
