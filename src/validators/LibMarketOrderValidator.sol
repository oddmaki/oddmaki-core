// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";

/**
 * @title LibMarketOrderValidator
 * @notice Validation logic + errors for the MarketOrdersFacet. Only reads
 *         storage — no mutations.
 */
library LibMarketOrderValidator {
    // ---- Constants ----
    uint256 constant MAX_ITERATIONS = 50;
    uint256 constant MAX_EXPIRY_RETRIES = 10;

    // ---- Errors: market state ----
    error MarketNotActive();

    // ---- Errors: input validation ----
    error ZeroCollateralAmount();
    error InvalidOutcome();
    error ZeroTokenAmount();

    // ---- Errors: execution ----
    error InsufficientLiquidityForFOK();
    error NoLiquidityAvailable();

    // ---- Precondition checks ----

    /// @notice Market must be active for trading.
    function requireActiveMarket(uint256 marketId) internal view {
        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
    }

    /// @notice Binary-market outcome id check (0 or 1).
    function validateOutcomeId(uint256 outcomeId) internal pure {
        if (outcomeId > 1) revert InvalidOutcome();
    }
}
