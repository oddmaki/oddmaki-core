// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {MarketTradingData, Side, Fill, SettlementPath, MarketOrderType, MarketSellResult} from "../src/interfaces/Types.sol";
import {LibMarketOrderValidator} from "../src/validators/LibMarketOrderValidator.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Market sell order integration tests
 * @notice Tests market sell execution (Normal Fill only) with FOK/FAK semantics,
 *         fee integration, expired order cleanup, and edge cases.
 */
contract MarketSellOrdersTest is Test, DiamondSetup {
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
    address constant TREASURY = address(0x7EA5);
    address constant FEE_RECIPIENT = address(0xFEE);
    address constant MARKET_CREATOR = address(0xC8EA);

    // Fee config: 100 bps venue, 30 bps creator
    uint256 constant VENUE_FEE_BPS = 100;
    uint256 constant CREATOR_FEE_BPS = 30;
    uint256 constant PROTOCOL_FEE_BPS = 50;
    uint256 constant OPERATOR_FEE_BPS = 10;
    uint256 constant TOTAL_FEE_BPS = PROTOCOL_FEE_BPS + VENUE_FEE_BPS + OPERATOR_FEE_BPS; // 160
    uint256 constant BPS_DENOMINATOR = 10_000;

    // =========================================================================
    // Helpers
    // =========================================================================

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

    function _placeBuyOrder(address buyer, uint256 tick, uint256 qty) internal returns (uint256) {
        uint256 collateralNeeded = _collateral(tick, qty);
        _mintAndApprove(buyer, collateralNeeded);
        vm.prank(buyer);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
    }

    function _marketSell(address seller, uint256 tokenAmount, uint256 minTick, MarketOrderType ot)
        internal
        returns (MarketSellResult memory)
    {
        _splitForUser(seller, tokenAmount);
        vm.prank(seller);
        return MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, tokenAmount, minTick, ot);
    }

    // =========================================================================
    // Setup (fees enabled)
    // =========================================================================

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);
        ProtocolFacet(address(diamond)).setProtocolFeeBps(PROTOCOL_FEE_BPS);

        vm.prank(MARKET_CREATOR);
        venueId = VenueFacet(address(diamond)).createVenue(
            "MS Test Venue", "", address(0), address(0), FEE_RECIPIENT,
            VENUE_FEE_BPS, CREATOR_FEE_BPS, TICK_SIZE, 5e6, 0, 1e6
        );

        uint256 creationFee = 5e6;
        collateral.mint(MARKET_CREATOR, creationFee);
        vm.prank(MARKET_CREATOR);
        collateral.approve(address(diamond), creationFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(MARKET_CREATOR);
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // =========================================================================
    // Basic functionality
    // =========================================================================

    function test_marketSell_singleFill() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        MarketSellResult memory r = _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        assertEq(r.tokensSold, qty, "tokens sold");
        assertEq(r.unsoldTokens, 0, "no unsold tokens");
        assertGt(r.collateralReceived, 0, "received collateral");
        assertGt(r.avgPrice, 0, "avg price set");
    }

    function test_marketSell_sellerReceivesCollateral() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        uint256 before = collateral.balanceOf(ALICE);
        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        uint256 proceeds = _collateral(tick, qty);
        uint256 expectedTotalFee = (proceeds * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedSellerPayout = proceeds - expectedTotalFee;
        uint256 operatorFee = (proceeds * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;
        // ALICE is seller AND operator (msg.sender), so gets sellerPayout + operatorFee
        assertEq(
            collateral.balanceOf(ALICE) - before,
            expectedSellerPayout + operatorFee,
            "seller received collateral + operator fee"
        );
    }

    function test_marketSell_buyerReceivesTokens() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        uint256 before = ctf.balanceOf(BOB, positionIds[0]);
        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        assertEq(ctf.balanceOf(BOB, positionIds[0]) - before, qty, "BOB received YES tokens");
    }

    function test_marketSell_partialBuyOrder() public {
        // Buy order is larger than what seller wants to sell
        uint256 tick = 60;
        uint256 buyQty = 200e18;
        _placeBuyOrder(BOB, tick, buyQty);

        uint256 sellQty = 100e18;
        MarketSellResult memory r = _marketSell(ALICE, sellQty, 1, MarketOrderType.FAK);

        assertEq(r.tokensSold, sellQty, "sold all tokens");
        assertEq(r.unsoldTokens, 0, "no unsold tokens");
    }

    function test_marketSell_multipleTickLevels() public {
        uint256 qty = 100e18;
        // Place bids at two ticks; highest bid fills first
        _placeBuyOrder(BOB, 70, qty);
        _placeBuyOrder(CAROL, 60, qty);

        MarketSellResult memory r = _marketSell(ALICE, 2 * qty, 1, MarketOrderType.FAK);

        assertEq(r.tokensSold, 2 * qty, "filled both levels");
        assertEq(r.unsoldTokens, 0, "no unsold tokens");
    }

    function test_marketSell_bestBidConsumedFirst() public {
        uint256 qty = 100e18;
        _placeBuyOrder(CAROL, 50, qty); // lower bid
        _placeBuyOrder(BOB, 70, qty); // higher bid

        // Sell only enough for one level
        MarketSellResult memory r = _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        // Should fill at tick 70 (best bid), not 50
        uint256 expectedProceeds = _collateral(70, qty);
        uint256 expectedFee = (expectedProceeds * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedAvg = (expectedProceeds * 1e18) / qty;
        assertEq(r.avgPrice, expectedAvg, "filled at best bid (tick 70)");
    }

    // =========================================================================
    // FOK / FAK semantics
    // =========================================================================

    function test_marketSell_fok_insufficientLiquidity_reverts() public {
        uint256 tick = 60;
        uint256 buyQty = 50e18;
        _placeBuyOrder(BOB, tick, buyQty);

        // Seller wants to sell more than available
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InsufficientLiquidityForFOK.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 1, MarketOrderType.FOK);
    }

    function test_marketSell_fak_partialFill() public {
        uint256 tick = 60;
        uint256 buyQty = 50e18;
        _placeBuyOrder(BOB, tick, buyQty);

        // Seller sends more tokens than available bids
        MarketSellResult memory r = _marketSell(ALICE, 100e18, 1, MarketOrderType.FAK);

        assertEq(r.tokensSold, buyQty, "sold available qty");
        assertEq(r.unsoldTokens, 50e18, "remainder returned");
    }

    function test_marketSell_fak_emptyBook_reverts() public {
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 1, MarketOrderType.FAK);
    }

    function test_marketSell_fok_emptyBook_reverts() public {
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 1, MarketOrderType.FOK);
    }

    function test_marketSell_fak_unsoldTokensReturned() public {
        uint256 tick = 60;
        uint256 buyQty = 50e18;
        _placeBuyOrder(BOB, tick, buyQty);

        uint256 sellQty = 100e18;
        uint256 tokensBefore = ctf.balanceOf(ALICE, positionIds[0]);
        _marketSell(ALICE, sellQty, 1, MarketOrderType.FAK);

        // ALICE should have her unsold tokens back
        // _splitForUser gives ALICE sellQty tokens, then deposits all, then 50e18 returned
        uint256 tokensAfter = ctf.balanceOf(ALICE, positionIds[0]);
        assertEq(tokensAfter - tokensBefore, 50e18, "unsold tokens returned to seller");
    }

    // =========================================================================
    // Min price constraint
    // =========================================================================

    function test_marketSell_minPriceTick_respected() public {
        uint256 qty = 100e18;
        // Bids at tick 70 and tick 40
        _placeBuyOrder(BOB, 70, qty);
        _placeBuyOrder(CAROL, 40, qty);

        // Seller sets minPriceTick = 50 => only tick 70 should be consumed
        MarketSellResult memory r = _marketSell(ALICE, 2 * qty, 50, MarketOrderType.FAK);

        assertEq(r.tokensSold, qty, "only filled at tick 70");
        assertEq(r.unsoldTokens, qty, "tokens for tick 40 returned");
    }

    function test_marketSell_allBidsBelowMinPrice_reverts() public {
        _placeBuyOrder(BOB, 30, 100e18);

        // Min price above all bids
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 50, MarketOrderType.FAK);
    }

    // =========================================================================
    // Fee integration
    // =========================================================================

    function test_marketSell_withFees_sellerPayoutReduced() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        uint256 proceeds = _collateral(tick, qty);
        uint256 aliceBefore = collateral.balanceOf(ALICE);

        MarketSellResult memory r = _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        uint256 expectedTotalFee = (proceeds * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedSellerPayout = proceeds - expectedTotalFee;
        assertEq(r.collateralReceived, expectedSellerPayout, "collateralReceived reduced by fees");
    }

    function test_marketSell_withFees_feesDistributed() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        uint256 proceeds = _collateral(tick, qty);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);
        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = collateral.balanceOf(MARKET_CREATOR);
        uint256 aliceBefore = collateral.balanceOf(ALICE);

        // ALICE is both seller and operator (msg.sender)
        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        uint256 protocolFee = (proceeds * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 venueNetFee = (proceeds * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        uint256 creatorFee = (proceeds * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 operatorFee = (proceeds * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;

        uint256 totalComponents = protocolFee + venueNetFee + creatorFee + operatorFee;
        uint256 expectedTotal = (proceeds * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 remainder = expectedTotal > totalComponents ? expectedTotal - totalComponents : 0;

        assertEq(collateral.balanceOf(TREASURY) - treasuryBefore, protocolFee + remainder, "treasury fee");
        assertEq(collateral.balanceOf(FEE_RECIPIENT) - feeRecipientBefore, venueNetFee, "venue fee");
        assertEq(collateral.balanceOf(MARKET_CREATOR) - creatorBefore, creatorFee, "creator fee");
        // ALICE is operator: gets sellerPayout + operatorFee
        uint256 sellerPayout = proceeds - expectedTotal;
        assertEq(
            collateral.balanceOf(ALICE) - aliceBefore,
            sellerPayout + operatorFee,
            "seller got payout + operator fee"
        );
    }

    function test_marketSell_withFees_buyerCollateralCoversAll() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        uint256 diamondBefore = collateral.balanceOf(address(diamond));

        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        // The buyer's locked collateral should exactly cover seller payout + all fees
        // Diamond balance should not increase (no leaked collateral)
        uint256 diamondAfter = collateral.balanceOf(address(diamond));
        uint256 proceeds = _collateral(tick, qty);
        // Diamond held buyer's collateral, then distributed it all
        assertEq(diamondAfter, diamondBefore - proceeds, "diamond balance decreased by full proceeds");
    }

    // =========================================================================
    // Fill recording
    // =========================================================================

    function test_marketSell_fillRecorded() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 buyOrderId = _placeBuyOrder(BOB, tick, qty);

        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        (uint256 id, uint256 fMarketId, uint8 path, uint256 o1, uint256 o2, uint256 fQty, uint256 priceTick,) =
            _readFill(1);

        assertEq(id, 1, "fill id");
        assertEq(fMarketId, marketId, "fill marketId");
        assertEq(path, uint8(SettlementPath.NORMAL), "fill path");
        assertEq(o1, buyOrderId, "order1Id = resting buy order");
        assertEq(o2, 0, "order2Id = 0 (market sell taker)");
        assertEq(fQty, qty, "fill qty");
        assertEq(priceTick, tick, "fill priceTick");
    }

    function test_marketSell_multiFill_recorded() public {
        uint256 qty = 100e18;
        uint256 buyOrder1 = _placeBuyOrder(BOB, 70, qty);
        uint256 buyOrder2 = _placeBuyOrder(CAROL, 60, qty);

        _marketSell(ALICE, 2 * qty, 1, MarketOrderType.FAK);

        // First fill at tick 70 (best bid)
        (uint256 id1,,, uint256 o1_1,,, uint256 pt1,) = _readFill(1);
        assertEq(id1, 1, "fill 1 id");
        assertEq(o1_1, buyOrder1, "fill 1 order1Id");
        assertEq(pt1, 70, "fill 1 at tick 70");

        // Second fill at tick 60
        (uint256 id2,,, uint256 o1_2,,, uint256 pt2,) = _readFill(2);
        assertEq(id2, 2, "fill 2 id");
        assertEq(o1_2, buyOrder2, "fill 2 order1Id");
        assertEq(pt2, 60, "fill 2 at tick 60");
    }

    // =========================================================================
    // Expired order cleanup
    // =========================================================================

    function test_marketSell_expiredBuyOrderSkipped() public {
        // First buy order expires soon (at tick 70)
        uint256 collateralNeeded = _collateral(70, 100e18);
        _mintAndApprove(BOB, collateralNeeded);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(
            marketId, 0, Side.BUY, 70, 100e18, block.timestamp + 1
        );

        // Second buy order at lower tick, no expiry
        _placeBuyOrder(CAROL, 60, 100e18);

        // Warp past expiry of first order
        vm.warp(block.timestamp + 2);

        MarketSellResult memory r = _marketSell(ALICE, 100e18, 1, MarketOrderType.FAK);

        // Should skip expired order at tick 70 and fill at tick 60
        uint256 expectedProceeds = _collateral(60, 100e18);
        uint256 expectedAvg = (expectedProceeds * 1e18) / 100e18;
        assertEq(r.tokensSold, 100e18, "filled from non-expired order");
        assertEq(r.avgPrice, expectedAvg, "filled at tick 60");
    }

    // =========================================================================
    // Volume tracking
    // =========================================================================

    function test_marketSell_volumeTracked() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        MarketTradingData memory tdBefore = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        uint256 volBefore = tdBefore.totalVolume[0];

        _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        MarketTradingData memory tdAfter = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        uint256 expectedProceeds = _collateral(tick, qty);
        assertEq(tdAfter.totalVolume[0] - volBefore, expectedProceeds, "volume tracked");
        assertEq(tdAfter.lastTradeTick[0], tick, "last trade tick updated");
    }

    // =========================================================================
    // Input validation
    // =========================================================================

    function test_marketSell_zeroTokenAmount_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.ZeroTokenAmount.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 0, 1, MarketOrderType.FAK);
    }

    function test_marketSell_zeroMinPrice_reverts() public {
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InvalidMinPrice.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 0, MarketOrderType.FAK);
    }

    function test_marketSell_invalidOutcome_reverts() public {
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InvalidOutcome.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 2, 100e18, 1, MarketOrderType.FAK);
    }

    function test_marketSell_inactiveMarket_reverts() public {
        _splitForUser(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.MarketNotActive.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(999, 0, 100e18, 1, MarketOrderType.FAK);
    }

    // =========================================================================
    // Average price calculation
    // =========================================================================

    function test_marketSell_avgPrice_singleLevel() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, tick, qty);

        MarketSellResult memory r = _marketSell(ALICE, qty, 1, MarketOrderType.FAK);

        // avgPrice = totalProceeds * 1e18 / tokensSold (gross, before fees)
        uint256 expectedProceeds = _collateral(tick, qty);
        uint256 expectedAvg = (expectedProceeds * 1e18) / qty;
        assertEq(r.avgPrice, expectedAvg, "avg price matches tick price");
    }

    function test_marketSell_avgPrice_multipleLevels() public {
        uint256 qty = 100e18;
        _placeBuyOrder(BOB, 70, qty);
        _placeBuyOrder(CAROL, 50, qty);

        MarketSellResult memory r = _marketSell(ALICE, 2 * qty, 1, MarketOrderType.FAK);

        // Weighted average of tick 70 and tick 50
        uint256 totalProceeds = _collateral(70, qty) + _collateral(50, qty);
        uint256 expectedAvg = (totalProceeds * 1e18) / (2 * qty);
        assertEq(r.avgPrice, expectedAvg, "weighted avg price");
    }

    // =========================================================================
    // Venue pause
    // =========================================================================

    function test_marketSell_revertsWhenVenuePaused() public {
        _placeBuyOrder(BOB, 60, 100e18);

        // Split tokens for ALICE before pausing (splitPosition also checks venue status)
        _splitForUser(ALICE, 100e18);

        // Pause venue (operator is MARKET_CREATOR)
        vm.prank(MARKET_CREATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.VenueInactive.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, 0, 100e18, 1, MarketOrderType.FAK);
    }

    // =========================================================================
    // Internal: read Fill from Diamond storage
    // =========================================================================

    function _readFill(uint256 fillId)
        internal
        view
        returns (uint256 id, uint256 fMarketId, uint8 path, uint256 o1, uint256 o2, uint256 fQty, uint256 priceTick, address op)
    {
        bytes32 storagePosition = keccak256("oddmaki.storage.fills");
        bytes32 fillSlot = keccak256(abi.encode(fillId, uint256(storagePosition)));

        id = uint256(vm.load(address(diamond), fillSlot));
        fMarketId = uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 1)));
        path = uint8(uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 2))));
        o1 = uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 3)));
        o2 = uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 4)));
        fQty = uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 5)));
        priceTick = uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 6)));
        op = address(uint160(uint256(vm.load(address(diamond), bytes32(uint256(fillSlot) + 7)))));
    }
}
