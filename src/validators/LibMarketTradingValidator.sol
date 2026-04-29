// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";

/**
 * @title LibMarketTradingValidator
 * @notice Market trading validation logic. Only reads storage — no mutations.
 */
library LibMarketTradingValidator {
    error MarketPaused();

    function requireMarketNotPaused(uint256 marketId) internal view {
        if (LibMarketTradingStorage.marketIsPaused(marketId)) revert MarketPaused();
    }
}
