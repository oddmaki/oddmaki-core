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
 *         Money model (the load-bearing invariant `Σ M_i == custody`, with `Σ userPaid <= M_i`
 *         and `Σ userShares == N_i`, par-or-dynamic):
 *           - enterIntent / exitIntent: 1:1 refundable, no pricing, NO fee (so exit is exact).
 *           - intent -> DPM seed (once, at the first post-openTime interaction): the entry fee is
 *             charged on the whole intent pool here. Per outcome `M_i = intentTotals_i - fee_i`
 *             (net, fee floored), `N_i = intentTotals_i` (gross). The summed fee is distributed.
 *           - per-user transition: pure allocation — `userShares += stake` (gross), `userPaid +=
 *             stake - ceil(stake·feeBps)` (net). It never touches M_i / N_i, so totals freeze at
 *             seed and no claim can drift.
 *           - enter: fee charged on the deposited `amount`; only `amount - fee` enters the pool.
 *           - claim: pays winners `userPaid + (M_other/N_w)·userShares`; refunds on invalid / no-contest.
 *
 *         Why this shape (the subtle part): the fee MUST be charged at the intent->pool transition,
 *         else everyone would route deposits through the free intent phase. But shares are kept
 *         gross (the fee only reduces collateral M, never share count N), so N_i never moves; and
 *         the fee is taken once at the market seed, never lazily during claims — together these
 *         freeze M/N before the first payout, so sequential winner claims can't drift. Pairing the
 *         seed's per-outcome floor with each user's ceil keeps `Σ userPaid <= M_i` (any sub-unit
 *         dust stays locked in the pool — the solvent direction). The operator fee slice is folded
 *         into the protocol bucket (DPM has no keeper to receive it).
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

        address token = _collateralToken(marketId);

        // Lazy intent -> DPM init: seed the market once (charging the intent fee), then fold this
        // caller's intent into their live position. Both are pure allocation w.r.t. M/N after seed.
        _seedIfNeeded(marketId, token);
        _transitionIfNeeded(marketId, user);

        // Pull the gross amount, then route the entry fee out of custody; only the net enters the pool.
        LibVaultCollateralService.depositCollateral(token, user, amount);
        uint256 feeOut = _feeOn(marketId, amount);
        _distributeFee(marketId, token, feeOut);
        uint256 netAmount = amount - feeOut;

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
            // Seed (idempotent per market) so the no-contest check sees intent-backed shares. This
            // also charges the intent fee if it has not been charged yet (pure-intent market that
            // saw no open-phase entry); the first claimer triggers it.
            _seedIfNeeded(marketId, _collateralToken(marketId));

            if (LibDpmStorage.getShares(marketId, winner) == 0) {
                // No-contest: nobody backed the winning outcome -> void, refund all.
                payout = _refundAll(marketId, user, oc);
            } else {
                // Fold the claimer's intent into their live position (pure allocation) so a
                // pure-intent winner is paid. This never changes M_i/N_i (market totals already
                // include their stake from the seed), so all winners claim against frozen totals.
                _transitionIfNeeded(marketId, user);

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

    // ---- Intent seed + per-user transition ----

    /// @dev Seed the per-market intent -> DPM pool exactly once, charging the intent entry fee on the
    ///      whole intent pool. Per outcome: M_i = intentTotals_i - floor(intentTotals_i·feeBps) (net),
    ///      N_i = intentTotals_i (gross). The summed fee is distributed (operator -> protocol), so
    ///      `Σ M_i == custody` holds after the fee leaves. Triggered by the first post-open enter or
    ///      the first claim — whoever gets there first pays the gas.
    function _seedIfNeeded(uint256 marketId, address token) private {
        if (LibDpmStorage.getDpmMarket(marketId).poolInitialized) return;

        uint256 oc = LibDpmStorage.getDpmMarket(marketId).outcomeCount;
        uint256 feeBps = _totalFeeBps(marketId);
        uint256 feeOut;
        for (uint256 i = 0; i < oc; i++) {
            uint256 t = LibDpmStorage.getIntentTotal(marketId, i);
            uint256 fee = (t * feeBps) / BPS_DENOMINATOR; // floor
            LibDpmAggregate.seedOutcome(marketId, i, t - fee, t); // M_i net, N_i gross
            feeOut += fee;
        }
        LibDpmAggregate.markPoolInitialized(marketId);
        _distributeFee(marketId, token, feeOut);
    }

    /// @dev Fold a user's intent into their live position once: gross shares, net paid basis
    ///      (stake minus the per-user ceil-rounded fee). The fee itself was already distributed at
    ///      seed; this only allocates, never touching M_i / N_i. Ceil rounding makes `Σ userPaid <=
    ///      M_i` so the pool can never be over-claimed (sub-unit dust stays locked).
    function _transitionIfNeeded(uint256 marketId, address user) private {
        if (LibDpmStorage.hasTransitioned(marketId, user)) return;

        uint256 oc = LibDpmStorage.getDpmMarket(marketId).outcomeCount;
        uint256 feeBps = _totalFeeBps(marketId);
        for (uint256 i = 0; i < oc; i++) {
            uint256 stake = LibDpmStorage.getIntentStake(marketId, user, i);
            if (stake == 0) continue;
            uint256 fee = (stake * feeBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR; // ceil
            LibDpmAggregate.recordIntentTransition(marketId, user, i, stake, stake - fee);
        }
        LibDpmAggregate.markTransitioned(marketId, user);
    }

    // ---- Fee math ----

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Total DPM fee bps for this market (protocol + venue + operator), or 0 if fees are
    ///      disabled (no protocol treasury snapshotted at creation).
    function _totalFeeBps(uint256 marketId) private view returns (uint256) {
        return LibFeeCalculatorService.getTotalFeeBps(LibFeeCalculatorService.getMarketFees(marketId));
    }

    /// @dev Fee charged on a fresh `amount` spend (floored). The complement enters the pool.
    function _feeOn(uint256 marketId, uint256 amount) private view returns (uint256) {
        return (amount * _totalFeeBps(marketId)) / BPS_DENOMINATOR;
    }

    /// @dev Distribute exactly `feeOut` to the fee recipients, folding the operator slice into the
    ///      protocol bucket (DPM `enter`/`seed` has no keeper to receive an operator fee). The split
    ///      is exact: any component-rounding dust is swept into the protocol remainder, so the sum
    ///      sent equals `feeOut` and `Σ M_i == custody` is preserved.
    function _distributeFee(uint256 marketId, address token, uint256 feeOut) private {
        if (feeOut == 0) return;
        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        LibFeeDistributionService.distributeFees(token, _splitFee(feeOut, fees), fees, marketId, 0);
    }

    /// @dev Split `feeOut` into a FeeBreakdown summing exactly to `feeOut`, with the operator slice
    ///      folded into protocol and the creator slice carved from venue. The remainder (rounding
    ///      dust) is left for protocol, matching how LibFeeDistributionService routes it.
    function _splitFee(uint256 feeOut, MarketFees memory fees) private pure returns (FeeBreakdown memory bd) {
        uint256 totalBps = LibFeeCalculatorService.getTotalFeeBps(fees); // protocol + venue + operator
        if (totalBps == 0) return bd;
        bd.protocolFee = (feeOut * (fees.protocolFeeBps + fees.operatorFeeBps)) / totalBps; // operator -> protocol
        bd.creatorFee = (feeOut * fees.creatorFeeBps) / totalBps;
        bd.venueNetFee = (feeOut * (fees.venueFeeBps - fees.creatorFeeBps)) / totalBps;
        bd.operatorFee = 0;
        bd.totalFee = bd.protocolFee + bd.creatorFee + bd.venueNetFee;
        bd.remainder = feeOut - bd.totalFee; // dust -> protocol in distributeFees
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
