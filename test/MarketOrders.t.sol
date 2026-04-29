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
import {MarketTradingData, Side, Fill, SettlementPath, MarketOrderType, MarketBuyResult} from "../src/interfaces/Types.sol";
import {LibMarketOrderValidator} from "../src/validators/LibMarketOrderValidator.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Market order integration tests
 * @notice Tests market buy execution (Normal Fill only) with FOK/FAK semantics,
 *         fee integration, expired order cleanup, and edge cases.
 */
contract MarketOrdersTest is Test, DiamondSetup {
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

    /// @dev Returns collateral needed for a market buy including fee headroom
    function _buyCollateral(uint256 tick, uint256 qty) internal pure returns (uint256) {
        uint256 base = _collateral(tick, qty);
        return base + (base * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
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

    function _placeSellOrder(address seller, uint256 tick, uint256 qty) internal returns (uint256) {
        _splitForUser(seller, qty);
        vm.prank(seller);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);
    }

    function _marketBuy(address buyer, uint256 colAmount, uint256 maxTick, MarketOrderType ot)
        internal
        returns (MarketBuyResult memory)
    {
        _mintAndApprove(buyer, colAmount);
        vm.prank(buyer);
        return MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, colAmount, maxTick, ot);
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
            "MO Test Venue", "", address(0), address(0), FEE_RECIPIENT,
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

    function test_marketBuy_singleFill() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        uint256 col = _buyCollateral(tick, qty);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        assertEq(r.tokensReceived, qty, "tokens received");
        assertEq(r.collateralSpent, col, "collateral spent");
        assertEq(r.unusedCollateral, 0, "no unused collateral");
        assertGt(r.avgPrice, 0, "avg price set");
    }

    function test_marketBuy_buyerReceivesTokens() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        uint256 before = ctf.balanceOf(ALICE, positionIds[0]);
        uint256 col = _buyCollateral(tick, qty);
        _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        assertEq(ctf.balanceOf(ALICE, positionIds[0]) - before, qty, "ALICE received YES tokens");
    }

    function test_marketBuy_partialSellOrder() public {
        // Sell order qty limits fill (sell 100 but buyer can afford more)
        uint256 tick = 60;
        uint256 sellQty = 100e18;
        _placeSellOrder(BOB, tick, sellQty);

        // Buyer sends enough for 200 tokens (including fees) — sell order caps at 100
        uint256 buyCol = _buyCollateral(tick, 200e18);
        MarketBuyResult memory r = _marketBuy(ALICE, buyCol, MAX_TICK, MarketOrderType.FAK);

        uint256 expectedSpent = _buyCollateral(tick, sellQty);
        assertEq(r.tokensReceived, sellQty, "buyer got sell order qty");
        assertEq(r.collateralSpent, expectedSpent, "spent cost + fees for 100 tokens");
        assertEq(r.unusedCollateral, buyCol - expectedSpent, "remainder returned");
    }

    function test_marketBuy_multipleTickLevels() public {
        // Place sell orders at two different ticks
        uint256 tick1 = 50;
        uint256 tick2 = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick1, qty);
        _placeSellOrder(CAROL, tick2, qty);

        // Buyer has enough for both levels (including fees)
        uint256 col = _buyCollateral(tick1, qty) + _buyCollateral(tick2, qty);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        assertEq(r.tokensReceived, 2 * qty, "filled both levels");
        assertEq(r.collateralSpent, col, "all collateral spent");
    }

    // =========================================================================
    // FOK / FAK semantics
    // =========================================================================

    function test_marketBuy_fok_insufficientLiquidity_reverts() public {
        uint256 tick = 60;
        uint256 qty = 50e18;
        _placeSellOrder(BOB, tick, qty);

        // Buyer wants more than available
        uint256 col = _collateral(tick, 100e18);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InsufficientLiquidityForFOK.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, MAX_TICK, MarketOrderType.FOK);
    }

    function test_marketBuy_fak_partialFill() public {
        uint256 tick = 60;
        uint256 sellQty = 50e18;
        _placeSellOrder(BOB, tick, sellQty);

        // Buyer sends more collateral than available liquidity (including fees)
        uint256 col = _buyCollateral(tick, 100e18);
        uint256 aliceBefore = collateral.balanceOf(ALICE);

        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // collateralSpent now includes fee (base cost + fee from buyer)
        uint256 expectedSpent = _buyCollateral(tick, sellQty);
        assertEq(r.tokensReceived, sellQty, "got available tokens");
        assertEq(r.collateralSpent, expectedSpent, "spent base cost + fees");
        assertEq(r.unusedCollateral, col - expectedSpent, "remainder returned");

        // Verify collateral returned to ALICE (includes operator fee since ALICE is msg.sender)
        uint256 aliceAfter = collateral.balanceOf(ALICE);
        uint256 baseCost = _collateral(tick, sellQty);
        uint256 operatorFee = (baseCost * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;
        assertEq(aliceAfter - aliceBefore, r.unusedCollateral + operatorFee, "ALICE got remainder + operator fee");
    }

    function test_marketBuy_fak_emptyBook_reverts() public {
        uint256 col = 100e18;
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, MAX_TICK, MarketOrderType.FAK);
    }

    function test_marketBuy_fok_emptyBook_reverts() public {
        uint256 col = 100e18;
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, MAX_TICK, MarketOrderType.FOK);
    }

    // =========================================================================
    // Max price constraint
    // =========================================================================

    function test_marketBuy_maxPriceTick_respected() public {
        // Sell at tick 60 and tick 70
        _placeSellOrder(BOB, 60, 100e18);
        _placeSellOrder(CAROL, 70, 100e18);

        // Buyer limits to tick 60 (send enough for both, but only tick 60 should fill)
        uint256 col = _buyCollateral(60, 100e18) + _buyCollateral(70, 100e18);
        MarketBuyResult memory r = _marketBuy(ALICE, col, 60, MarketOrderType.FAK);

        // Should only fill at tick 60, not 70 (collateralSpent includes fee)
        assertEq(r.tokensReceived, 100e18, "only filled at tick 60");
        assertEq(r.collateralSpent, _buyCollateral(60, 100e18), "only spent for tick 60");
        assertGt(r.unusedCollateral, 0, "remainder from tick 70 liquidity not consumed");
    }

    // =========================================================================
    // Fee integration
    // =========================================================================

    function test_marketBuy_withFees_sellerPayoutReduced() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        uint256 baseCost = _collateral(tick, qty);
        uint256 col = _buyCollateral(tick, qty);
        uint256 bobBefore = collateral.balanceOf(BOB);

        _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // Seller (maker) now gets FULL base cost — fee comes from buyer's collateral
        assertEq(collateral.balanceOf(BOB) - bobBefore, baseCost, "seller gets full base cost");
    }

    function test_marketBuy_withFees_feesDistributed() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        uint256 baseCost = _collateral(tick, qty);
        uint256 col = _buyCollateral(tick, qty);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);
        uint256 feeRecipientBefore = collateral.balanceOf(FEE_RECIPIENT);
        uint256 creatorBefore = collateral.balanceOf(MARKET_CREATOR);
        uint256 aliceBefore = collateral.balanceOf(ALICE);

        // ALICE is both buyer and operator (msg.sender)
        _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // Fee is computed on the base cost (not on col which includes fee headroom)
        uint256 protocolFee = (baseCost * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 venueNetFee = (baseCost * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        uint256 creatorFee = (baseCost * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 operatorFee = (baseCost * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;

        uint256 totalComponents = protocolFee + venueNetFee + creatorFee + operatorFee;
        uint256 expectedTotal = (baseCost * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 remainder = expectedTotal > totalComponents ? expectedTotal - totalComponents : 0;

        assertEq(collateral.balanceOf(TREASURY) - treasuryBefore, protocolFee + remainder, "treasury fee");
        assertEq(collateral.balanceOf(FEE_RECIPIENT) - feeRecipientBefore, venueNetFee, "venue fee");
        assertEq(collateral.balanceOf(MARKET_CREATOR) - creatorBefore, creatorFee, "creator fee");
        // ALICE is operator: _marketBuy mints col, facet deposits it, then gives operator fee
        // Net balance change: +operatorFee
        assertEq(collateral.balanceOf(ALICE) - aliceBefore, operatorFee, "operator fee to buyer/operator");
    }

    // =========================================================================
    // Fill recording
    // =========================================================================

    function test_marketBuy_fillRecorded() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 sellOrderId = _placeSellOrder(BOB, tick, qty);

        uint256 col = _buyCollateral(tick, qty);
        _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // Read fill from Diamond storage (same pattern as Fees.t.sol)
        (uint256 id, uint256 fMarketId, uint8 path, uint256 o1, uint256 o2, uint256 fQty, uint256 priceTick,) =
            _readFill(1);

        assertEq(id, 1, "fill id");
        assertEq(fMarketId, marketId, "fill marketId");
        assertEq(path, uint8(SettlementPath.NORMAL), "fill path");
        assertEq(o1, 0, "order1Id = 0 (market order taker)");
        assertEq(o2, sellOrderId, "order2Id = sell order");
        assertEq(fQty, qty, "fill qty");
        assertEq(priceTick, tick, "fill priceTick");
    }

    // =========================================================================
    // Expired order cleanup
    // =========================================================================

    function test_marketBuy_expiredOrderSkipped() public {
        // First sell order expires soon
        _splitForUser(BOB, 100e18);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(
            marketId, 0, Side.SELL, 50, 100e18, block.timestamp + 1
        );

        // Second sell order at higher tick, no expiry
        _placeSellOrder(CAROL, 60, 100e18);

        // Warp past expiry of first order
        vm.warp(block.timestamp + 2);

        uint256 col = _buyCollateral(60, 100e18);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // Should skip expired order at tick 50 and fill at tick 60
        assertEq(r.tokensReceived, 100e18, "filled from non-expired order");
        assertEq(r.collateralSpent, col, "spent for tick 60");
    }

    // =========================================================================
    // Volume tracking
    // =========================================================================

    function test_marketBuy_volumeTracked() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        MarketTradingData memory tdBefore = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        uint256 volBefore = tdBefore.totalVolume[0];

        uint256 col = _buyCollateral(tick, qty);
        _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        MarketTradingData memory tdAfter = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        // Volume tracks base cost (not including fees)
        uint256 baseCost = _collateral(tick, qty);
        assertEq(tdAfter.totalVolume[0] - volBefore, baseCost, "volume tracked");
        assertEq(tdAfter.lastTradeTick[0], tick, "last trade tick updated");
    }

    // =========================================================================
    // Input validation
    // =========================================================================

    function test_marketBuy_zeroCollateral_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.ZeroCollateralAmount.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, 0, MAX_TICK, MarketOrderType.FAK);
    }

    function test_marketBuy_zeroMaxPrice_reverts() public {
        _mintAndApprove(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InvalidMaxPrice.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, 100e18, 0, MarketOrderType.FAK);
    }

    function test_marketBuy_inactiveMarket_reverts() public {
        // Market ID 999 doesn't exist (not active)
        _mintAndApprove(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.MarketNotActive.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(999, 0, 100e18, MAX_TICK, MarketOrderType.FAK);
    }

    // =========================================================================
    // Average price calculation
    // =========================================================================

    function test_marketBuy_avgPrice_singleLevel() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        _placeSellOrder(BOB, tick, qty);

        uint256 col = _buyCollateral(tick, qty);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // avgPrice = collateralSpent * 1e18 / tokensReceived
        uint256 expectedAvg = (col * 1e18) / qty;
        assertEq(r.avgPrice, expectedAvg, "avg price matches tick price");
    }

    function test_marketBuy_avgPrice_multiplelevels() public {
        uint256 qty = 100e18;
        _placeSellOrder(BOB, 50, qty);
        _placeSellOrder(CAROL, 70, qty);

        uint256 col = _buyCollateral(50, qty) + _buyCollateral(70, qty);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FAK);

        // Should be weighted average of tick 50 and tick 70 (including fees)
        uint256 expectedAvg = (col * 1e18) / (2 * qty);
        assertEq(r.avgPrice, expectedAvg, "weighted avg price");
    }

    // =========================================================================
    // H-3 audit fix: FOK rounding dust
    // =========================================================================

    function test_marketBuy_fok_roundingDust_succeeds() public {
        // Place a sell order smaller than what the buyer can afford,
        // so the sell order qty limits the fill and rounding dust remains.
        // At tick 33, 30 tokens cost 9.9e18. _buyCollateral rounds to include fees.
        // The sell order (30e18) caps the fill, leaving small dust in remaining.
        _placeSellOrder(BOB, 33, 30e18);

        uint256 col = _buyCollateral(33, 30e18);
        MarketBuyResult memory r = _marketBuy(ALICE, col, MAX_TICK, MarketOrderType.FOK);

        assertEq(r.tokensReceived, 30e18, "received tokens");
        assertLe(r.unusedCollateral, TICK_SIZE, "dust is within threshold");
        assertEq(r.collateralSpent + r.unusedCollateral, col, "accounting is sound");
    }

    function test_marketBuy_fok_genuineInsufficientLiquidity_stillReverts() public {
        // Only 50e18 liquidity at tick 60
        _placeSellOrder(BOB, 60, 50e18);

        // Buyer wants 100e18 worth — genuine shortfall (remaining = 30e18 >> tickSize)
        uint256 col = _collateral(60, 100e18);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketOrderValidator.InsufficientLiquidityForFOK.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, MAX_TICK, MarketOrderType.FOK);
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

    // ---- M-3: Venue pause blocks market orders ----

    function test_M3_placeMarketOrder_revertsWhenVenuePaused() public {
        // Set up sell-side liquidity first (while venue is active)
        _placeSellOrder(BOB, 60, 100e18);

        // Pause venue (operator is MARKET_CREATOR)
        vm.prank(MARKET_CREATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        // Market order should revert
        uint256 col = _collateral(60, 100e18);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.VenueInactive.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, MAX_TICK, MarketOrderType.FAK);
    }
}
