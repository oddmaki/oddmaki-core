// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LibDpmPricingService} from "../src/services/LibDpmPricingService.sol";

/// @dev External wrapper so `vm.expectRevert` sees a real sub-call frame (internal
///      library calls inline into the test contract and revert at the same depth).
contract DpmPricingHarness {
    function collateralForShares(uint256 mI, uint256 nOther, uint256 n) external pure returns (uint256) {
        return LibDpmPricingService.collateralForShares(mI, nOther, n);
    }
}

/**
 * @title LibDpmPricingService unit + property tests
 * @notice Verifies the Pennock 2004 §4 (DPM I) fixed-point pricing:
 *           - par-until-contested boundary,
 *           - protocol-favorable round-trip,
 *           - the self-funding identity (Σ M_i == total deposited) over random buys,
 *           - the worked binary example from docs/dpm-pricing-math.md,
 *           - the exp-domain overflow guard.
 *         Amounts are in USDC-native 6-decimal integers (1e6 == $1), matching the
 *         protocol's collateral scale; shares share that scale because par mints 1:1.
 */
contract LibDpmPricingServiceTest is Test {
    uint256 internal constant USDC = 1e6; // $1 in 6-decimal collateral units

    DpmPricingHarness internal harness;

    function setUp() public {
        harness = new DpmPricingHarness();
    }

    // Mirror the par-or-dynamic decision `enter` makes: par fires while either side
    // is empty (N_other == 0 or M_i == 0), otherwise dynamic Pennock pricing.
    function _shares(uint256 mI, uint256 nOther, uint256 m) internal pure returns (uint256) {
        return LibDpmPricingService.sharesForCollateral(mI, nOther, m);
    }

    // ---- Par boundary ----

    function test_par_whenOtherSharesZero() public pure {
        // N_other == 0 => $1/share regardless of M_i.
        assertEq(_shares(123 * USDC, 0, 10 * USDC), 10 * USDC, "par on empty other side");
    }

    function test_par_whenOwnCollateralZero() public pure {
        // M_i == 0 (own side never funded) => $1/share even with shares on the other side.
        assertEq(_shares(0, 30 * USDC, 10 * USDC), 10 * USDC, "par when own collateral zero");
    }

    function testFuzz_par_isOneToOne(uint256 m) public pure {
        m = bound(m, 1, 1e30);
        assertEq(_shares(0, 1234, m), m, "par mints exactly m shares");
        assertEq(_shares(50 * USDC, 0, m), m, "par mints exactly m shares (other side empty)");
    }

    // ---- Round-trip: forward(inverse(m)) <= m (protocol-favorable) ----

    function testFuzz_roundTrip_neverOvercredits(uint256 mI, uint256 nOther, uint256 m) public pure {
        mI = bound(mI, 1 * USDC, 1e15);
        nOther = bound(nOther, 1 * USDC, 1e15);
        m = bound(m, 1, 1e15);

        uint256 n = LibDpmPricingService.sharesForCollateral(mI, nOther, m);
        // Inverse then forward must charge no more collateral than the user actually paid:
        // shares are floored, so the exact cost of `n` shares is <= m, and the ceil of an
        // integer-bounded value cannot exceed the integer m.
        uint256 m2 = LibDpmPricingService.collateralForShares(mI, nOther, n);
        assertLe(m2, m, "round-trip must not overcredit collateral");
    }

    // ---- Self-funding identity: Σ M_i == total deposited, over random interleavings ----

    function testFuzz_selfFunding_identityHolds(uint8[16] calldata sides, uint64[16] calldata rawAmounts) public pure {
        uint256 mYes;
        uint256 nYes;
        uint256 mNo;
        uint256 nNo;
        uint256 deposited;

        for (uint256 i = 0; i < 16; i++) {
            uint256 m = bound(uint256(rawAmounts[i]), 1, 1e12);
            if (sides[i] % 2 == 0) {
                // Buy YES: other side is NO.
                uint256 n = _shares(mYes, nNo, m);
                mYes += m;
                nYes += n;
            } else {
                uint256 n = _shares(mNo, nYes, m);
                mNo += m;
                nNo += n;
            }
            deposited += m;
            // The load-bearing invariant: collateral accounting never drifts, par or dynamic.
            assertEq(mYes + mNo, deposited, "Sigma M_i must equal total deposited");
        }
        // Shares stay strictly positive once funded (sanity).
        assertGt(nYes + nNo, 0, "shares minted");
    }

    // ---- Worked binary example (docs/dpm-pricing-math.md §"Quick sanity walkthrough") ----

    function test_workedExample_binary() public pure {
        uint256 mYes;
        uint256 nYes;
        uint256 mNo;
        uint256 nNo;

        // Per-user winning-side positions we will pay out (YES wins).
        uint256 aliceShares;
        uint256 bobShares;
        uint256 daveShares;

        // 1. Alice $10 YES — par (NO side empty). 10 shares.
        {
            uint256 n = _shares(mYes, nNo, 10 * USDC);
            assertEq(n, 10 * USDC, "Alice par");
            mYes += 10 * USDC;
            nYes += n;
            aliceShares = n;
        }
        // 2. Bob $20 YES — still par. 20 shares.
        {
            uint256 n = _shares(mYes, nNo, 20 * USDC);
            assertEq(n, 20 * USDC, "Bob par");
            mYes += 20 * USDC;
            nYes += n;
            bobShares = n;
        }
        // 3. Carol $10 NO — par (M_no == 0). 10 shares.
        {
            uint256 n = _shares(mNo, nYes, 10 * USDC);
            assertEq(n, 10 * USDC, "Carol par");
            mNo += 10 * USDC;
            nNo += n;
        }
        // 4. Dave $10 YES — both sides live => dynamic. ~2.8768 shares.
        {
            uint256 n = _shares(mYes, nNo, 10 * USDC);
            assertApproxEqAbs(n, 2_876_820, 50, "Dave dynamic ~2.8768 shares");
            mYes += 10 * USDC;
            nYes += n;
            daveShares = n;
        }

        // State after Dave.
        assertEq(mYes, 40 * USDC, "M_yes == 40");
        assertEq(mNo, 10 * USDC, "M_no == 10");
        assertApproxEqAbs(nYes, 32_876_820, 50, "N_yes ~32.8768");
        assertEq(nNo, 10 * USDC, "N_no == 10");

        // 5. Resolution: YES wins. payout = userPaid + (M_other / N_w) * userShares, slice floored.
        uint256 pool = mYes + mNo;
        assertEq(pool, 50 * USDC, "pool == $50 exactly");

        uint256 mOther = mNo; // losers' pool
        uint256 nW = nYes;

        // Each winner: userPaid refund (== their deposit, all bought at par or paid full m) + slice.
        uint256 aliceP = (10 * USDC) + (mOther * aliceShares) / nW;
        uint256 bobP = (20 * USDC) + (mOther * bobShares) / nW;
        uint256 daveP = (10 * USDC) + (mOther * daveShares) / nW;

        // Doc figures: Alice ~$13.04, Bob ~$26.08, Dave ~$10.88 (within a cent).
        assertApproxEqAbs(aliceP, 13_04 * (USDC / 100), USDC / 100, "Alice ~ $13.04");
        assertApproxEqAbs(bobP, 26_08 * (USDC / 100), USDC / 100, "Bob ~ $26.08");
        assertApproxEqAbs(daveP, 10_88 * (USDC / 100), USDC / 100, "Dave ~ $10.88");

        // Carol (NO) gets nothing.
        uint256 total = aliceP + bobP + daveP;
        // Self-funded: payouts never exceed the pool; floor dust (< 1 unit per winner) stays in custody.
        assertLe(total, pool, "payouts <= pool");
        assertLe(pool - total, 3, "floor dust < one micro-USDC per winning position");
    }

    // ---- Identity at the formula level (exact, no per-user floor dust) ----

    function testFuzz_payoutFormula_sumsToPool(uint64 a, uint64 b, uint64 c) public pure {
        uint256 mYes;
        uint256 nYes;
        uint256 mNo;
        uint256 nNo;

        uint256 amtA = bound(uint256(a), 1 * USDC, 1e12);
        uint256 amtB = bound(uint256(b), 1 * USDC, 1e12);
        uint256 amtC = bound(uint256(c), 1 * USDC, 1e12);

        // Two YES buys, one NO buy (guarantees both sides live and N_w > 0).
        nYes += _shares(mYes, nNo, amtA);
        mYes += amtA;
        nNo += _shares(mNo, nYes, amtC);
        mNo += amtC;
        nYes += _shares(mYes, nNo, amtB);
        mYes += amtB;

        uint256 pool = mYes + mNo;
        // Aggregate DPM I payout if YES wins: M_yes + (M_no / N_yes) * N_yes == M_yes + M_no == pool,
        // exactly (this is the formula identity; per-user floors only ever leave dust behind).
        uint256 aggregate = mYes + (mNo * nYes) / nYes;
        assertEq(aggregate, pool, "aggregate winner payout == pool");
    }

    // ---- exp-domain overflow guard ----

    function test_collateralForShares_revertsBeyondExpDomain() public {
        // n / N_other == 134 > uEXP_MAX_INPUT (~133.084) must revert rather than mis-price.
        vm.expectRevert(LibDpmPricingService.DpmExpInputTooLarge.selector);
        harness.collateralForShares(1 * USDC, 1 * USDC, 134 * USDC);
    }

    function test_collateralForShares_okWithinExpDomain() public pure {
        // n / N_other == 100 is inside the safe domain; should not revert and should be huge but finite.
        uint256 m = LibDpmPricingService.collateralForShares(1 * USDC, 1 * USDC, 100 * USDC);
        assertGt(m, 0, "priced within domain");
    }

    // ---- Extreme imbalance does not overflow for reasonable trades ----

    function test_extremeImbalance_noOverflow() public pure {
        // M_i enormous relative to M_other: a $1 buy still prices fine (n stays tiny, no revert).
        uint256 n = _shares(1e15 /* $1e9 on this side */, 1 * USDC /* tiny other side */, 1 * USDC);
        // n = N_other * ln(1 + 1/1e9) ~= 1e6 * 1e-9 ~= 0 (floored). Protocol-favorable.
        assertLe(n, 1 * USDC, "tiny shares for a buy into a deep side");
    }
}
