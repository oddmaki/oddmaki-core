// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketTradingData, Side, Fill, SettlementPath} from "../src/interfaces/Types.sol";
import {LibFillStorage} from "../src/storage/LibFillStorage.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Fee system integration tests
 * @notice Tests fee calculation, distribution, fill recording, and backward compatibility
 *         across all three settlement paths (Normal, Mint, Merge).
 */
contract FeesTest is Test, DiamondSetup {
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
    address constant OPERATOR = address(0x0FE8A70E);

    // Venue config: 100 bps venue fee, 30 bps creator fee
    uint256 constant VENUE_FEE_BPS = 100;
    uint256 constant CREATOR_FEE_BPS = 30;
    uint256 constant PROTOCOL_FEE_BPS = 20;
    uint256 constant OPERATOR_FEE_BPS = 10;
    // Total = 20 + 100 + 10 = 130 bps
    uint256 constant TOTAL_FEE_BPS = PROTOCOL_FEE_BPS + VENUE_FEE_BPS + OPERATOR_FEE_BPS;
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

    // =========================================================================
    // Setup (with fees enabled)
    // =========================================================================

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);

        // Set protocol treasury to enable fees
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);

        // Create venue with specific fee config
        vm.prank(MARKET_CREATOR);
        venueId = VenueFacet(address(diamond)).createVenue(
            "Fee Test Venue",
            "",
            address(0), // public trading
            address(0), // public creation
            FEE_RECIPIENT,
            VENUE_FEE_BPS,  // 100 bps (1%)
            CREATOR_FEE_BPS, // 30 bps (0.3%)
            TICK_SIZE,
            5e6, // marketCreationFee
            0,
            1e6
        );

        // Create market (creator = MARKET_CREATOR)
        // Give MARKET_CREATOR collateral for the creation fee
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
    // Normal Fill Fee Tests
    // =========================================================================

    function test_normalFill_withFees_sellerPayoutReduced() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        uint256 bobBefore = collateral.balanceOf(BOB);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1);

        // Total fee = col * 130 / 10000
        uint256 expectedTotalFee = (col * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedSellerPayout = col - expectedTotalFee;

        assertEq(collateral.balanceOf(BOB) - bobBefore, expectedSellerPayout, "seller payout reduced by fees");
    }

    function test_normalFill_withFees_feesDistributedCorrectly() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);
        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = collateral.balanceOf(MARKET_CREATOR);
        uint256 operatorBefore = collateral.balanceOf(OPERATOR);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Expected fee components
        uint256 protocolFee = (col * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 venueNetFee = (col * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        uint256 creatorFee = (col * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 operatorFee = (col * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;

        // Remainder from rounding goes to protocol
        uint256 totalComponents = protocolFee + venueNetFee + creatorFee + operatorFee;
        uint256 expectedTotal = (col * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 remainder = expectedTotal > totalComponents ? expectedTotal - totalComponents : 0;

        assertEq(
            collateral.balanceOf(TREASURY) - treasuryBefore,
            protocolFee + remainder,
            "treasury received protocol fee + remainder"
        );
        assertEq(
            collateral.balanceOf(FEE_RECIPIENT) - feeRecipientBefore, venueNetFee, "venue received net fee"
        );
        assertEq(
            collateral.balanceOf(MARKET_CREATOR) - creatorBefore, creatorFee, "creator received fee"
        );
        assertEq(
            collateral.balanceOf(OPERATOR) - operatorBefore, operatorFee, "operator received fee"
        );
    }

    function test_normalFill_withFees_fillRecorded() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        uint256 buyOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        uint256 sellOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Read fill from storage via a view helper
        // Fill IDs start at 1
        (uint256 id, uint256 fMarketId, uint8 path, uint256 o1, uint256 o2, uint256 fQty, uint256 priceTick, address op) =
            _readFill(1);

        assertEq(id, 1, "fill id");
        assertEq(fMarketId, marketId, "fill marketId");
        assertEq(path, uint8(SettlementPath.NORMAL), "fill path");
        assertEq(o1, buyOrderId, "fill order1Id (buyOrderId)");
        assertEq(o2, sellOrderId, "fill order2Id (sellOrderId)");
        assertEq(fQty, qty, "fill qty");
        assertEq(priceTick, tick, "fill priceTick");
        assertEq(op, OPERATOR, "fill operator");
    }

    // =========================================================================
    // Mint Fill Fee Tests
    // =========================================================================

    function test_mintFill_withFees_feasibilityRejectsMarginalBids() public {
        // With 130 bps fees, bids that exactly cover 1.0 should NOT fill
        // because they need to cover 1.0 + fees
        uint256 yesTick = 60;
        uint256 noTick = 40; // sum = 100 = maxTick, but need > 100 with fees
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "should not fill when bids only cover 1.0 without fee margin");
    }

    function test_mintFill_withFees_sufficientBidsFill() public {
        // minRequired = 100 * (10000 + 130) / 10000 = 100 * 10130 / 10000 = 101.3 ticks
        // So yesBid=61 + noBid=41 = 102 >= 101.3 -> should fill
        uint256 yesTick = 61;
        uint256 noTick = 41;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "should fill with sufficient bids");

        // Both buyers get tokens
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), qty, "ALICE received YES");
        assertEq(ctf.balanceOf(CAROL, positionIds[1]), qty, "CAROL received NO");
    }

    function test_mintFill_withFees_feesDistributed() public {
        uint256 yesTick = 61;
        uint256 noTick = 41;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Fee base for mint is qty (notional)
        uint256 protocolFee = (qty * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        assertGt(collateral.balanceOf(TREASURY) - treasuryBefore, 0, "treasury received fees");
        // Protocol fee should be at least protocolFee (may include remainder)
        assertGe(collateral.balanceOf(TREASURY) - treasuryBefore, protocolFee, "protocol fee amount");
    }

    function test_mintFill_withFees_fillRecorded() public {
        uint256 yesTick = 61;
        uint256 noTick = 41;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        uint256 yesOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        uint256 noOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        (uint256 id,, uint8 path, uint256 o1, uint256 o2,,,) = _readFill(1);
        assertEq(id, 1, "fill id");
        assertEq(path, uint8(SettlementPath.MINT), "fill path");
        assertEq(o1, yesOrderId, "fill order1Id (yesOrderId)");
        assertEq(o2, noOrderId, "fill order2Id (noOrderId)");
    }

    // =========================================================================
    // Merge Fill Fee Tests
    // =========================================================================

    function test_mergeFill_withFees_feasibilityRejectsMarginalAsks() public {
        // With 130 bps fees, asks that sum exactly to 1.0 should NOT fill
        // maxAllowed = 100 * (10000 - 130) / 10000 = 100 * 9870 / 10000 = 98.7 ticks
        // So yesAsk=55 + noAsk=44 = 99 > 98.7 -> should NOT fill
        uint256 yesAsk = 55;
        uint256 noAsk = 44;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "should not fill when asks exceed 1.0 - fees");
    }

    function test_mergeFill_withFees_sufficientAsksFill() public {
        // maxAllowed = 98.7 ticks
        // yesAsk=50 + noAsk=48 = 98 <= 98.7 -> should fill
        uint256 yesAsk = 50;
        uint256 noAsk = 48;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        uint256 aliceBefore = collateral.balanceOf(ALICE);
        uint256 bobBefore = collateral.balanceOf(BOB);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "should fill with sufficient spread");

        // Sellers get collateral at their ask prices
        assertEq(collateral.balanceOf(ALICE) - aliceBefore, _collateral(yesAsk, qty), "ALICE payout");
        assertEq(collateral.balanceOf(BOB) - bobBefore, _collateral(noAsk, qty), "BOB payout");
    }

    function test_mergeFill_withFees_feesDistributed() public {
        uint256 yesAsk = 50;
        uint256 noAsk = 48;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        assertGt(collateral.balanceOf(TREASURY) - treasuryBefore, 0, "treasury received fees from merge");
    }

    function test_mergeFill_withFees_fillRecorded() public {
        uint256 yesAsk = 50;
        uint256 noAsk = 48;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        uint256 yesOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        uint256 noOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        (uint256 id,, uint8 path, uint256 o1, uint256 o2,,,) = _readFill(1);
        assertEq(id, 1, "fill id");
        assertEq(path, uint8(SettlementPath.MERGE), "fill path");
        assertEq(o1, yesOrderId, "fill order1Id (yesOrderId)");
        assertEq(o2, noOrderId, "fill order2Id (noOrderId)");
    }

    // =========================================================================
    // Fill ID Sequencing
    // =========================================================================

    function test_fillId_incrementsAcrossFills() public {
        uint256 tick = 60;
        uint256 qty = 50e18;
        uint256 col = _collateral(tick, qty);

        // First fill: normal
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);
        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Second fill: normal
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);
        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        (uint256 id1,,,,,,, ) = _readFill(1);
        (uint256 id2,,,,,,, ) = _readFill(2);
        assertEq(id1, 1, "first fill id");
        assertEq(id2, 2, "second fill id");
    }

    // =========================================================================
    // Backward Compatibility (no treasury = no fees)
    // =========================================================================

    function test_normalFill_noTreasury_backwardCompatible() public {
        // Deploy a fresh diamond without treasury
        OddMaki d2 = deployDiamond(address(this));
        MockCTF ctf2 = new MockCTF();
        MockERC20 col2 = new MockERC20("T2", "T2", 6);
        VaultFacet(address(d2)).setCtf(address(ctf2));
        ProtocolFacet(address(d2)).setCollateralWhitelisted(address(col2), true);
        // NOTE: no setProtocolTreasury call

        uint256 vid = VenueFacet(address(d2)).createVenue(
            "No Fee Venue", "", address(0), address(0), address(this), 100, 0, TICK_SIZE, 5e6, 0, 1e6
        );

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        uint256 mid = MarketsFacet(address(d2)).createMarket(vid, "", outcomes, TICK_SIZE, address(col2), 0, 0, new bytes32[](0));

        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;

        // Setup ALICE buy
        col2.mint(ALICE, col);
        vm.prank(ALICE);
        col2.approve(address(d2), col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 0, Side.BUY, tick, qty, 0);

        // Setup BOB sell
        col2.mint(BOB, qty);
        vm.startPrank(BOB);
        col2.approve(address(d2), qty);
        VaultFacet(address(d2)).splitPosition(mid, qty);
        ctf2.setApprovalForAll(address(d2), true);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 0, Side.SELL, tick, qty, 0);
        vm.stopPrank();

        uint256 bobBefore = col2.balanceOf(BOB);

        MatchingFacet(address(d2)).matchOrders(mid, 10);

        // Without treasury, seller gets full collateral (no fee deduction)
        assertEq(col2.balanceOf(BOB) - bobBefore, col, "seller gets full collateral without treasury");
    }

    // =========================================================================
    // Edge Cases
    // =========================================================================

    function test_fees_partialFill_feesProportional() public {
        uint256 tick = 60;
        uint256 bigQty = 200e18;
        uint256 smallQty = 80e18;
        uint256 bigCol = _collateral(tick, bigQty);
        uint256 smallCol = _collateral(tick, smallQty);

        // ALICE places a large BUY
        _mintAndApprove(ALICE, bigCol);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, bigQty, 0);

        // BOB places a smaller SELL
        _splitForUser(BOB, bigQty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, smallQty, 0);

        uint256 bobBefore = collateral.balanceOf(BOB);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Fee is on the smallQty collateral (the actual fill amount)
        uint256 expectedTotalFee = (smallCol * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 expectedPayout = smallCol - expectedTotalFee;
        assertEq(collateral.balanceOf(BOB) - bobBefore, expectedPayout, "partial fill fee proportional");
    }

    function test_fees_creatorFeeZero_allGoesToVenue() public {
        // Create a venue with 0 creator fee
        uint256 vid2 = VenueFacet(address(diamond)).createVenue(
            "Zero Creator", "", address(0), address(0), FEE_RECIPIENT, 100, 0, TICK_SIZE, 5e6, 0, 1e6
        );

        // Provide creation fee collateral
        uint256 cFee = 5e6;
        collateral.mint(address(this), cFee);
        collateral.approve(address(diamond), cFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        uint256 mid2 = MarketsFacet(address(diamond)).createMarket(vid2, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(mid2, 0, Side.BUY, tick, qty, 0);

        // Split for BOB on mid2 (can't use _splitForUser which uses global marketId)
        collateral.mint(BOB, qty);
        vm.startPrank(BOB);
        collateral.approve(address(diamond), qty);
        VaultFacet(address(diamond)).splitPosition(mid2, qty);
        ctf.setApprovalForAll(address(diamond), true);
        LimitOrdersFacet(address(diamond)).placeOrder(mid2, 0, Side.SELL, tick, qty, 0);
        vm.stopPrank();

        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(mid2, 10);

        // Venue gets all 100 bps (no creator split)
        uint256 expectedVenueNet = (col * 100) / BPS_DENOMINATOR;
        assertEq(
            collateral.balanceOf(FEE_RECIPIENT) - feeRecipientBefore, expectedVenueNet, "venue gets full fee"
        );
    }

    // =========================================================================
    // H-2 Fix: Fee Snapshot at Market Creation
    // =========================================================================

    function test_feeSnapshot_venueChangeDoesNotAffectExistingMarket() public {
        // Market was created with VENUE_FEE_BPS=100, CREATOR_FEE_BPS=30
        // Venue operator jacks up fees to max (200 bps venue, 0 creator)
        vm.prank(MARKET_CREATOR);
        VenueFacet(address(diamond)).updateVenueFees(venueId, 200, 0);

        // Place and match orders — fees should still be the original 100/30 bps
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        uint256 bobBefore = collateral.balanceOf(BOB);
        uint256 treasuryBefore = collateral.balanceOf(TREASURY);
        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = collateral.balanceOf(MARKET_CREATOR);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1);

        // Fees should use ORIGINAL snapshot (100 bps venue, 30 bps creator),
        // NOT the updated 200 bps venue / 0 bps creator
        uint256 originalTotalBps = PROTOCOL_FEE_BPS + VENUE_FEE_BPS + OPERATOR_FEE_BPS; // 20+100+10=130
        uint256 expectedTotalFee = (col * originalTotalBps) / BPS_DENOMINATOR;
        uint256 expectedSellerPayout = col - expectedTotalFee;

        assertEq(collateral.balanceOf(BOB) - bobBefore, expectedSellerPayout, "seller payout uses original fees");

        // Creator should still get 30 bps (not 0)
        uint256 expectedCreatorFee = (col * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        assertEq(collateral.balanceOf(MARKET_CREATOR) - creatorBefore, expectedCreatorFee, "creator fee uses original snapshot");

        // Venue net = (100 - 30) = 70 bps
        uint256 expectedVenueNet = (col * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        assertEq(collateral.balanceOf(FEE_RECIPIENT) - feeRecipientBefore, expectedVenueNet, "venue net fee uses original snapshot");
    }

    function test_feeSnapshot_newMarketUsesCurrentVenueFees() public {
        // Update venue fees
        vm.prank(MARKET_CREATOR);
        VenueFacet(address(diamond)).updateVenueFees(venueId, 50, 10);

        // Create a NEW market — should snapshot the new 50/10 fees
        uint256 cFee = 5e6;
        collateral.mint(MARKET_CREATOR, cFee);
        vm.prank(MARKET_CREATOR);
        collateral.approve(address(diamond), cFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(MARKET_CREATOR);
        uint256 newMarketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = _collateral(tick, qty);

        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(newMarketId, 0, Side.BUY, tick, qty, 0);

        collateral.mint(BOB, qty);
        vm.startPrank(BOB);
        collateral.approve(address(diamond), qty);
        VaultFacet(address(diamond)).splitPosition(newMarketId, qty);
        ctf.setApprovalForAll(address(diamond), true);
        LimitOrdersFacet(address(diamond)).placeOrder(newMarketId, 0, Side.SELL, tick, qty, 0);
        vm.stopPrank();

        uint256 bobBefore = collateral.balanceOf(BOB);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(newMarketId, 10);

        // New market should use 50 bps venue fee (not original 100)
        uint256 newTotalBps = PROTOCOL_FEE_BPS + 50 + OPERATOR_FEE_BPS; // 20+50+10=80
        uint256 expectedTotalFee = (col * newTotalBps) / BPS_DENOMINATOR;
        uint256 expectedSellerPayout = col - expectedTotalFee;

        assertEq(collateral.balanceOf(BOB) - bobBefore, expectedSellerPayout, "new market uses current venue fees");
    }

    // =========================================================================
    // Internal: read Fill from Diamond storage
    // =========================================================================

    function _readFill(uint256 fillId)
        internal
        view
        returns (uint256 id, uint256 fMarketId, uint8 path, uint256 o1, uint256 o2, uint256 fQty, uint256 priceTick, address op)
    {
        // Access Diamond storage directly in test context (test contract is not delegatecall'd)
        // We need to read from the Diamond's storage, which requires calling a view through the Diamond.
        // Since there's no OrderBookFacet yet, we use a low-level staticcall to read storage.
        // For now, use the known storage slot pattern.

        // The Diamond storage for fills is at keccak256("oddmaki.storage.fills")
        // Storage layout: fills mapping at slot+0, nextFillId at slot+1
        // mapping(uint256 => Fill): slot = keccak256(abi.encode(fillId, storageSlot))

        bytes32 storagePosition = keccak256("oddmaki.storage.fills");
        bytes32 fillSlot = keccak256(abi.encode(fillId, uint256(storagePosition)));

        // Fill struct fields are packed sequentially starting at fillSlot
        // id (slot+0), marketId (slot+1), path (slot+2), order1Id (slot+3),
        // order2Id (slot+4), qty (slot+5), priceTick (slot+6), operator (slot+7)
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
