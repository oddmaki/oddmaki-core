// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";
import {LibDpmAggregate} from "../aggregates/LibDpmAggregate.sol";
import {LibDpmPricingService} from "./LibDpmPricingService.sol";

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";

import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";

import {LibMarketOrderValidator} from "../validators/LibMarketOrderValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";

import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {DpmMarket, MarketFees, FeeBreakdown} from "../interfaces/Types.sol";

/**
 * @title LibDpmService
 * @notice Orchestration (sagas) for DPM markets — Pennock 2004 §4 ("DPM I"). All functions are
 *         `internal`; the DpmFacet wraps them with nonReentrant. Reads storage, calls validators,
 *         pricing, the aggregate, and reuses the shared collateral / fee / stats services. Never
 *         mutates storage directly (that is the aggregate's job).
 *
 *         Money model (the load-bearing invariant `Σ M_i == custody`, exact, par-or-dynamic):
 *           - enterIntent / exitIntent: 1:1 refundable, no pricing, NO fee (so exit is exact).
 *           - intent -> DPM transition: par, gross, fee-free reallocation (see note below).
 *           - enter: fee charged on the deposited `amount`; only `amount - fee` enters the pool.
 *           - claim: pays winners `userPaid + (M_other/N_w)·userShares`; refunds on invalid / no-contest.
 *
 *         Why no fee at the intent transition: the plan sketched charging it there, but netting a
 *         per-user fee out of the seeded pool breaks `Σ_u userPaid == M_i` (per-user vs per-market
 *         flooring) and/or mutates `N_w`/`M_other` during the claim phase, which makes sequential
 *         winner claims over-draw the pool. Charging only on dynamic `enter` keeps the identity
 *         exact and freezes M/N before any claim. Intent stake therefore pays no transaction fee.
 */
