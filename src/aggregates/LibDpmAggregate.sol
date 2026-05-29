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
 *         Invariant these writes preserve: `Σ_i collateral[i] == pool == collateral
 *         held in custody for this market`, par-or-dynamic, AND
 *         `Σ_u userPaid[u][i] == collateral[i]`, `Σ_u userShares[u][i] == shares[i]`,
 *         exactly. Intent transition is gross par reallocation (no flooring, no fee), so
 *         those sums never drift; the only fee charged is on dynamic {recordDpmEntry},
 *         where the per-entry net amount equals the per-market increment by construction.
 *         (See LibDpmService for why charging a fee at the intent transition is rejected.)
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

    // ---- Intent -> DPM transition (lazy, par allocation) ----

    /// @notice Seed market totals from the intent pool at par: M_i = N_i = intentTotals_i.
    /// @dev Once per market (idempotency enforced by the caller via `poolInitialized`).
    ///      Seeds GROSS; intent fees are netted out per user in {applyIntentFee} as each
    ///      participant transitions, so custody and `Σ M_i` stay equal at every step.
    function seedMarketFromIntent(uint256 marketId) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        uint256 oc = s.byMarketId[marketId].outcomeCount;
        for (uint256 i = 0; i < oc; i++) {
            uint256 t = s.intentTotals[marketId][i];
            s.collateral[marketId][i] = t; // M_i
            s.shares[marketId][i] = t; // N_i (par: $1/share)
        }
        s.byMarketId[marketId].poolInitialized = true;
    }

    /// @notice Fold a user's intent stake into their live DPM position at par, for every outcome.
    /// @dev userShares_i += intentStake_i; userPaid_i += intentStake_i; intentStake_i = 0.
    ///      Sets the per-user transitioned flag. Gross allocation — the entry fee on this
    ///      collateral is applied separately via {applyIntentFee}.
    function transitionUserFromIntent(uint256 marketId, address user) internal {
        LibDpmStorage.Storage storage s = LibDpmStorage.getStorage();
        uint256 oc = s.byMarketId[marketId].outcomeCount;
        for (uint256 i = 0; i < oc; i++) {
            uint256 stake = s.intentStake[marketId][user][i];
            if (stake != 0) {
                s.userShares[marketId][user][i] += stake;
                s.userPaid[marketId][user][i] += stake;
                s.intentStake[marketId][user][i] = 0;
            }
        }
        s.intentTransitioned[marketId][user] = true;
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
}
