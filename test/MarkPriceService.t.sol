// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketTradingData, Side} from "../src/interfaces/Types.sol";
import {LibMarkPriceService} from "../src/services/LibMarkPriceService.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title LibMarkPriceService integration tests
 * @notice Covers the on-chain mark-price waterfall introduced in PR 2:
 *           1. Implied midpoint via cross-outcome complement (mint/merge).
 *           2. Last-trade fallback with complement of the other outcome.
 *           3. Honest "(0, false)" when neither path yields a defensible price.
 *
 *         Exercised via `OrderBookFacet.getMarkPrice` (which delegates to the
 *         library) so the same selector covers both the library and the
 *         external-read surface.
 */
contract MarkPriceServiceTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16; // 1 tick = 1%
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE; // 100

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA801);

    function _collateral(uint256 tick, uint256 qty) internal pure returns (uint256) {
        return (tick * qty * TICK_SIZE) / 1e18;
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(diamond), amount);
    }

    function _splitForUser(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.startPrank(user);
        collateral.approve(address(diamond), amount);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        ctf.setApprovalForAll(address(diamond), true);
        vm.stopPrank();
    }

    function _place(address user, uint256 outcomeId, Side side, uint256 tick, uint256 qty) internal {
        vm.prank(user);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, outcomeId, side, tick, qty, 0);
    }

    function _getMark(uint256 outcomeId) internal view returns (uint256 tick, bool defined) {
        return OrderBookFacet(address(diamond)).getMarkPrice(marketId, outcomeId);
    }

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Up";
        outcomes[1] = "Down";
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // =========================================================================
    // 1. Direct top-of-book midpoint (parity with the legacy implementation)
    // =========================================================================

    function test_directMidpoint_tightSpread_returnsMid() public {
        // YES bid=48, YES ask=52 ->spread 4 ≤ 10 ->mid = 50
        _mintAndApprove(ALICE, _collateral(48, 100e18));
        _place(ALICE, 0, Side.BUY, 48, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 52, 100e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertTrue(defined, "tight direct spread defines mark");
        assertEq(tick, 50, "midpoint of 48/52");
    }

    function test_directMidpoint_atSpreadThreshold_returnsMid() public {
        // bid=45, ask=55 ->spread = 10 = threshold ->still returns mid
        _mintAndApprove(ALICE, _collateral(45, 100e18));
        _place(ALICE, 0, Side.BUY, 45, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 55, 100e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertTrue(defined, "spread at exactly threshold defines mark");
        assertEq(tick, 50);
    }

    // =========================================================================
    // 2. Cross-outcome implied midpoint (the user's reported scenario)
    // =========================================================================

    /// @notice The case `OrderBookFacet.getMarkPrice` could not handle before
    ///         PR 2: only one outcome has direct liquidity, but the *other*
    ///         outcome's complement defines an implied midpoint within spread.
    function test_impliedMidpoint_crossOutcomeComplement_definesMark() public {
        // Up has a BUY at 47 (direct YES bid = 47).
        // Down has a SELL at 45 (direct NO ask = 45 ->implied YES bid = 100 - 45 = 55).
        // No Down BUY (no implied YES ask via mint) so we still need a direct YES ask.
        //
        // Add an Up SELL at 60 (direct YES ask = 60). impliedAsk = 60.
        // impliedBid = max(47, 55) = 55. Spread = 60 - 55 = 5 ≤ 10 ->mid = 57.
        _mintAndApprove(ALICE, _collateral(47, 100e18));
        _place(ALICE, 0, Side.BUY, 47, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 1, Side.SELL, 45, 100e18);

        _splitForUser(CAROL, 100e18);
        _place(CAROL, 0, Side.SELL, 60, 100e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertTrue(defined, "cross-outcome complement defines implied mark");
        // impliedBid = max(47, 55) = 55, impliedAsk = min(60, NA) = 60, mid = 57
        assertEq(tick, 57, "implied midpoint via merge complement");
    }

    /// @notice When the only YES ask is the mint complement of NO's bid, the
    ///         implied ask is well-defined even with no direct YES ask.
    function test_impliedMidpoint_mintComplementOnly_definesMark() public {
        // Up BUY at 48 (direct YES bid = 48).
        // Down BUY at 50 (direct NO bid = 50 ->implied YES ask = 100 - 50 = 50).
        // No direct YES ask, no direct NO ask.
        // impliedBid = 48, impliedAsk = 50, spread 2 ≤ 10 ->mid = 49.
        _mintAndApprove(ALICE, _collateral(48, 100e18));
        _place(ALICE, 0, Side.BUY, 48, 100e18);

        _mintAndApprove(CAROL, _collateral(50, 100e18));
        _place(CAROL, 1, Side.BUY, 50, 100e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertTrue(defined, "mint complement alone defines ask");
        assertEq(tick, 49, "midpoint of 48/50");
    }

    /// @notice User's exact reported book: Up bid @47, Down bids @53 and @54,
    ///         no asks anywhere. impliedAsk = min(NA, 100 − 54) = 46.
    ///         impliedBid = 47. The implied book is *crossed* (47 > 46), which
    ///         means the matching engine should mint-fill this — so the
    ///         midpoint branch is rejected and we fall through to last trade.
    ///         With no trades yet, return (0, false) honestly.
    function test_userScenario_crossedImpliedBook_fallsThroughToUndefined() public {
        _mintAndApprove(ALICE, _collateral(47, 100e18));
        _place(ALICE, 0, Side.BUY, 47, 100e18);

        _mintAndApprove(BOB, _collateral(53, 100e18));
        _place(BOB, 1, Side.BUY, 53, 100e18);

        _mintAndApprove(CAROL, _collateral(54, 100e18));
        _place(CAROL, 1, Side.BUY, 54, 100e18);

        (uint256 tickUp, bool definedUp) = _getMark(0);
        (uint256 tickDown, bool definedDown) = _getMark(1);

        // Implied book is crossed ->no midpoint. No trades ->no fallback.
        // Honest "(0, false)" matches the design contract.
        assertFalse(definedUp, "crossed implied book + no trades = undefined Up");
        assertEq(tickUp, 0);
        assertFalse(definedDown, "crossed implied book + no trades = undefined Down");
        assertEq(tickDown, 0);
    }

    // =========================================================================
    // 3. Wide-spread rejection (the Polymarket "55%" trap)
    // =========================================================================

    /// @notice Reproduces the Polymarket screenshot: bid=15, ask=95, spread=80,
    ///         no trades. Honest answer is "undefined" — not a fabricated mid.
    function test_wideSpread_noTrades_returnsUndefined() public {
        _mintAndApprove(ALICE, _collateral(15, 100e18));
        _place(ALICE, 0, Side.BUY, 15, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 95, 100e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertFalse(defined, "wide spread without trades must be undefined");
        assertEq(tick, 0);
    }

    function test_wideSpread_withLastTrade_fallsBackToLastTrade() public {
        // Seed a trade so last-trade fallback has data
        _mintAndApprove(ALICE, _collateral(50, 100e18));
        _place(ALICE, 0, Side.BUY, 50, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 50, 100e18);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Now widen the book to trigger wide-spread rejection
        _mintAndApprove(ALICE, _collateral(20, 50e18));
        _place(ALICE, 0, Side.BUY, 20, 50e18);

        _splitForUser(CAROL, 50e18);
        _place(CAROL, 0, Side.SELL, 90, 50e18);

        (uint256 tick, bool defined) = _getMark(0);
        assertTrue(defined, "wide spread but last trade exists ->fallback");
        assertEq(tick, 50, "last trade tick");
    }

    // =========================================================================
    // 4. Last-trade fallback — complement when other outcome traded last
    // =========================================================================

    function test_lastTradeFallback_complementOfOtherOutcome() public {
        // Trade only on Down at tick 30. Query mark for Up.
        // Up has no direct trade; Down's last trade was 30 ->Up mark = 100 - 30 = 70.
        _mintAndApprove(ALICE, _collateral(30, 100e18));
        _place(ALICE, 1, Side.BUY, 30, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 1, Side.SELL, 30, 100e18);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Verify Down last trade tick is 30
        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertEq(td.lastTradeTick[1], 30, "Down last trade");
        assertEq(td.lastTradeTick[0], 0, "Up has no direct trade");

        (uint256 tickUp, bool defUp) = _getMark(0);
        assertTrue(defUp, "Up mark falls back to complement of Down's last trade");
        assertEq(tickUp, 70);
    }

    function test_lastTradeFallback_prefersDirectOverComplement() public {
        // Both outcomes have a last trade — direct wins regardless of recency
        // (we don't have on-chain timestamps; this asserts the documented contract).
        _mintAndApprove(ALICE, _collateral(40, 100e18));
        _place(ALICE, 0, Side.BUY, 40, 100e18);
        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 40, 100e18);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        _mintAndApprove(CAROL, _collateral(35, 100e18));
        _place(CAROL, 1, Side.BUY, 35, 100e18);
        address dave = address(0xDA7E);
        _splitForUser(dave, 100e18);
        _place(dave, 1, Side.SELL, 35, 100e18);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Wipe the books so spread-based mid doesn't kick in
        // (both fills consumed everything ->no resting orders ->wide implied "spread")
        (uint256 tickUp,  bool defUp)  = _getMark(0);
        (uint256 tickDn,  bool defDn)  = _getMark(1);

        assertTrue(defUp,  "Up direct last trade");
        assertEq(tickUp, 40, "Up uses direct last trade tick");
        assertTrue(defDn,  "Down direct last trade");
        assertEq(tickDn, 35, "Down uses direct last trade tick");
    }

    // =========================================================================
    // 5. No data ->undefined
    // =========================================================================

    function test_emptyMarket_returnsUndefined() public {
        (uint256 tick, bool defined) = _getMark(0);
        assertFalse(defined);
        assertEq(tick, 0);
    }

    // =========================================================================
    // 6. Tick-size-aware spread threshold
    // =========================================================================

    /// @notice Pure-function test of the threshold scaler — verifies the
    ///         "$0.10 absolute" invariant holds at non-standard tick sizes.
    function test_getMaxSpreadTicks_scaling() public {
        // Standard tickSize ->10 ticks ($0.10)
        assertEq(LibMarkPriceService.getMaxSpreadTicks(1e16), 10);
        // Fine tickSize (0.1%) ->100 ticks ($0.10)
        assertEq(LibMarkPriceService.getMaxSpreadTicks(1e15), 100);
        // Coarse tickSize (2%) ->5 ticks ($0.10)
        assertEq(LibMarkPriceService.getMaxSpreadTicks(2e16), 5);
        // Zero tick size guarded (returns base)
        assertEq(LibMarkPriceService.getMaxSpreadTicks(0), 10);
    }

    // =========================================================================
    // 7. Implied top-of-book primitive
    // =========================================================================

    function test_getImpliedTopOfBook_emptyMarket() public {
        (uint256 bid, uint256 ask) = OrderBookFacet(address(diamond)).getImpliedTopOfBook(marketId, 0);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_getImpliedTopOfBook_combinesDirectAndComplement() public {
        // Direct YES bid = 40. Direct NO ask = 55 ->merge complement = 100 - 55 = 45.
        //   ->impliedBid = max(40, 45) = 45.
        // Direct YES ask = 60. Direct NO bid = 38 ->mint complement = 100 - 38 = 62.
        //   ->impliedAsk = min(60, 62) = 60.
        _mintAndApprove(ALICE, _collateral(40, 100e18));
        _place(ALICE, 0, Side.BUY, 40, 100e18);

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 60, 100e18);

        _mintAndApprove(CAROL, _collateral(38, 100e18));
        _place(CAROL, 1, Side.BUY, 38, 100e18);

        address dave = address(0xDA7E);
        _splitForUser(dave, 100e18);
        _place(dave, 1, Side.SELL, 55, 100e18);

        (uint256 bid, uint256 ask) = OrderBookFacet(address(diamond)).getImpliedTopOfBook(marketId, 0);
        assertEq(bid, 45, "impliedBid = max(direct 40, merge complement 45)");
        assertEq(ask, 60, "impliedAsk = min(direct 60, mint complement 62)");
    }
}
