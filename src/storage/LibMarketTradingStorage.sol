// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {MarketTradingData} from "../interfaces/Types.sol";

/**
 * @title LibMarketTradingStorage
 * @notice Market trading (exchange): marketId → MarketTradingData. PositionIds, volume, lastTradeTick, active, tickSize, collateralToken.
 */
library LibMarketTradingStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.market.trading");

    struct Storage {
        mapping(uint256 => MarketTradingData) byMarketId;
        mapping(uint256 => bool) marketPaused;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getMarketTradingData(uint256 marketId) internal view returns (MarketTradingData storage) {
        return getStorage().byMarketId[marketId];
    }

    function marketTradingDataExists(uint256 marketId) internal view returns (bool) {
        return getMarketTradingData(marketId).marketId != 0;
    }

    function marketIsActive(uint256 marketId) internal view returns (bool) {
        return getMarketTradingData(marketId).active;
    }

    function marketIsPaused(uint256 marketId) internal view returns (bool) {
        return getStorage().marketPaused[marketId];
    }
}
