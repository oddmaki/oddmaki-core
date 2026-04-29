// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {MarketTradingData, Side, MatchPreview} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title MatchingPreview integration tests
 * @notice Tests OrderBookFacet.canMatchOrders: verifies that the view function
 *         correctly identifies matchable state for all three fill paths.
 */
contract MatchingPreviewTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

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

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        marketId =
            MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // -------------------------------------------------------------------------
    // Empty book
    // -------------------------------------------------------------------------

    function test_emptyBook_nothingMatchable() public view {
        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.normalYesCross, "no YES cross on empty book");
        assertFalse(p.normalNoCross, "no NO cross on empty book");
        assertFalse(p.mintFeasible, "no mint on empty book");
        assertFalse(p.mergeFeasible, "no merge on empty book");
        assertFalse(p.anyMatchable, "nothing matchable on empty book");
        assertEq(p.yesBestBid, 0);
        assertEq(p.yesBestAsk, 0);
        assertEq(p.noBestBid, 0);
        assertEq(p.noBestAsk, 0);
    }

    // -------------------------------------------------------------------------
    // Normal fill: YES outcome crossing
    // -------------------------------------------------------------------------

    function test_normalYesCross() public {
        uint256 qty = 100e18;

        // BUY YES @ tick 60
        _mintAndApprove(ALICE, _collateral(60, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 60, qty, 0);

        // SELL YES @ tick 55
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 55, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertTrue(p.normalYesCross, "YES should cross: bid 60 >= ask 55");
        assertFalse(p.normalNoCross, "NO has no orders");
        assertFalse(p.mintFeasible, "no NO bid for mint");
        assertFalse(p.mergeFeasible, "no NO ask for merge");
        assertTrue(p.anyMatchable, "should be matchable");
        assertEq(p.yesBestBid, 60);
        assertEq(p.yesBestAsk, 55);
    }

    // -------------------------------------------------------------------------
    // Normal fill: NO outcome crossing
    // -------------------------------------------------------------------------

    function test_normalNoCross() public {
        uint256 qty = 100e18;

        // BUY NO @ tick 50
        _mintAndApprove(ALICE, _collateral(50, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, 50, qty, 0);

        // SELL NO @ tick 45
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, 45, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.normalYesCross, "YES has no orders");
        assertTrue(p.normalNoCross, "NO should cross: bid 50 >= ask 45");
        assertTrue(p.anyMatchable, "should be matchable");
        assertEq(p.noBestBid, 50);
        assertEq(p.noBestAsk, 45);
    }

    // -------------------------------------------------------------------------
    // Non-crossing spread: no match
    // -------------------------------------------------------------------------

    function test_nonCrossingSpread() public {
        uint256 qty = 100e18;

        // BUY YES @ tick 40
        _mintAndApprove(ALICE, _collateral(40, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 40, qty, 0);

        // SELL YES @ tick 60
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 60, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.normalYesCross, "bid 40 < ask 60, no cross");
        assertFalse(p.anyMatchable, "should not be matchable");
        assertEq(p.yesBestBid, 40);
        assertEq(p.yesBestAsk, 60);
    }

    // -------------------------------------------------------------------------
    // Mint-to-fill feasibility
    // -------------------------------------------------------------------------

    function test_mintFeasible() public {
        uint256 qty = 100e18;

        // BUY YES @ tick 55
        _mintAndApprove(ALICE, _collateral(55, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 55, qty, 0);

        // BUY NO @ tick 55
        _mintAndApprove(BOB, _collateral(55, qty));
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, 55, qty, 0);

        // 55 + 55 = 110 ticks. Full price = 100 ticks.
        // With fees (~130 bps default), min required ~101.3 ticks. 110 >= 101.3, feasible.
        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertTrue(p.mintFeasible, "mint should be feasible: 55+55=110 > ~101");
        assertFalse(p.normalYesCross, "no YES sell orders");
        assertFalse(p.normalNoCross, "no NO sell orders");
        assertTrue(p.anyMatchable, "should be matchable");
    }

    function test_mintNotFeasible_bidsTooLow() public {
        uint256 qty = 100e18;

        // BUY YES @ tick 40
        _mintAndApprove(ALICE, _collateral(40, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 40, qty, 0);

        // BUY NO @ tick 40
        _mintAndApprove(BOB, _collateral(40, qty));
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, 40, qty, 0);

        // 40 + 40 = 80 < 100 + fees. Not feasible.
        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.mintFeasible, "mint not feasible: 40+40=80 < ~101");
        assertFalse(p.anyMatchable, "should not be matchable");
    }

    // -------------------------------------------------------------------------
    // Merge-to-fill feasibility
    // -------------------------------------------------------------------------

    function test_mergeFeasible() public {
        uint256 qty = 100e18;

        // SELL YES @ tick 40
        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 40, qty, 0);

        // SELL NO @ tick 40
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, 40, qty, 0);

        // 40 + 40 = 80 ticks. Full price = 100 ticks.
        // With fees (~130 bps default), max allowed ~98.7 ticks. 80 <= 98.7, feasible.
        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertTrue(p.mergeFeasible, "merge should be feasible: 40+40=80 < ~99");
        assertFalse(p.normalYesCross, "no YES buy orders");
        assertFalse(p.normalNoCross, "no NO buy orders");
        assertTrue(p.anyMatchable, "should be matchable");
    }

    function test_mergeNotFeasible_asksTooHigh() public {
        uint256 qty = 100e18;

        // SELL YES @ tick 55
        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 55, qty, 0);

        // SELL NO @ tick 55
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, 55, qty, 0);

        // 55 + 55 = 110 > 100 - fees. Not feasible.
        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.mergeFeasible, "merge not feasible: 55+55=110 > ~99");
        assertFalse(p.anyMatchable, "should not be matchable");
    }

    // -------------------------------------------------------------------------
    // Head order expiry detection
    // -------------------------------------------------------------------------

    function test_expiredHeadOrder_flagged() public {
        uint256 qty = 100e18;
        uint256 expiry = block.timestamp + 100;

        // BUY YES @ tick 60 with expiry
        _mintAndApprove(ALICE, _collateral(60, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 60, qty, expiry);

        // SELL YES @ tick 55 (GTC)
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 55, qty, 0);

        // Before expiry: crossing exists, head not expired
        MatchPreview memory preExpiry = OrderBookFacet(address(diamond)).canMatchOrders(marketId);
        assertTrue(preExpiry.normalYesCross, "should cross before expiry");
        assertFalse(preExpiry.yesBidHeadExpired, "head not expired yet");
        assertTrue(preExpiry.anyMatchable, "should be matchable");

        // Warp past expiry
        vm.warp(expiry + 1);

        // After expiry: crossing still shows (top-of-book unchanged) but head is flagged expired
        MatchPreview memory postExpiry = OrderBookFacet(address(diamond)).canMatchOrders(marketId);
        assertTrue(postExpiry.normalYesCross, "top-of-book still crosses");
        assertTrue(postExpiry.yesBidHeadExpired, "head should be flagged expired");
        assertTrue(postExpiry.anyMatchable, "anyMatchable still true (false negatives worse than false positives)");
    }

    // -------------------------------------------------------------------------
    // One-sided book: only bids or only asks
    // -------------------------------------------------------------------------

    function test_onlyBids_noMatch() public {
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(60, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 60, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.normalYesCross, "no ask to cross with");
        assertFalse(p.anyMatchable, "one-sided book not matchable");
        assertEq(p.yesBestBid, 60);
        assertEq(p.yesBestAsk, 0);
    }

    function test_onlyAsks_noMatch() public {
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 55, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertFalse(p.normalYesCross, "no bid to cross with");
        assertFalse(p.anyMatchable, "one-sided book not matchable");
        assertEq(p.yesBestBid, 0);
        assertEq(p.yesBestAsk, 55);
    }

    // -------------------------------------------------------------------------
    // Multiple paths matchable simultaneously
    // -------------------------------------------------------------------------

    function test_multiplePaths() public {
        uint256 qty = 100e18;

        // Normal YES cross: BUY@60 vs SELL@55
        _mintAndApprove(ALICE, _collateral(60, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 60, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 55, qty, 0);

        // Mint path: also place a NO BUY@55 (YES BUY@60 + NO BUY@55 = 115 > ~101)
        _mintAndApprove(BOB, _collateral(55, qty));
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, 55, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertTrue(p.normalYesCross, "YES should cross");
        assertTrue(p.mintFeasible, "mint should be feasible");
        assertTrue(p.anyMatchable, "should be matchable");
    }

    // -------------------------------------------------------------------------
    // Exact tick crossing (bid == ask)
    // -------------------------------------------------------------------------

    function test_exactTickCrossing() public {
        uint256 qty = 100e18;
        uint256 tick = 50;

        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        MatchPreview memory p = OrderBookFacet(address(diamond)).canMatchOrders(marketId);

        assertTrue(p.normalYesCross, "bid == ask should cross");
        assertTrue(p.anyMatchable, "should be matchable");
        assertEq(p.yesBestBid, tick);
        assertEq(p.yesBestAsk, tick);
    }
}
