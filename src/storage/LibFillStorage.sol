// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Fill} from "../interfaces/Types.sol";

/**
 * @title LibFillStorage
 * @notice Diamond storage for trade execution records (fills). Keyed by fillId.
 */
library LibFillStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.fills");

    struct Storage {
        mapping(uint256 => Fill) fills;
        uint256 nextFillId; // Starts at 0; first fill gets id=1
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getFill(uint256 fillId) internal view returns (Fill storage) {
        return getStorage().fills[fillId];
    }

    function getNextFillId() internal view returns (uint256) {
        return getStorage().nextFillId;
    }
}
