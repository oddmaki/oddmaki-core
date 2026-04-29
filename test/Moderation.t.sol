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
import {MarketTradingData, Side, MarketOrderType, MarketBuyResult} from "../src/interfaces/Types.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {LibProtocolValidator} from "../src/validators/LibProtocolValidator.sol";
import {LibMarketTradingValidator} from "../src/validators/LibMarketTradingValidator.sol";
import {NotContractOwner} from "../src/libraries/LibDiamond.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Moderation integration tests
 * @notice Tests protocol pause, venue suspension, and market pause enforcement
 *         across all trading paths (limit orders, matching, market orders, split/merge).
 */
contract ModerationTest is Test, DiamondSetup {
    // Events
    event ProtocolPausedEvent(address indexed caller);
    event ProtocolUnpausedEvent(address indexed caller);
    event VenueSuspendedEvent(uint256 indexed venueId, address indexed caller);
    event VenueUnsuspendedEvent(uint256 indexed venueId, address indexed caller);
    event MarketPausedEvent(uint256 indexed marketId, uint256 indexed venueId, address indexed operator);
    event MarketUnpausedEvent(uint256 indexed marketId, uint256 indexed venueId, address indexed operator);

    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE;

    address constant OPERATOR = address(0xABCD);
    address constant FEE_RECIPIENT = address(0xFEE);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant RANDO = address(0xBAD);
    address constant TREASURY = address(0x7EA5);

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
        uint256 col = _collateral(tick, qty);
        _mintAndApprove(buyer, col);
        vm.prank(buyer);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
    }

    function _placeSellOrder(address seller, uint256 tick, uint256 qty) internal returns (uint256) {
        _splitForUser(seller, qty);
        vm.prank(seller);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);
    }

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        diamond = deployDiamond(address(this)); // address(this) = protocol owner
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);

        // Create venue with OPERATOR as operator
        vm.prank(OPERATOR);
        venueId = VenueFacet(address(diamond)).createVenue(
            "Test Venue", "", address(0), address(0), FEE_RECIPIENT, 100, 0, TICK_SIZE, 5e6, 0, 1e6
        );

        // Create market (creation fee = 5 USDC)
        uint256 creationFee = 5e6;
        collateral.mint(ALICE, creationFee);
        vm.prank(ALICE);
        collateral.approve(address(diamond), creationFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(ALICE);
        marketId =
            MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // =========================================================================
    // Protocol Pause — access control
    // =========================================================================

    function test_pauseProtocol_ownerSucceeds() public {
        vm.expectEmit(true, false, false, true);
        emit ProtocolPausedEvent(address(this));
        ProtocolFacet(address(diamond)).pauseProtocol();

        assertTrue(ProtocolFacet(address(diamond)).getProtocolPaused());
    }

    function test_unpauseProtocol_ownerSucceeds() public {
        ProtocolFacet(address(diamond)).pauseProtocol();

        vm.expectEmit(true, false, false, true);
        emit ProtocolUnpausedEvent(address(this));
        ProtocolFacet(address(diamond)).unpauseProtocol();

        assertFalse(ProtocolFacet(address(diamond)).getProtocolPaused());
    }

    function test_pauseProtocol_nonOwnerReverts() public {
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, RANDO, address(this)));
        ProtocolFacet(address(diamond)).pauseProtocol();
    }

    function test_unpauseProtocol_nonOwnerReverts() public {
        ProtocolFacet(address(diamond)).pauseProtocol();
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, RANDO, address(this)));
        ProtocolFacet(address(diamond)).unpauseProtocol();
    }

    // =========================================================================
    // Protocol Pause — blocks trading
    // =========================================================================

    function test_protocolPause_blocksPlaceOrder() public {
        ProtocolFacet(address(diamond)).pauseProtocol();

        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e6, 0);
    }

    function test_protocolPause_blocksMatchOrders() public {
        // Place orders before pause
        _placeBuyOrder(ALICE, 50, 100e6);
        _placeSellOrder(BOB, 50, 100e6);

        ProtocolFacet(address(diamond)).pauseProtocol();

        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    function test_protocolPause_blocksPlaceMarketOrder() public {
        // Place a sell order before pause
        _placeSellOrder(BOB, 50, 100e6);

        ProtocolFacet(address(diamond)).pauseProtocol();

        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, 50, MarketOrderType.FAK);
    }

    function test_protocolPause_blocksCreateMarket() public {
        ProtocolFacet(address(diamond)).pauseProtocol();

        uint256 creationFee = 5e6;
        collateral.mint(BOB, creationFee);
        vm.prank(BOB);
        collateral.approve(address(diamond), creationFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(BOB);
        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));
    }

    function test_protocolPause_blocksSplitPosition() public {
        ProtocolFacet(address(diamond)).pauseProtocol();

        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), amount);
        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Protocol Pause — allows cancel + merge
    // =========================================================================

    function test_protocolPause_allowsCancelOrder() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e6);

        ProtocolFacet(address(diamond)).pauseProtocol();

        // Cancel should still work
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(orderId);
    }

    function test_protocolPause_allowsMergePositions() public {
        uint256 amount = 100e6;
        _splitForUser(ALICE, amount);

        ProtocolFacet(address(diamond)).pauseProtocol();

        // Merge should still work
        vm.startPrank(ALICE);
        ctf.setApprovalForAll(address(diamond), true);
        VaultFacet(address(diamond)).mergePositions(marketId, amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Protocol Pause — recovery
    // =========================================================================

    function test_protocolPause_unpauseRestoresTrading() public {
        ProtocolFacet(address(diamond)).pauseProtocol();
        ProtocolFacet(address(diamond)).unpauseProtocol();

        // Trading should work again
        _placeBuyOrder(ALICE, 50, 100e6);
    }

    // =========================================================================
    // Venue Suspension — access control
    // =========================================================================

    function test_suspendVenue_ownerSucceeds() public {
        vm.expectEmit(true, true, false, true);
        emit VenueSuspendedEvent(venueId, address(this));
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        assertTrue(ProtocolFacet(address(diamond)).getVenueSuspended(venueId));
    }

    function test_unsuspendVenue_ownerSucceeds() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        vm.expectEmit(true, true, false, true);
        emit VenueUnsuspendedEvent(venueId, address(this));
        ProtocolFacet(address(diamond)).unsuspendVenue(venueId);

        assertFalse(ProtocolFacet(address(diamond)).getVenueSuspended(venueId));
    }

    function test_suspendVenue_nonOwnerReverts() public {
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, RANDO, address(this)));
        ProtocolFacet(address(diamond)).suspendVenue(venueId);
    }

    function test_suspendVenue_nonexistentVenueReverts() public {
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        ProtocolFacet(address(diamond)).suspendVenue(999);
    }

    function test_unsuspendVenue_nonexistentVenueReverts() public {
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        ProtocolFacet(address(diamond)).unsuspendVenue(999);
    }

    // =========================================================================
    // Venue Suspension — blocks trading
    // =========================================================================

    function test_venueSuspension_blocksPlaceOrder() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibProtocolValidator.VenueSuspended.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e6, 0);
    }

    function test_venueSuspension_blocksCreateMarket() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        uint256 creationFee = 5e6;
        collateral.mint(BOB, creationFee);
        vm.prank(BOB);
        collateral.approve(address(diamond), creationFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(BOB);
        vm.expectRevert(LibProtocolValidator.VenueSuspended.selector);
        MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));
    }

    function test_venueSuspension_blocksSplitPosition() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), amount);
        vm.expectRevert(LibProtocolValidator.VenueSuspended.selector);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        vm.stopPrank();
    }

    function test_venueSuspension_blocksMatchOrders() public {
        _placeBuyOrder(ALICE, 50, 100e6);
        _placeSellOrder(BOB, 50, 100e6);

        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        vm.expectRevert(LibProtocolValidator.VenueSuspended.selector);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    // =========================================================================
    // Venue Suspension — allows cancel + merge
    // =========================================================================

    function test_venueSuspension_allowsCancelOrder() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e6);

        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(orderId);
    }

    function test_venueSuspension_allowsMergePositions() public {
        uint256 amount = 100e6;
        _splitForUser(ALICE, amount);

        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        vm.startPrank(ALICE);
        ctf.setApprovalForAll(address(diamond), true);
        VaultFacet(address(diamond)).mergePositions(marketId, amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Venue Suspension — operator cannot override
    // =========================================================================

    function test_venueSuspension_operatorCannotUnpauseVenue() public {
        // First pause the venue via operator
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        // Then suspend via protocol
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        // Operator tries to unpause — blocked by suspension
        vm.prank(OPERATOR);
        vm.expectRevert(LibProtocolValidator.VenueSuspended.selector);
        VenueFacet(address(diamond)).unpauseVenue(venueId);
    }

    function test_venueSuspension_afterUnsuspendOperatorCanUnpause() public {
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        ProtocolFacet(address(diamond)).suspendVenue(venueId);
        ProtocolFacet(address(diamond)).unsuspendVenue(venueId);

        // Now operator can unpause
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).unpauseVenue(venueId);

        // Trading should work
        _placeBuyOrder(ALICE, 50, 100e6);
    }

    // =========================================================================
    // Venue Suspension — recovery
    // =========================================================================

    function test_venueSuspension_unsuspendRestoresTrading() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);
        ProtocolFacet(address(diamond)).unsuspendVenue(venueId);

        // Trading should work again
        _placeBuyOrder(ALICE, 50, 100e6);
    }

    // =========================================================================
    // Market Pause — access control
    // =========================================================================

    function test_pauseMarket_operatorSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit MarketPausedEvent(marketId, venueId, OPERATOR);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);
    }

    function test_unpauseMarket_operatorSucceeds() public {
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.expectEmit(true, true, true, true);
        emit MarketUnpausedEvent(marketId, venueId, OPERATOR);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).unpauseMarket(marketId);
    }

    function test_pauseMarket_nonOperatorReverts() public {
        vm.prank(RANDO);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        MarketsFacet(address(diamond)).pauseMarket(marketId);
    }

    function test_unpauseMarket_nonOperatorReverts() public {
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.prank(RANDO);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        MarketsFacet(address(diamond)).unpauseMarket(marketId);
    }

    // =========================================================================
    // Market Pause — blocks trading
    // =========================================================================

    function test_marketPause_blocksPlaceOrder() public {
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketTradingValidator.MarketPaused.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e6, 0);
    }

    function test_marketPause_blocksMatchOrders() public {
        _placeBuyOrder(ALICE, 50, 100e6);
        _placeSellOrder(BOB, 50, 100e6);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.expectRevert(LibMarketTradingValidator.MarketPaused.selector);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    function test_marketPause_blocksPlaceMarketOrder() public {
        _placeSellOrder(BOB, 50, 100e6);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibMarketTradingValidator.MarketPaused.selector);
        MarketOrdersFacet(address(diamond)).placeMarketOrder(marketId, 0, col, 50, MarketOrderType.FAK);
    }

    function test_marketPause_blocksSplitPosition() public {
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), amount);
        vm.expectRevert(LibMarketTradingValidator.MarketPaused.selector);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        vm.stopPrank();
    }

    // =========================================================================
    // Market Pause — allows cancel + merge + expire
    // =========================================================================

    function test_marketPause_allowsCancelOrder() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e6);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(orderId);
    }

    function test_marketPause_allowsMergePositions() public {
        uint256 amount = 100e6;
        _splitForUser(ALICE, amount);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.startPrank(ALICE);
        ctf.setApprovalForAll(address(diamond), true);
        VaultFacet(address(diamond)).mergePositions(marketId, amount);
        vm.stopPrank();
    }

    function test_marketPause_allowsExpireOrders() public {
        // Place an order with a short expiry
        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(
            marketId, 0, Side.BUY, 50, 100e6, block.timestamp + 1
        );

        // Warp past expiry
        vm.warp(block.timestamp + 2);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        // Expire should still work
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        LimitOrdersFacet(address(diamond)).expireOrders(marketId, ids);
    }

    // =========================================================================
    // Market Pause — operator can pause even when venue is paused
    // =========================================================================

    function test_marketPause_worksWhenVenuePaused() public {
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        // Operator can still pause a market (uses requireExistingVenueOperator, not requireActiveVenue)
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        // And unpause
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).unpauseMarket(marketId);
    }

    // =========================================================================
    // Market Pause — recovery
    // =========================================================================

    function test_marketPause_unpauseRestoresTrading() public {
        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).pauseMarket(marketId);

        vm.prank(OPERATOR);
        MarketsFacet(address(diamond)).unpauseMarket(marketId);

        // Trading should work again
        _placeBuyOrder(ALICE, 50, 100e6);
    }

    // =========================================================================
    // Interaction tests — precedence
    // =========================================================================

    function test_protocolPauseTakesPrecedenceOverVenueSuspension() public {
        ProtocolFacet(address(diamond)).suspendVenue(venueId);
        ProtocolFacet(address(diamond)).pauseProtocol();

        // Protocol pause error comes first (checked before venue suspension in requireActiveVenue)
        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        vm.expectRevert(LibProtocolValidator.ProtocolPaused.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e6, 0);
    }

    function test_viewFunctions_returnCorrectState() public {
        assertFalse(ProtocolFacet(address(diamond)).getProtocolPaused());
        assertFalse(ProtocolFacet(address(diamond)).getVenueSuspended(venueId));

        ProtocolFacet(address(diamond)).pauseProtocol();
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        assertTrue(ProtocolFacet(address(diamond)).getProtocolPaused());
        assertTrue(ProtocolFacet(address(diamond)).getVenueSuspended(venueId));

        ProtocolFacet(address(diamond)).unpauseProtocol();
        ProtocolFacet(address(diamond)).unsuspendVenue(venueId);

        assertFalse(ProtocolFacet(address(diamond)).getProtocolPaused());
        assertFalse(ProtocolFacet(address(diamond)).getVenueSuspended(venueId));
    }

    function test_suspensionOnlyAffectsTargetVenue() public {
        // Create a second venue
        vm.prank(OPERATOR);
        uint256 venueId2 = VenueFacet(address(diamond)).createVenue(
            "Venue 2", "", address(0), address(0), FEE_RECIPIENT, 100, 0, TICK_SIZE, 5e6, 0, 1e6
        );

        // Suspend only venue 1
        ProtocolFacet(address(diamond)).suspendVenue(venueId);

        // Venue 2 should still work: create a market on it
        uint256 creationFee = 5e6;
        collateral.mint(BOB, creationFee);
        vm.prank(BOB);
        collateral.approve(address(diamond), creationFee);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(BOB);
        uint256 marketId2 = MarketsFacet(address(diamond)).createMarket(
            venueId2, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        // Trading on venue 2 works
        uint256 col = _collateral(50, 100e6);
        _mintAndApprove(ALICE, col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId2, 0, Side.BUY, 50, 100e6, 0);
    }
}
