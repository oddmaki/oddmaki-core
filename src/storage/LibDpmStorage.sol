// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {DpmMarket} from "../interfaces/Types.sol";

/**
 * @title LibDpmStorage
 * @notice Diamond storage for DPM (Dynamic Pari-Mutuel) markets — Pennock 2004 §4 ("DPM I").
 *         Each DPM market is an overlay on a standard OddMaki market: identity, fees, oracle
 *         and resolution all live in the normal registry/trading/oracle storage. This namespace
 *         holds only the pari-mutuel pool state.
 *
 *         Per-outcome aggregates and per-user balances are stored in flat mappings keyed by
 *         outcome index (rather than dynamic arrays) so any outcome count needs no array allocation
 *         and per-user state stays sparse.
 *
 *         See docs/dpm-markets-plan.md and docs/dpm-pricing-math.md for the full design.
 */
library LibDpmStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.dpm");

    struct Storage {
        // Scalar lifecycle fields per market (outcomeCount == 0 => not a DPM market).
        mapping(uint256 => DpmMarket) byMarketId;
        // Per-outcome market aggregates: marketId => outcome => value.
        mapping(uint256 => mapping(uint256 => uint256)) collateral; // M_i: total collateral wagered on outcome i
        mapping(uint256 => mapping(uint256 => uint256)) shares;     // N_i: total shares outstanding on outcome i
        mapping(uint256 => mapping(uint256 => uint256)) intentTotals; // pre-openTime intent collateral per outcome
        // Per-user state: marketId => user => outcome => value.
        mapping(uint256 => mapping(address => mapping(uint256 => uint256))) intentStake; // refundable pre-openTime stake
        mapping(uint256 => mapping(address => mapping(uint256 => uint256))) userShares;  // shares held per outcome
        mapping(uint256 => mapping(address => mapping(uint256 => uint256))) userPaid;    // collateral spent per outcome (DPM I refund basis)
        // Per-user flags: marketId => user => flag.
        mapping(uint256 => mapping(address => bool)) claimed;            // payout claimed at resolution
        mapping(uint256 => mapping(address => bool)) intentTransitioned; // user's intent stake folded into DPM at par
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    // ---- Market accessors ----

    function getDpmMarket(uint256 marketId) internal view returns (DpmMarket storage) {
        return getStorage().byMarketId[marketId];
    }

    function isDpmMarket(uint256 marketId) internal view returns (bool) {
        return getStorage().byMarketId[marketId].outcomeCount != 0;
    }

    // ---- Per-outcome aggregate accessors ----

    function getCollateral(uint256 marketId, uint256 outcome) internal view returns (uint256) {
        return getStorage().collateral[marketId][outcome];
    }

    function getShares(uint256 marketId, uint256 outcome) internal view returns (uint256) {
        return getStorage().shares[marketId][outcome];
    }

    function getIntentTotal(uint256 marketId, uint256 outcome) internal view returns (uint256) {
        return getStorage().intentTotals[marketId][outcome];
    }

    /// @notice Total collateral currently in the live DPM pool (sum of M_i over all outcomes).
    function getPool(uint256 marketId) internal view returns (uint256 pool) {
        Storage storage s = getStorage();
        uint256 n = s.byMarketId[marketId].outcomeCount;
        for (uint256 i = 0; i < n; i++) {
            pool += s.collateral[marketId][i];
        }
    }

    /// @notice Aggregate intent + live shares on all outcomes other than `outcome`.
    ///         This is N_other in the Pennock price function (the denominator side).
    function getOtherShares(uint256 marketId, uint256 outcome) internal view returns (uint256 other) {
        Storage storage s = getStorage();
        uint256 n = s.byMarketId[marketId].outcomeCount;
        for (uint256 i = 0; i < n; i++) {
            if (i == outcome) continue;
            other += s.shares[marketId][i];
        }
    }

    /// @notice Aggregate live collateral on all outcomes other than `outcome` (M_other, the losers' pool).
    function getOtherCollateral(uint256 marketId, uint256 outcome) internal view returns (uint256 other) {
        Storage storage s = getStorage();
        uint256 n = s.byMarketId[marketId].outcomeCount;
        for (uint256 i = 0; i < n; i++) {
            if (i == outcome) continue;
            other += s.collateral[marketId][i];
        }
    }

    // ---- Per-user accessors ----

    function getIntentStake(uint256 marketId, address user, uint256 outcome) internal view returns (uint256) {
        return getStorage().intentStake[marketId][user][outcome];
    }

    function getUserShares(uint256 marketId, address user, uint256 outcome) internal view returns (uint256) {
        return getStorage().userShares[marketId][user][outcome];
    }

    function getUserPaid(uint256 marketId, address user, uint256 outcome) internal view returns (uint256) {
        return getStorage().userPaid[marketId][user][outcome];
    }

    function hasClaimed(uint256 marketId, address user) internal view returns (bool) {
        return getStorage().claimed[marketId][user];
    }

    function hasTransitioned(uint256 marketId, address user) internal view returns (bool) {
        return getStorage().intentTransitioned[marketId][user];
    }
}
