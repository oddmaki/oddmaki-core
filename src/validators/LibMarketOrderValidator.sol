// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";

/**
 * @title LibMarketOrderValidator
 * @notice Market order validation logic and errors. Only reads storage — no mutations.
 *         Used by the MarketOrdersFacet and LibMarketOrderService to enforce invariants.
 */
library LibMarketOrderValidator {
    // ---- Constants ----
    uint256 constant MAX_ITERATIONS = 50;
    uint256 constant MAX_EXPIRY_RETRIES = 10;

    // ---- Errors: market state ----
    error MarketNotActive();

    // ---- Errors: input validation (buy) ----
    error ZeroCollateralAmount();
    error InvalidMaxPrice();
    error InvalidOutcome();

    // ---- Errors: input validation (sell) ----
    error ZeroTokenAmount();
    error InvalidMinPrice();

    // ---- Errors: execution ----
    error InsufficientLiquidityForFOK();
    error NoLiquidityAvailable();

    // ---- Precondition checks ----

    /// @notice Market must be active for trading.
    function requireActiveMarket(uint256 marketId) internal view {
        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
    }

    /// @notice Validate market order input parameters.
    function validateMarketOrderParams(
        uint256 collateralAmount,
        uint256 maxPriceTick,
        uint256 outcomeId
    ) internal pure {
        if (collateralAmount == 0) revert ZeroCollateralAmount();
        if (maxPriceTick == 0) revert InvalidMaxPrice();
        if (outcomeId > 1) revert InvalidOutcome();
    }

    /// @notice Validate market sell order input parameters.
    function validateMarketSellParams(
        uint256 tokenAmount,
        uint256 minPriceTick,
        uint256 outcomeId
    ) internal pure {
        if (tokenAmount == 0) revert ZeroTokenAmount();
        if (minPriceTick == 0) revert InvalidMinPrice();
        if (outcomeId > 1) revert InvalidOutcome();
    }

    /// @notice Standalone outcome-id check (binary markets: 0 or 1).
    function validateOutcomeId(uint256 outcomeId) internal pure {
        if (outcomeId > 1) revert InvalidOutcome();
    }
}
