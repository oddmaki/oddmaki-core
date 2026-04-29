// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {MarketTradingData, Order, Side} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Matching integration tests
 * @notice Tests MatchingFacet.matchOrders: normal fill, mint-to-fill, merge-to-fill,
 *         partial fill, no-match, and inline expiry cleanup.
 */
contract MatchingTest is Test, DiamondSetup {
    // Event declarations for vm.expectEmit / vm.recordLogs
    event TradeExecuted(
        uint256 indexed marketId,
        uint256 indexed outcomeId,
        uint256 indexed fillId,
        uint256 priceTick,
        uint256 quantity,
        uint256 cumulativeVolume,
        uint256 timestamp
    );
    event MintFill(
        uint256 indexed marketId,
        uint256 qty,
        uint256 yesOrderId,
        uint256 noOrderId,
        uint256 yesTick,
        uint256 noTick
    );
    event MergeFill(
        uint256 indexed marketId,
        uint256 qty,
        uint256 yesOrderId,
        uint256 noOrderId,
        uint256 yesTick,
        uint256 noTick
    );

    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16; // 1 tick = 1%
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE; // 100

    address constant ALICE = address(0xA11CE); // buyer / YES seller
    address constant BOB = address(0xB0B); // seller / NO seller
    address constant CAROL = address(0xCA801); // second buyer / NO buyer

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Collateral locked for a BUY order at (tick, qty).
    function _collateral(uint256 tick, uint256 qty) internal pure returns (uint256) {
        return (tick * qty * TICK_SIZE) / 1e18;
    }

    /// @dev Mint collateral to user and approve Diamond.
    function _mintAndApprove(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(diamond), amount);
    }

    /// @dev Give outcome tokens to user via split (Diamond holds the rest if split > needed).
    function _splitForUser(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.startPrank(user);
        collateral.approve(address(diamond), amount);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        ctf.setApprovalForAll(address(diamond), true);
        vm.stopPrank();
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
    // Normal fill
    // -------------------------------------------------------------------------

    function test_normalFill_yesOutcome() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty); // collateral locked by buyer

        // ALICE places BUY order for YES @ tick 60
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        // BOB places SELL order for YES @ tick 60 (exact cross)
        _splitForUser(BOB, qty); // gives BOB qty YES + qty NO tokens
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        uint256 aliceColBefore = collateral.balanceOf(ALICE);
        uint256 bobColBefore = collateral.balanceOf(BOB);
        uint256 aliceYesBefore = ctf.balanceOf(ALICE, positionIds[0]);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        assertEq(fillCount, 1, "one fill");

        // Buyer (ALICE) receives YES tokens
        assertEq(ctf.balanceOf(ALICE, positionIds[0]) - aliceYesBefore, qty, "ALICE received YES");

        // Seller (BOB) receives collateral (at ask price = tick = 60)
        uint256 sellerPayout = _collateral(tick, qty);
        assertEq(collateral.balanceOf(BOB) - bobColBefore, sellerPayout, "BOB received collateral");

        // Both orders fully consumed (no residual orders)
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 0, "buy order deleted");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(2).id, 0, "sell order deleted");
    }

    function test_normalFill_buyerSurplusRefunded() public {
        uint256 buyTick = 70;
        uint256 sellTick = 60;
        uint256 qty = 100e18;

        // ALICE places BUY @ tick 70 (locks 0.70 USDC/token)
        _mintAndApprove(ALICE, _collateral(buyTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, buyTick, qty, 0);

        // BOB places SELL @ tick 60 (willing to sell at 0.60 USDC/token)
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, sellTick, qty, 0);

        uint256 aliceColBefore = collateral.balanceOf(ALICE);
        uint256 bobColBefore = collateral.balanceOf(BOB);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "one fill");

        // Buyer (ALICE) receives YES tokens
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), qty, "ALICE received YES");

        // Buyer (ALICE) receives surplus refund: (70 - 60) ticks worth of collateral
        uint256 expectedSurplus = _collateral(buyTick, qty) - _collateral(sellTick, qty);
        assertEq(collateral.balanceOf(ALICE) - aliceColBefore, expectedSurplus, "ALICE surplus refunded");

        // Seller (BOB) receives collateral at ask price (tick 60)
        assertEq(collateral.balanceOf(BOB) - bobColBefore, _collateral(sellTick, qty), "BOB received collateral at ask");

        // Both orders fully consumed
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 0, "buy order deleted");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(2).id, 0, "sell order deleted");
    }

    function test_normalFill_partialFill() public {
        uint256 tick = 50;
        uint256 bigQty = 200e18;
        uint256 smallQty = 80e18;
        uint256 bigCol = _collateral(tick, bigQty);
        uint256 smallCol = _collateral(tick, smallQty);

        // ALICE places a large BUY
        _mintAndApprove(ALICE, bigCol);
        vm.prank(ALICE);
        uint256 buyId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, bigQty, 0);

        // BOB places a smaller SELL
        _splitForUser(BOB, bigQty); // split enough for the whole big buy (we only use smallQty for sell)
        vm.prank(BOB);
        uint256 sellId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, smallQty, 0);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "one fill");

        // BOB's smaller order is fully consumed
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(sellId).id, 0, "sell order deleted");

        // ALICE's order is partially filled (remaining qty = bigQty - smallQty)
        Order memory remaining = LimitOrdersFacet(address(diamond)).getOrder(buyId);
        assertEq(remaining.qty, bigQty - smallQty, "buy order partially filled");

        // BOB received collateral for smallQty at tick price
        assertEq(collateral.balanceOf(BOB), smallCol, "BOB received partial payout");

        // ALICE received smallQty YES tokens
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), smallQty, "ALICE received partial YES");
    }

    // -------------------------------------------------------------------------
    // Mint-to-fill
    // -------------------------------------------------------------------------

    function test_mintToFill_bothBuyersGetTokens() public {
        uint256 yesTick = 60; // 60%
        uint256 noTick = 40; // 40% — sum = 100 = maxTick ✓
        uint256 qty = 100e18;

        uint256 yesCol = _collateral(yesTick, qty);
        uint256 noCol = _collateral(noTick, qty);

        // ALICE buys YES @ 60
        _mintAndApprove(ALICE, yesCol);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        // CAROL buys NO @ 40
        _mintAndApprove(CAROL, noCol);
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "one mint fill");

        // ALICE receives YES tokens, CAROL receives NO tokens
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), qty, "ALICE received YES");
        assertEq(ctf.balanceOf(CAROL, positionIds[1]), qty, "CAROL received NO");

        // Both buy orders consumed
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 0, "YES order deleted");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(2).id, 0, "NO order deleted");
    }

    // -------------------------------------------------------------------------
    // Merge-to-fill
    // -------------------------------------------------------------------------

    function test_mergeToFill_bothSellersGetCollateral() public {
        uint256 yesAsk = 55; // 55%
        uint256 noAsk = 40; // 40% — sum = 95 ≤ 100 = maxTick ✓
        uint256 qty = 100e18;

        // ALICE holds YES tokens, BOB holds NO tokens — obtained via split
        _splitForUser(ALICE, qty); // gives ALICE qty YES + qty NO
        _splitForUser(BOB, qty); // gives BOB   qty YES + qty NO

        // ALICE sells YES @ 55
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        // BOB sells NO @ 40
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        uint256 aliceColBefore = collateral.balanceOf(ALICE);
        uint256 bobColBefore = collateral.balanceOf(BOB);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "one merge fill");

        // Each seller receives collateral at their ask price
        assertEq(collateral.balanceOf(ALICE) - aliceColBefore, _collateral(yesAsk, qty), "ALICE payout");
        assertEq(collateral.balanceOf(BOB) - bobColBefore, _collateral(noAsk, qty), "BOB payout");

        // Sell orders consumed
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 0, "YES sell deleted");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(2).id, 0, "NO sell deleted");
    }

    // -------------------------------------------------------------------------
    // No-match
    // -------------------------------------------------------------------------

    function test_matchOrders_noMatch_returnsZero() public {
        uint256 qty = 100e18;

        // ALICE buys YES @ 40, BOB sells YES @ 60 — no cross (bid < ask)
        _mintAndApprove(ALICE, _collateral(40, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 40, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 60, qty, 0);

        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "no fills when bid < ask");
    }

    // -------------------------------------------------------------------------
    // Inline expiry during matching
    // -------------------------------------------------------------------------

    function test_matchOrders_expiredOrderSkipped() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        // ALICE places a BUY order that expires in 1 hour
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        uint256 expiry = block.timestamp + 1 hours;
        uint256 expiredBuyId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, expiry);

        // CAROL places a second BUY order (GTC — never expires) at same tick
        _mintAndApprove(CAROL, col);
        vm.prank(CAROL);
        uint256 activeBuyId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        // BOB places a SELL order at same tick
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Advance time past ALICE's expiry
        vm.warp(expiry + 1);

        // Match: ALICE's expired BUY is at the head of the FIFO queue
        // It should be cleaned up inline; CAROL's active order should fill with BOB's SELL
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // ALICE's order was expired inline (full refund)
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(expiredBuyId).id, 0, "expired order removed");
        assertEq(collateral.balanceOf(ALICE), col, "ALICE refunded on expiry");

        // CAROL's order filled with BOB
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(activeBuyId).id, 0, "CAROL order filled");
        assertEq(ctf.balanceOf(CAROL, positionIds[0]), qty, "CAROL received YES tokens");
        assertEq(fillCount, 1, "one fill (not counting expired cleanup)");
    }

    // -------------------------------------------------------------------------
    // Trade recording & events
    // -------------------------------------------------------------------------

    function test_mintToFill_recordsLastTradeTick() public {
        uint256 yesTick = 60;
        uint256 noTick = 40;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertEq(td.lastTradeTick[0], yesTick, "YES lastTradeTick should be yesBid");
        assertEq(td.lastTradeTick[1], noTick, "NO lastTradeTick should be noBid");
    }

    function test_normalFill_emitsTradeExecuted() public {
        uint256 tick = 60;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        vm.recordLogs();
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 tradeExecutedTopic = keccak256("TradeExecuted(uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == tradeExecutedTopic) count++;
        }
        assertEq(count, 1, "NormalFill should emit one TradeExecuted");
    }

    function test_mintFill_emitsTradeExecuted() public {
        uint256 yesTick = 60;
        uint256 noTick = 40;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.recordLogs();
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 tradeExecutedTopic = keccak256("TradeExecuted(uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == tradeExecutedTopic) count++;
        }
        assertEq(count, 2, "MintFill should emit two TradeExecuted events (one per outcome)");
    }

    function test_mergeFill_doesNotEmitTradeExecuted() public {
        uint256 yesAsk = 55;
        uint256 noAsk = 40;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        _splitForUser(BOB, qty);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        vm.recordLogs();
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 tradeExecutedTopic = keccak256("TradeExecuted(uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != tradeExecutedTopic, "MergeFill should NOT emit TradeExecuted");
        }
    }

    function test_mintFill_eventIncludesTicks() public {
        uint256 yesTick = 60;
        uint256 noTick = 40;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.recordLogs();
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 mintFillTopic = keccak256("MintFill(uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == mintFillTopic) {
                found = true;
                // Decode non-indexed params: qty, yesOrderId, noOrderId, yesTick, noTick
                (uint256 emittedQty,, , uint256 emittedYesTick, uint256 emittedNoTick) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(emittedQty, qty, "MintFill qty");
                assertEq(emittedYesTick, yesTick, "MintFill yesTick");
                assertEq(emittedNoTick, noTick, "MintFill noTick");
            }
        }
        assertTrue(found, "MintFill event should be emitted");
    }

    // -------------------------------------------------------------------------
    // M-3: Venue pause halts matching
    // -------------------------------------------------------------------------

    function test_M3_matchOrders_revertsWhenVenuePaused() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        // Place crossing orders while venue is active
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Pause the venue
        VenueFacet(address(diamond)).pauseVenue(venueId);

        // matchOrders should revert
        vm.expectRevert(LibVenueValidator.VenueInactive.selector);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    function test_M3_matchOrders_succeedsAfterUnpause() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Pause then unpause
        VenueFacet(address(diamond)).pauseVenue(venueId);
        VenueFacet(address(diamond)).unpauseVenue(venueId);

        // Should succeed after unpause
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "one fill after unpause");
    }
}
