// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {MarketRegistryData} from "../interfaces/Types.sol";

/**
 * @title LibMarketRegistryStorage
 * @notice Market registry (lifecycle): marketId → MarketRegistryData. Allocates marketId; optional reverse index questionId → marketId.
 */
library LibMarketRegistryStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.market.registry");

    struct Storage {
        mapping(uint256 => MarketRegistryData) byMarketId;
        mapping(bytes32 => uint256) marketIdByQuestionId;
        uint256 nextMarketId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getMarketRegistryData(uint256 marketId) internal view returns (MarketRegistryData storage) {
        return getStorage().byMarketId[marketId];
    }

    function getMarketIdByQuestionId(bytes32 questionId) internal view returns (uint256) {
        return getStorage().marketIdByQuestionId[questionId];
    }

    /// @notice Allocate next market id (increment and return). Call before writing Registry.
    function allocateMarketId() internal returns (uint256 marketId) {
        Storage storage s = getStorage();
        marketId = s.nextMarketId + 1;
        s.nextMarketId = marketId;
        return marketId;
    }

    function getNextMarketId() internal view returns (uint256) {
        return getStorage().nextMarketId;
    }

    function marketRegistryDataExists(uint256 marketId) internal view returns (bool) {
        return getMarketRegistryData(marketId).marketId != 0;
    }
}
