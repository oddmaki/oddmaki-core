// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

/**
 * @title LibAccessControlStorage
 * @notice Diamond storage for access control: market-level trading AC overrides.
 */
library LibAccessControlStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.accesscontrol");

    struct Storage {
        mapping(uint256 => address) marketTradingAC; // marketId -> AC contract override
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getMarketTradingAC(uint256 marketId) internal view returns (address) {
        return getStorage().marketTradingAC[marketId];
    }

    function setMarketTradingAC(uint256 marketId, address acContract) internal {
        getStorage().marketTradingAC[marketId] = acContract;
    }
}