library LibDpmService {
    // =========================================================================
    // Creation
    // =========================================================================

    /// @notice Initialize the DPM overlay on an already-created base market.
    function initPool(uint256 marketId, uint256 outcomeCount, uint256 openTime, uint256 closeTime) internal {
        LibDpmValidator.requireDpmMarketNotExists(marketId);
        LibDpmAggregate.initPool(marketId, outcomeCount, openTime, closeTime);
    }

    // =========================================================================
    // Intent phase (t < openTime) — 1:1, refundable, no fee, no pricing
    // =========================================================================

    function enterIntent(address user, uint256 marketId, uint256 outcome, uint256 amount) internal {
        LibDpmValidator.requireIsDpmMarket(marketId);
        LibDpmValidator.requireIntentPhase(marketId);
        LibDpmValidator.requireValidOutcome(marketId, outcome);
        LibDpmValidator.requireNonZeroAmount(amount);
        _requireTradingAllowed(user, marketId);

        LibVaultCollateralService.depositCollateral(_collateralToken(marketId), user, amount);
        LibDpmAggregate.recordIntentStake(marketId, user, outcome, amount);
    }

    /// @dev No pause / access gate: a refundable intent stake must always be retrievable before
    ///      openTime, even if the venue later pauses the market or revokes the user's access.
    function exitIntent(address user, uint256 marketId, uint256 outcome, uint256 amount) internal {
        LibDpmValidator.requireIsDpmMarket(marketId);
        LibDpmValidator.requireIntentPhase(marketId);
        LibDpmValidator.requireValidOutcome(marketId, outcome);
        LibDpmValidator.requireNonZeroAmount(amount);
        LibDpmValidator.requireSufficientIntentStake(marketId, user, outcome, amount);

        LibDpmAggregate.releaseIntentStake(marketId, user, outcome, amount);
        LibVaultCollateralService.withdrawCollateral(_collateralToken(marketId), user, amount);
    }

    // =========================================================================
    // Open phase (openTime <= t < closeTime) — dynamic Pennock pricing, fee on entry
    // =========================================================================

    function enter(address user, uint256 marketId, uint256 outcome, uint256 amount)
        internal
        returns (uint256 sharesOut)
    {
        LibDpmValidator.requireIsDpmMarket(marketId);
        LibDpmValidator.requireOpenPhase(marketId);
        LibDpmValidator.requireValidOutcome(marketId, outcome);
        LibDpmValidator.requireNonZeroAmount(amount);
        _requireTradingAllowed(user, marketId);

        // Lazy intent -> DPM init (per-market once, then per-user) at par, fee-free.
        if (!LibDpmStorage.getDpmMarket(marketId).poolInitialized) {
            LibDpmAggregate.seedMarketFromIntent(marketId);
        }
        if (!LibDpmStorage.hasTransitioned(marketId, user)) {
            LibDpmAggregate.transitionUserFromIntent(marketId, user);
        }

        address token = _collateralToken(marketId);

        // Pull the gross amount, then route the fee out of custody; only the net enters the pool.
        LibVaultCollateralService.depositCollateral(token, user, amount);
        uint256 netAmount = _chargeEntryFee(marketId, token, amount);

        // Pennock inverse against the *other* side; rounds shares down (protocol-favorable).
        uint256 mI = LibDpmStorage.getCollateral(marketId, outcome);
        uint256 nOther = LibDpmStorage.getOtherShares(marketId, outcome);
        sharesOut = LibDpmPricingService.sharesForCollateral(mI, nOther, netAmount);

        LibDpmAggregate.recordDpmEntry(marketId, user, outcome, netAmount, sharesOut);

        // Keep the shared protocol stats populated (volume on gross spend; implied last-trade tick).
        LibMarketTradingAggregate.recordTotalVolume(marketId, outcome, amount);
        LibMarketTradingAggregate.recordLastTradeTick(marketId, outcome, _impliedTick(marketId, netAmount, sharesOut));
    }

    // =========================================================================
    // Resolution (t >= closeTime, market resolved) — claim per DPM I
    // =========================================================================

    function claim(address user, uint256 marketId) internal returns (uint256 payout) {
        LibDpmValidator.requireIsDpmMarket(marketId);
        LibDpmValidator.requireClosed(marketId);
        LibDpmValidator.requireResolved(marketId);
        LibDpmValidator.requireNotClaimed(marketId, user);

        // Effects before interaction: lock the claim immediately.
        LibDpmAggregate.markClaimed(marketId, user);

        DpmMarket storage m = LibDpmStorage.getDpmMarket(marketId);
        uint256 oc = m.outcomeCount;

        (bool hasWinner, uint256 winner) = _winningOutcome(marketId, oc);

        if (!hasWinner) {
            // Invalid / split ([1,1] or any non-singleton payout): refund every position.
            payout = _refundAll(marketId, user, oc);
        } else {
            // Seed (idempotent per market) so the no-contest check sees intent-backed shares.
            if (!m.poolInitialized) LibDpmAggregate.seedMarketFromIntent(marketId);

            if (LibDpmStorage.getShares(marketId, winner) == 0) {
                // No-contest: nobody backed the winning outcome -> void, refund all.
                payout = _refundAll(marketId, user, oc);
            } else {
                // Fold the claimer's intent into their live position at par (fee-free) so a
                // pure-intent winner is paid. This never changes M_i/N_i (market totals already
                // include their stake from the seed), so all winners claim against frozen totals.
                if (!LibDpmStorage.hasTransitioned(marketId, user)) {
                    LibDpmAggregate.transitionUserFromIntent(marketId, user);
                }

                uint256 nW = LibDpmStorage.getShares(marketId, winner);
                uint256 mOther = LibDpmStorage.getOtherCollateral(marketId, winner); // pool - M_w
                uint256 userShares = LibDpmStorage.getUserShares(marketId, user, winner);
                uint256 userPaid = LibDpmStorage.getUserPaid(marketId, user, winner);

                // DPM I: refund of price paid + pro-rata slice of the losers' pool (slice floored).
                payout = userPaid + (mOther * userShares) / nW;
            }
        }

        if (payout > 0) {
            LibVaultCollateralService.withdrawCollateral(_collateralToken(marketId), user, payout);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Sum of a user's refundable basis across all outcomes: net DPM basis (`userPaid`, set by
    ///      transition or dynamic entries) plus any still-un-transitioned gross intent stake. These
    ///      are disjoint per user (a dynamic entry transitions them, zeroing intentStake), so the sum
    ///      never double-counts. Used for invalid / no-contest refunds.
    function _refundAll(uint256 marketId, address user, uint256 oc) private view returns (uint256 refund) {
        for (uint256 i = 0; i < oc; i++) {
            refund += LibDpmStorage.getUserPaid(marketId, user, i);
            refund += LibDpmStorage.getIntentStake(marketId, user, i);
        }
    }

    /// @dev Read the resolved payout numerators from the CTF and classify: exactly one non-zero
    ///      numerator is a clean winner; zero or more-than-one (e.g. [1,1]) is invalid / split.
    function _winningOutcome(uint256 marketId, uint256 oc) private view returns (bool hasWinner, uint256 winner) {
        bytes32 conditionId = LibMarketOracleStorage.getMarketOracleData(
            LibMarketRegistryStorage.getMarketRegistryData(marketId).questionId
        ).conditionId;
        IConditionalTokens ctf = IConditionalTokens(LibVaultStorage.getCtf());

        uint256 nonZero;
        for (uint256 i = 0; i < oc; i++) {
            if (ctf.payoutNumerators(conditionId, i) != 0) {
                nonZero++;
                winner = i;
            }
        }
        hasWinner = (nonZero == 1);
        if (!hasWinner) winner = 0;
    }

    /// @dev Charge the entry fee on `amount` and route it out of custody via the shared distributor.
    ///      Returns the net collateral that stays in the pool. `feeOut == amount·totalFeeBps/10000`
    ///      (== breakdown.totalFee + remainder), so `Σ M_i` stays equal to custody after the fee
    ///      leaves. Note: the operator slice routes to msg.sender (the entrant) per the shared helper.
    function _chargeEntryFee(uint256 marketId, address token, uint256 amount) private returns (uint256 netAmount) {
        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        FeeBreakdown memory breakdown = LibFeeCalculatorService.calculateFees(amount, fees);
        uint256 feeOut = breakdown.totalFee + breakdown.remainder;
        LibFeeDistributionService.distributeFees(token, breakdown, fees, marketId, 0);
        netAmount = amount - feeOut;
    }

    /// @dev Implied per-share price of a fill expressed as a tick (price·1e18 / tickSize), best-effort
    ///      for off-chain stats only. DPM prices can exceed $1/share for late buyers; that is expected
    ///      and harmless here (DPM markets are guarded out of the CLOB mark-price paths).
    function _impliedTick(uint256 marketId, uint256 netAmount, uint256 shares) private view returns (uint256) {
        if (shares == 0) return 0;
        uint256 tickSize = LibMarketTradingStorage.getMarketTradingData(marketId).tickSize;
        if (tickSize == 0) return 0;
        // pricePerShare (1e18) = netAmount·1e18 / shares; tick = pricePerShare / tickSize.
        return (netAmount * 1e18 / shares) / tickSize;
    }

    function _requireTradingAllowed(address user, uint256 marketId) private view {
        LibMarketOrderValidator.requireActiveMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(user, marketId);
    }

    function _collateralToken(uint256 marketId) private view returns (address) {
        return address(LibMarketTradingStorage.getMarketTradingData(marketId).collateralToken);
    }
}
