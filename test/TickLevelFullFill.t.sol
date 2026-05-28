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
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {MarketTradingData, Side, TickLevel, MarketOrderType} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title TickLevel totalQty regression tests
 * @notice Validates that tick level totalQty is correctly decremented to zero
 *         after fully-filled orders across all settlement paths: normal fill,
 *         mint-to-fill, merge-to-fill, and market orders.
 *
 *         Regression for: ghost orders caused by totalQty not being decremented
 *         when orders are fully filled (reduceOrderQty zeroed order.qty before
 *         dequeueOrder read it, causing removeOrderFromLevel to do totalQty -= 0).
 */
contract TickLevelFullFillTest is Test, DiamondSetup {
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

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

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

    /// @dev Seed defined mark price for the V2 market-order path.
    function _seedMark(uint256 tick) internal {
        uint256 q = 1e16;
        address seeder = address(0xBEEF1);
        collateral.mint(seeder, _collateral(tick, q));
        vm.prank(seeder);
        collateral.approve(address(diamond), _collateral(tick, q));
        vm.prank(seeder);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, q, 0);

        collateral.mint(seeder, q);
        vm.startPrank(seeder);
        collateral.approve(address(diamond), q);
        VaultFacet(address(diamond)).splitPosition(marketId, q);
        ctf.setApprovalForAll(address(diamond), true);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, q, 0);
        vm.stopPrank();

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

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
    // Normal fill: full fill clears tick level totalQty
    // -------------------------------------------------------------------------

    function test_normalFill_fullFill_tickLevelCleared() public {
        uint256 tick = 60;
        uint256 qty = 100e18;

        // ALICE places BUY @ tick 60
        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        // BOB places SELL @ tick 60 (exact cross)
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Verify tick levels have orders before matching
        TickLevel memory buyLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, tick);
        assertEq(buyLevelBefore.totalQty, qty, "buy totalQty before match");
        assertEq(buyLevelBefore.depth, 1, "buy depth before match");

        TickLevel memory sellLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, tick);
        assertEq(sellLevelBefore.totalQty, qty, "sell totalQty before match");
        assertEq(sellLevelBefore.depth, 1, "sell depth before match");

        // Match
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Tick levels must be fully cleared — no ghost orders
        TickLevel memory buyLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, tick);
        assertEq(buyLevelAfter.totalQty, 0, "buy totalQty must be 0 after full fill");
        assertEq(buyLevelAfter.depth, 0, "buy depth must be 0 after full fill");
        assertEq(buyLevelAfter.headOrderId, 0, "buy head must be 0 after full fill");

        TickLevel memory sellLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, tick);
        assertEq(sellLevelAfter.totalQty, 0, "sell totalQty must be 0 after full fill");
        assertEq(sellLevelAfter.depth, 0, "sell depth must be 0 after full fill");
        assertEq(sellLevelAfter.headOrderId, 0, "sell head must be 0 after full fill");

        // Top of book must reset to 0
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.BUY), 0, "buy top of book cleared");
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.SELL), 0, "sell top of book cleared");
    }

    // -------------------------------------------------------------------------
    // Normal fill: partial fill decrements totalQty correctly
    // -------------------------------------------------------------------------

    function test_normalFill_partialFill_tickLevelUpdated() public {
        uint256 tick = 50;
        uint256 bigQty = 200e18;
        uint256 smallQty = 80e18;

        // ALICE places a large BUY
        _mintAndApprove(ALICE, _collateral(tick, bigQty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, bigQty, 0);

        // BOB places a smaller SELL
        _splitForUser(BOB, bigQty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, smallQty, 0);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Buy tick level: partially filled, remaining = bigQty - smallQty
        TickLevel memory buyLevel = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, tick);
        assertEq(buyLevel.totalQty, bigQty - smallQty, "buy totalQty after partial fill");
        assertEq(buyLevel.depth, 1, "buy depth still 1 (partially filled order remains)");

        // Sell tick level: fully consumed
        TickLevel memory sellLevel = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, tick);
        assertEq(sellLevel.totalQty, 0, "sell totalQty must be 0 after full fill");
        assertEq(sellLevel.depth, 0, "sell depth must be 0");
    }

    // -------------------------------------------------------------------------
    // Mint-to-fill: full fill clears both YES and NO bid levels
    // -------------------------------------------------------------------------

    function test_mintFill_fullFill_tickLevelsCleared() public {
        uint256 yesTick = 60;
        uint256 noTick = 40; // sum = 100 = maxTick
        uint256 qty = 100e18;

        // ALICE buys YES @ 60
        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        // CAROL buys NO @ 40
        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        // Verify before
        TickLevel memory yesLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, yesTick);
        assertEq(yesLevelBefore.totalQty, qty, "YES buy totalQty before");

        TickLevel memory noLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 1, Side.BUY, noTick);
        assertEq(noLevelBefore.totalQty, qty, "NO buy totalQty before");

        // Match (mint-to-fill)
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Both tick levels must be fully cleared
        TickLevel memory yesLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, yesTick);
        assertEq(yesLevelAfter.totalQty, 0, "YES buy totalQty must be 0 after mint fill");
        assertEq(yesLevelAfter.depth, 0, "YES buy depth must be 0");

        TickLevel memory noLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 1, Side.BUY, noTick);
        assertEq(noLevelAfter.totalQty, 0, "NO buy totalQty must be 0 after mint fill");
        assertEq(noLevelAfter.depth, 0, "NO buy depth must be 0");

        // Top of book cleared
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.BUY), 0, "YES buy top cleared");
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 1, Side.BUY), 0, "NO buy top cleared");
    }

    // -------------------------------------------------------------------------
    // Merge-to-fill: full fill clears both YES and NO ask levels
    // -------------------------------------------------------------------------

    function test_mergeFill_fullFill_tickLevelsCleared() public {
        uint256 yesAsk = 55;
        uint256 noAsk = 40; // sum = 95 <= 100
        uint256 qty = 100e18;

        // ALICE holds YES tokens, BOB holds NO tokens
        _splitForUser(ALICE, qty);
        _splitForUser(BOB, qty);

        // ALICE sells YES @ 55
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        // BOB sells NO @ 40
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        // Verify before
        TickLevel memory yesLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, yesAsk);
        assertEq(yesLevelBefore.totalQty, qty, "YES sell totalQty before");

        TickLevel memory noLevelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 1, Side.SELL, noAsk);
        assertEq(noLevelBefore.totalQty, qty, "NO sell totalQty before");

        // Match (merge-to-fill)
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Both tick levels must be fully cleared
        TickLevel memory yesLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, yesAsk);
        assertEq(yesLevelAfter.totalQty, 0, "YES sell totalQty must be 0 after merge fill");
        assertEq(yesLevelAfter.depth, 0, "YES sell depth must be 0");

        TickLevel memory noLevelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 1, Side.SELL, noAsk);
        assertEq(noLevelAfter.totalQty, 0, "NO sell totalQty must be 0 after merge fill");
        assertEq(noLevelAfter.depth, 0, "NO sell depth must be 0");

        // Top of book cleared
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.SELL), 0, "YES sell top cleared");
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 1, Side.SELL), 0, "NO sell top cleared");
    }

    // -------------------------------------------------------------------------
    // Market order: full fill of sell order clears tick level
    // -------------------------------------------------------------------------

    function test_marketOrder_fullFill_tickLevelCleared() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 cost = _collateral(tick, qty);

        // BOB places a SELL limit order
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Verify sell tick level before
        TickLevel memory sellBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, tick);
        assertEq(sellBefore.totalQty, qty, "sell totalQty before market order");
        assertEq(sellBefore.depth, 1, "sell depth before market order");

        // Seed defined mark price (no fees in this venue setup, so this is fee-free).
        _seedMark(tick);

        // ALICE places a market BUY that consumes the entire sell order
        _mintAndApprove(ALICE, cost);
        vm.prank(ALICE);
        MarketOrdersFacet(address(diamond)).placeMarketBuy(marketId, 0, cost, 2000, MarketOrderType.FOK);

        // Sell tick level must be fully cleared
        TickLevel memory sellAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.SELL, tick);
        assertEq(sellAfter.totalQty, 0, "sell totalQty must be 0 after market order full fill");
        assertEq(sellAfter.depth, 0, "sell depth must be 0 after market order full fill");
        assertEq(sellAfter.headOrderId, 0, "sell head must be 0 after market order full fill");

        // Top of book cleared
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.SELL), 0, "sell top cleared");
    }

    // -------------------------------------------------------------------------
    // Multiple orders at same tick: full fill of one, other remains correct
    // -------------------------------------------------------------------------

    function test_normalFill_twoOrdersSameTick_oneFullyFilled() public {
        uint256 tick = 50;
        uint256 qty1 = 100e18;
        uint256 qty2 = 150e18;
        uint256 sellQty = 100e18; // exactly matches first buy

        // ALICE places first BUY
        _mintAndApprove(ALICE, _collateral(tick, qty1));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty1, 0);

        // CAROL places second BUY at same tick
        _mintAndApprove(CAROL, _collateral(tick, qty2));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty2, 0);

        // Verify combined totalQty
        TickLevel memory levelBefore = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, tick);
        assertEq(levelBefore.totalQty, qty1 + qty2, "combined totalQty before");
        assertEq(levelBefore.depth, 2, "two orders at tick");

        // BOB places SELL that matches exactly the first BUY (FIFO head)
        _splitForUser(BOB, sellQty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, sellQty, 0);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Buy tick level: first order fully consumed, second remains
        TickLevel memory levelAfter = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, tick);
        assertEq(levelAfter.totalQty, qty2, "totalQty must equal remaining second order");
        assertEq(levelAfter.depth, 1, "depth must be 1 (one order remains)");

        // Top of book still active
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.BUY), tick, "buy top still at tick");
    }
}
