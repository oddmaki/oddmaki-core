// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";
import {DpmMarket} from "../interfaces/Types.sol";

/**
 * @title LibDpmAggregate
 * @notice Mutation-only writes to LibDpmStorage for DPM (Pennock 2004 §4) markets.
 *         No getters (reads go through LibDpmStorage); all business logic / ordering
 *         lives in LibDpmService. Every function here is a single, self-contained
 *         storage edit so the saga in the service stays auditable.
 *
 *         Invariants these writes preserve (see LibDpmService for the full argument):
 *           - `Σ_i collateral[i] == pool == collateral held in custody`, par-or-dynamic.
 *           - `Σ_u userShares[u][i] == shares[i]` exactly (shares are always GROSS — never
 *             reduced by fees — which is what keeps N_i frozen across sequential claims).
 *           - `Σ_u userPaid[u][i] <= collateral[i]` (tiny rounding dust stays locked in the
 *             pool — the solvent direction).
 *         The intent entry fee is charged once at seed: {seedOutcome} stores M_i net of the
 *         per-outcome fee while N_i stays gross; {recordIntentTransition} then allocates each
 *         user a gross share count and a net paid basis without ever touching M_i / N_i.
 */
library LibDpmAggregate {
    /// @notice Create the DPM overlay for `marketId`. Reverts if one already exists.
    function initPool(uint256 marketId, uint256 outcomeCount, uint256 openTime, uint256 closeTime) internal {
        if (LibDpmStorage.isDpmMarket(marketId)) revert LibDpmValidator.AlreadyDpmMarket();
        LibDpmStorage.getStorage().byMarketId[marketId] =
            DpmMarket({outcomeCount: outcomeCount, openTime: openTime, closeTime: closeTime, poolInitialized: false});
    }

    // ---- Intent phase (1:1, refundable) ----

    /// @notice Add `amount` to a user's refundable intent stake on `outcome` and the market intent total.
    function recordIntentStake(uint256 marketId, address user, uint256 outcome, uint256 amount) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        s.intentStake[marketId][user][outcome] += amount;
        s.intentTotals[marketId][outcome] += amount;
    }

    /// @notice Remove `amount` from a user's intent stake on `outcome` (and the market total).
    /// @dev Reverts on underflow (checked arithmetic). Callers should pre-check via
    ///      LibDpmValidator.requireSufficientIntentStake for a friendly error.
    function releaseIntentStake(uint256 marketId, address user, uint256 outcome, uint256 amount) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        s.intentStake[marketId][user][outcome] -= amount;
        s.intentTotals[marketId][outcome] -= amount;
    }

    // ---- Intent -> DPM transition (lazy seed + per-user allocation) ----

    /// @notice Seed one outcome's market totals at the intent transition.
    /// @dev `collateralValue` is M_i (intent total net of the seed fee); `sharesValue` is N_i
    ///      (always the GROSS intent total, par $1/share — shares are never fee-reduced so N_i
    ///      stays frozen across claims). The service distributes the netted fee separately.
    function seedOutcome(uint256 marketId, uint256 outcome, uint256 collateralValue, uint256 sharesValue) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        s.collateral[marketId][outcome] = collateralValue;
        s.shares[marketId][outcome] = sharesValue;
    }

    /// @notice Mark the per-market intent -> DPM seed as performed (one-shot).
    function markPoolInitialized(uint256 marketId) internal {
        LibDpmStorage.getStorage().byMarketId[marketId].poolInitialized = true;
    }

    /// @notice Allocate a user's intent stake on `outcome` into their live position.
    /// @dev userShares += grossShares (par, gross — the fee was already taken at seed); userPaid +=
    ///      netPaid (gross stake minus the per-user ceil-rounded fee); intentStake zeroed. Does NOT
    ///      touch M_i / N_i, so the market totals stay frozen and no claim can drift.
    function recordIntentTransition(
        uint256 marketId,
        address user,
        uint256 outcome,
        uint256 grossShares,
        uint256 netPaid
    ) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        s.userShares[marketId][user][outcome] += grossShares;
        s.userPaid[marketId][user][outcome] += netPaid;
        s.intentStake[marketId][user][outcome] = 0;
    }

    /// @notice Mark a user's intent stake as folded into their live DPM position (one-shot per user).
    function markTransitioned(uint256 marketId, address user) internal {
        LibDpmStorage.getStorage().intentTransitioned[marketId][user] = true;
    }

    // ---- Open phase (dynamic Pennock entries) ----

    /// @notice Record a dynamic entry: `m_in` net collateral buying `n_out` shares on `outcome`.
    /// @dev M_i += m_in; N_i += n_out; userShares += n_out; userPaid += m_in. `m_in` must be the
    ///      collateral that actually entered custody (net of fee) so `Σ M_i == custody` holds.
    function recordDpmEntry(uint256 marketId, address user, uint256 outcome, uint256 m_in, uint256 n_out) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        s.collateral[marketId][outcome] += m_in;
        s.shares[marketId][outcome] += n_out;
        s.userShares[marketId][user][outcome] += n_out;
        s.userPaid[marketId][user][outcome] += m_in;
    }

    // ---- Resolution ----

    /// @notice Mark a user's payout as claimed (double-claim guard).
    function markClaimed(uint256 marketId, address user) internal {
        LibDpmStorage.getStorage().claimed[marketId][user] = true;
    }

    /// @notice Set a market's outcome count (used when a late outcome is added). The new outcome's
    ///         M/N start at 0 (par-until-contested) — the flat mappings need no resizing.
    function setOutcomeCount(uint256 marketId, uint256 outcomeCount) internal {
        LibDpmStorage.getStorage().byMarketId[marketId].outcomeCount = outcomeCount;
    }
}
