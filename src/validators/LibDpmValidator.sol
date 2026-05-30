// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {DpmMarket, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title LibDpmValidator
 * @notice Read-only guard checks for DPM (Dynamic Pari-Mutuel) market operations.
 *         Errors are defined here, not in services or aggregates.
 *
 *         Lifecycle (see docs/dpm-markets-plan.md):
 *           - Intent phase: block.timestamp <  openTime   (enterIntent / exitIntent, 1:1 refundable)
 *           - Open phase:   openTime <= now <  closeTime   (enter, dynamic DPM pricing; no exits)
 *           - Closed:       now >= closeTime               (resolution, then claim)
 */
library LibDpmValidator {
    // Outcome bounds for a DPM market. Binary is the floor; the ceiling bounds the O(N) pricing /
    // seed / claim loops (each enter/claim sums over all other outcomes). 64 is well under the CTF
    // protocol limit of 256 and keeps per-op gas predictable; raise it only with the gas cost in mind.
    uint256 internal constant MIN_OUTCOMES = 2;
    uint256 internal constant MAX_OUTCOMES = 64;

    error NotDpmMarket();
    error AlreadyDpmMarket();
    error MarketIsDpm();          // cross-mode guard: a DPM market reached a CLOB entry point
    error InvalidOutcomeCount();
    error CloseTimeNotAfterOpenTime();
    error InvalidOpenTime();
    error InvalidOutcome();
    error ZeroAmount();
    error NotIntentPhase();       // requires block.timestamp < openTime
    error NotOpenPhase();         // requires openTime <= now < closeTime
    error TradingClosed();        // now >= closeTime
    error AlreadyClaimed();
    error InsufficientIntentStake();
    error NotResolved();          // claim requires the underlying market resolved by the oracle

    // ---- Mode guards ----

    /// @notice Require that `marketId` IS a DPM market (used inside DpmFacet).
    function requireIsDpmMarket(uint256 marketId) internal view {
        if (!LibDpmStorage.isDpmMarket(marketId)) revert NotDpmMarket();
    }

    /// @notice Require that `marketId` is NOT a DPM market (cross-mode guard for CLOB entry points).
    ///         DPM markets carry MarketTradingData (created via the base path), so without this
    ///         guard the CLOB facets would otherwise accept them.
    function requireNotDpmMarket(uint256 marketId) internal view {
        if (LibDpmStorage.isDpmMarket(marketId)) revert MarketIsDpm();
    }

    /// @notice Require that no DPM overlay exists yet for `marketId` (creation-time guard).
    function requireDpmMarketNotExists(uint256 marketId) internal view {
        if (LibDpmStorage.isDpmMarket(marketId)) revert AlreadyDpmMarket();
    }

    // ---- Creation-time input guards ----

    function requireValidOutcomeCount(uint256 outcomeCount) internal pure {
        if (outcomeCount < MIN_OUTCOMES || outcomeCount > MAX_OUTCOMES) revert InvalidOutcomeCount();
    }

    /// @notice Validate the user-supplied `openTime`. `0` is the immediate sentinel — the facet
    ///         resolves it to block.timestamp (mirrors price markets). Any other value must be
    ///         strictly in the future.
    function requireValidOpenTime(uint256 openTime) internal view {
        if (openTime != 0 && openTime <= block.timestamp) revert InvalidOpenTime();
    }

    /// @notice Trading must end strictly after it begins.
    function requireValidCloseTime(uint256 effectiveOpenTime, uint256 closeTime) internal pure {
        if (closeTime <= effectiveOpenTime) revert CloseTimeNotAfterOpenTime();
    }

    // ---- Operation-time input guards ----

    function requireValidOutcome(uint256 marketId, uint256 outcome) internal view {
        if (outcome >= LibDpmStorage.getDpmMarket(marketId).outcomeCount) revert InvalidOutcome();
    }

    function requireNonZeroAmount(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    // ---- Lifecycle guards ----

    /// @notice Intent phase: strictly before openTime (enter/exit intent allowed).
    function requireIntentPhase(uint256 marketId) internal view {
        if (block.timestamp >= LibDpmStorage.getDpmMarket(marketId).openTime) revert NotIntentPhase();
    }

    /// @notice Open phase: openTime <= now < closeTime (dynamic DPM entries allowed, no exits).
    function requireOpenPhase(uint256 marketId) internal view {
        DpmMarket storage m = LibDpmStorage.getDpmMarket(marketId);
        if (block.timestamp < m.openTime) revert NotOpenPhase();
        if (block.timestamp >= m.closeTime) revert TradingClosed();
    }

    /// @notice Closed: now >= closeTime (resolution / claim window).
    function requireClosed(uint256 marketId) internal view {
        if (block.timestamp < LibDpmStorage.getDpmMarket(marketId).closeTime) revert TradingClosed();
    }

    /// @notice Guard against double-claim.
    function requireNotClaimed(uint256 marketId, address user) internal view {
        if (LibDpmStorage.hasClaimed(marketId, user)) revert AlreadyClaimed();
    }

    /// @notice Require the user holds at least `amount` refundable intent stake on `outcome`.
    function requireSufficientIntentStake(uint256 marketId, address user, uint256 outcome, uint256 amount)
        internal
        view
    {
        if (LibDpmStorage.getIntentStake(marketId, user, outcome) < amount) revert InsufficientIntentStake();
    }

    /// @notice Require the underlying market has been resolved by the oracle (claim precondition).
    ///         DPM has no resolve function of its own; it reads the shared registry status that the
    ///         UMA/Pyth/group resolution paths set.
    function requireResolved(uint256 marketId) internal view {
        if (LibMarketRegistryStorage.getMarketRegistryData(marketId).status != MarketStatus.Resolved) {
            revert NotResolved();
        }
    }
}
