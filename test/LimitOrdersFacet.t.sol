// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MarketTradingData, MarketOracleData, Order, Side} from "../src/interfaces/Types.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {LibOrderAggregate} from "../src/aggregates/LibOrderAggregate.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title LimitOrdersFacet integration tests
 * @notice Create market via MarketsFacet, then place/cancel limit orders.
 */
contract LimitOrdersFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    address public owner;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256 constant TICK_SIZE = 1e16; // 1%
    bytes32 public conditionId; // set in setUp from storage after createMarket
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    function setUp() public {
        owner = address(this);
        diamond = deployDiamond(owner);
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        marketId = MarketsFacet(address(diamond))
            .createMarket(
                venueId, // venueId
                "", // ancillaryData
                outcomes,
                TICK_SIZE,
                address(collateral),
                0, // additionalReward
                0, // liveness
                new bytes32[](0) // tags
            );
        // Read back the conditionId computed by the oracle service (keccak256 of Diamond + questionId + 2).
        conditionId = MarketsFacet(address(diamond)).getMarketOracleData(marketId).conditionId;
    }

    function test_createMarket_returnsIdOne() public view {
        assertEq(marketId, 1);
        assertEq(MarketsFacet(address(diamond)).getNextMarketId(), 1);
    }

    function test_getMarketConfig_afterCreate() public view {
        MarketTradingData memory trading = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertEq(trading.tickSize, TICK_SIZE);
        assertTrue(trading.active);
        assertEq(address(trading.collateralToken), address(collateral));
        assertEq(trading.positionIds[0], _positionId(conditionId, 0));
        assertEq(trading.positionIds[1], _positionId(conditionId, 1));

        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(oracle.conditionId, conditionId);
    }

    function test_placeBuyOrder() public {
        uint256 tick = 50; // tick level (1 to maxTick=1e18/tickSize=100); 50 => 50% for tickSize 1e16
        uint256 qty = 100e18;
        uint256 collateralAmount = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, collateralAmount);
        vm.prank(ALICE);
        collateral.approve(address(diamond), collateralAmount);

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        assertEq(orderId, 1);
        Order memory order = LimitOrdersFacet(address(diamond)).getOrder(orderId);
        assertEq(order.id, 1);
        assertEq(order.qty, qty);
        assertEq(order.marketId, marketId);
        assertEq(order.owner, ALICE);
        assertEq(order.tick, tick);
        assertTrue(order.side == Side.BUY);
        assertEq(order.outcomeId, 0);
        assertEq(order.originalQty, qty);
        // Enqueued as only order at level: head and tail (next/prev both 0)
        assertEq(order.nextOrderId, 0);
        assertEq(order.prevOrderId, 0);
    }

    function test_placeTwoBuyOrdersSameTick_fifoQueuePointers() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 collateralAmount = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, collateralAmount * 2);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), collateralAmount * 2);

        uint256 orderId1 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        uint256 orderId2 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        vm.stopPrank();

        assertEq(orderId1, 1);
        assertEq(orderId2, 2);
        Order memory o1 = LimitOrdersFacet(address(diamond)).getOrder(orderId1);
        Order memory o2 = LimitOrdersFacet(address(diamond)).getOrder(orderId2);
        // FIFO: first is head (prev=0), second is tail (next=0); first.next = second, second.prev = first
        assertEq(o1.prevOrderId, 0);
        assertEq(o1.nextOrderId, orderId2);
        assertEq(o2.prevOrderId, orderId1);
        assertEq(o2.nextOrderId, 0);
    }

    function test_cancelOrder_removesOrderAndRefundsCollateral() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 collateralAmount = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, collateralAmount);
        vm.prank(ALICE);
        collateral.approve(address(diamond), collateralAmount);

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        assertEq(orderId, 1);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 1);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(1);

        assertEq(LimitOrdersFacet(address(diamond)).getOrder(1).id, 0);
        assertEq(collateral.balanceOf(ALICE), collateralAmount);
    }

    function test_cancelOrder_revertsWhenNotOwner() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 collateralAmount = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, collateralAmount);
        vm.prank(ALICE);
        collateral.approve(address(diamond), collateralAmount);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        vm.prank(BOB);
        vm.expectRevert("Unauthorized cancel");
        LimitOrdersFacet(address(diamond)).cancelOrder(1);
    }

    function test_placeOrder_revertsForInvalidTick_zero() public {
        collateral.mint(ALICE, 1000e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.InvalidTick.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 0, 100e18, 0);
    }

    function test_placeOrder_revertsForInvalidTick_aboveMax() public {
        uint256 maxTick = 1e18 / TICK_SIZE; // 100
        collateral.mint(ALICE, 1000e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.InvalidTick.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, maxTick + 1, 100e18, 0);
    }

    function test_placeOrder_revertsForZeroQuantity() public {
        collateral.mint(ALICE, 1000e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.InvalidQuantity.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 0, 0);
    }

    function test_placeOrder_revertsForExpiredExpiry() public {
        collateral.mint(ALICE, 1000e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.OrderExpired.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, block.timestamp);
    }

    // ---- M-6/L-1: Minimum order value (dust orders) ----

    function test_M6_placeOrder_revertsForZeroCollateralBuyOrder() public {
        // tick=1, qty=1 => collateral = (1 * 1 * 1e16) / 1e18 = 0
        collateral.mint(ALICE, 1e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);

        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.OrderTooSmall.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 1, 1, 0);
    }

    function test_M6_placeOrder_revertsJustBelowMinimum() public {
        // tick=1, qty=99 => 1 * 99 * 1e16 = 99e16 < 1e18 => should revert
        collateral.mint(ALICE, 1e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);

        vm.prank(ALICE);
        vm.expectRevert(LibOrderAggregate.OrderTooSmall.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 1, 99, 0);
    }

    function test_M6_placeOrder_succeedsAtMinimumValue() public {
        // tick=1, qty=100 => 1 * 100 * 1e16 = 1e18 >= 1e18 => should succeed
        uint256 col = (1 * 100 * TICK_SIZE) / 1e18; // = 1
        collateral.mint(ALICE, col);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 1, 100, 0);
        assertTrue(orderId > 0, "Order should be placed at minimum value");
    }

    // ---- M-3: Venue pause blocks order placement ----

    function test_M3_placeOrder_revertsWhenVenuePaused() public {
        VenueFacet(address(diamond)).pauseVenue(venueId);

        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, col);
        vm.prank(ALICE);
        collateral.approve(address(diamond), col);

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.VenueInactive.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
    }

    function test_M3_cancelOrder_succeedsWhenVenuePaused() public {
        // Place order while venue is active
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(ALICE, col);
        vm.prank(ALICE);
        collateral.approve(address(diamond), col);
        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        // Pause venue — user should still be able to cancel and reclaim funds
        VenueFacet(address(diamond)).pauseVenue(venueId);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(orderId);
        assertEq(collateral.balanceOf(ALICE), col, "ALICE should get collateral back");
    }

    function _positionId(bytes32 cId, uint256 indexSet) internal view returns (uint256) {
        bytes32 parent = bytes32(0);
        bytes32 collectionId = keccak256(abi.encodePacked(parent, cId, indexSet + 1));
        return uint256(keccak256(abi.encodePacked(address(collateral), collectionId)));
    }
}
