// SPDX-License-Identifier: MIT
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
