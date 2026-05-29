// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {UD60x18, wrap, uEXP_MAX_INPUT} from "@prb/math/UD60x18.sol";

/**
 * @title LibDpmPricingService
 * @notice Pennock 2004 §4 ("DPM I") dynamic pari-mutuel pricing, in fixed point.
 *
 *         For a buy of outcome `i`, with `M_i` collateral already wagered on `i`,
 *         `N_other` shares outstanding on the *other* side(s):
 *
 *           price:    p_i(n) = (M_i / N_other) · e^(n / N_other)        (eq. 7)
 *           cost:     m(n)   = M_i · (e^(n / N_other) − 1)              (eq. 6, integrated)
 *           inverse:  n(m)   = N_other · ln(1 + m / M_i)
 *
 *         `enter` submits `m` collateral and receives `n` shares — it calls
 *         {sharesForCollateral}. {collateralForShares} is the forward map, used by
 *         tests to round-trip and to assert the self-funding identity.
 *
 *         Par boundary (our decision, see docs/dpm-pricing-math.md §"Par boundary"):
 *         when `N_other == 0` OR `M_i == 0` the dynamic formula is undefined, so the
 *         side prices at par — $1/share, i.e. `n == m`. The self-funding identity
 *         `Σ M_i == pool` holds par-or-dynamic, so this can never cause insolvency.
 *
 *         Units: `M_i`, `N_other`, `m`, `n` are all passed in the protocol's native
 *         integer scale (collateral token decimals; shares share that scale because
 *         par mints 1 share per collateral unit). The ratios `m/M_i` and `n/N_other`
 *         are dimensionless, so wrapping the raw integers directly into UD60x18 lets
 *         the 1e18 fixed-point factor cancel in {div}; the surrounding {mul} by the
 *         raw `N_other`/`M_i` returns a result in the same native scale.
 */
library LibDpmPricingService {
    /// @dev UD60x18 unit (1.0 in 18-decimal fixed point).
    uint256 internal constant ONE = 1e18;

    /// @notice `n / N_other` exceeded UD60x18's safe `exp` domain. Split the trade client-side.
    error DpmExpInputTooLarge();

    /**
     * @notice Shares `n` minted for `m` collateral on outcome `i` — `n = N_other · ln(1 + m/M_i)`.
     * @dev Rounds **down** (mints fewer shares for the same collateral). This is
     *      protocol-favorable: the loser-pool slice each winning share earns is
     *      `M_other / N_w`, so fewer shares outstanding can only raise per-share
     *      payout, never push the pool insolvent. Caller (`enter`) relies on this
     *      direction — do not change it without revisiting the claim accounting.
     * @param mI       M_i — collateral already wagered on the bought outcome.
     * @param nOther   N_other — shares outstanding on the other side(s).
     * @param m        collateral being spent (net of fee).
     * @return n       shares minted, floored.
     */
    function sharesForCollateral(uint256 mI, uint256 nOther, uint256 m) internal pure returns (uint256 n) {
        // Par-until-contested: one side empty => the dynamic price is undefined => $1/share.
        if (nOther == 0 || mI == 0) {
            return m;
        }
        UD60x18 ratio = wrap(m).div(wrap(mI)); // m / M_i (dimensionless; the 1e18 factors cancel)
        UD60x18 lnVal = wrap(ONE).add(ratio).ln(); // ln(1 + m/M_i)
        // N_other · lnVal: mul == mulDiv(nOther, lnVal, 1e18), floored => native share scale.
        n = wrap(nOther).mul(lnVal).unwrap();
    }

    /**
     * @notice Collateral `m` required to mint `n` shares on outcome `i` — `m = M_i · (e^(n/N_other) − 1)`.
     * @dev The forward of {sharesForCollateral}. Rounds **up** (charges no less than the
     *      exact cost). Used by tests for round-trip and the self-funding identity; the
     *      `enter` path uses the inverse instead. Reverts {DpmExpInputTooLarge} if
     *      `n / N_other` leaves `exp`'s safe domain — a whale-sized single trade beyond
     *      the library range must be split client-side (documented limit).
     * @param mI       M_i — collateral already wagered on the outcome.
     * @param nOther   N_other — shares outstanding on the other side(s).
     * @param n        shares to mint.
     * @return m       collateral cost, rounded up.
     */
    function collateralForShares(uint256 mI, uint256 nOther, uint256 n) internal pure returns (uint256 m) {
        if (nOther == 0 || mI == 0) {
            return n; // par: $1/share
        }
        UD60x18 expo = wrap(n).div(wrap(nOther)); // n / N_other
        if (expo.unwrap() > uEXP_MAX_INPUT) revert DpmExpInputTooLarge();
        UD60x18 eMinus1 = expo.exp().sub(wrap(ONE)); // e^(n/N_other) − 1
        uint256 scaled = eMinus1.unwrap();
        // m = M_i · (e−1), rounded up. mul == mulDiv(mI, scaled, 1e18) floored (512-bit safe);
        // mulmod recovers the remainder without an intermediate overflow.
        uint256 floorM = wrap(mI).mul(eMinus1).unwrap();
        m = mulmod(mI, scaled, ONE) == 0 ? floorM : floorM + 1;
    }
}
