// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {BatchOrdersFacet} from "../src/facets/BatchOrdersFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketTradingData, Order, Side} from "../src/interfaces/Types.sol";
import {BatchOrderParams} from "../src/interfaces/IBatchOrders.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title BatchOrdersFacet integration tests
 * @notice Tests batch place, batch cancel, and cancel-and-replace operations.
 */
contract BatchOrdersTest is Test, DiamondSetup {
    OddMaki public diamond;
    address public owner;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256 constant TICK_SIZE = 1e16; // 1%
    bytes32 public conditionId;
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
                venueId,
                "",
                outcomes,
                TICK_SIZE,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
        conditionId = MarketsFacet(address(diamond)).getMarketOracleData(marketId).conditionId;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _fundAndApprove(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(diamond), type(uint256).max);
    }

    function _splitAndApprove(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.startPrank(user);
        collateral.approve(address(diamond), type(uint256).max);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
        ctf.setApprovalForAll(address(diamond), true);
        vm.stopPrank();
    }

    function _collateral(uint256 tick, uint256 qty) internal pure returns (uint256) {
        return (tick * qty * TICK_SIZE) / 1e18;
    }

    // =========================================================================
    // batchPlaceOrders
    // =========================================================================

    function test_batchPlaceOrders_singleBuyOrder() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        BatchOrderParams[] memory orders = new BatchOrderParams[](1);
        orders[0] = BatchOrderParams(0, Side.BUY, tick, qty, 0);

        vm.prank(ALICE);
        uint256[] memory ids = BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);

        assertEq(ids.length, 1);
        Order memory o = LimitOrdersFacet(address(diamond)).getOrder(ids[0]);
        assertEq(o.owner, ALICE);
        assertEq(o.tick, tick);
        assertEq(o.qty, qty);
        assertTrue(o.side == Side.BUY);
    }

    function test_batchPlaceOrders_bidAskLadder() public {
        // 3 BUY orders at ticks 40, 45, 48
        // 3 SELL orders at ticks 52, 55, 60 (YES outcome)
        uint256 qty = 50e18;
        uint256 totalBuyCollateral = _collateral(40, qty) + _collateral(45, qty) + _collateral(48, qty);
        uint256 totalSellTokens = qty * 3;

        _fundAndApprove(ALICE, totalBuyCollateral);
        _splitAndApprove(ALICE, totalSellTokens); // splits give YES+NO tokens

        BatchOrderParams[] memory orders = new BatchOrderParams[](6);
        orders[0] = BatchOrderParams(0, Side.BUY, 40, qty, 0);
        orders[1] = BatchOrderParams(0, Side.BUY, 45, qty, 0);
        orders[2] = BatchOrderParams(0, Side.BUY, 48, qty, 0);
        orders[3] = BatchOrderParams(0, Side.SELL, 52, qty, 0);
        orders[4] = BatchOrderParams(0, Side.SELL, 55, qty, 0);
        orders[5] = BatchOrderParams(0, Side.SELL, 60, qty, 0);

        vm.prank(ALICE);
        uint256[] memory ids = BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);

        assertEq(ids.length, 6);
        // Verify all orders exist and have correct sides
        for (uint256 i; i < 3; i++) {
            Order memory o = LimitOrdersFacet(address(diamond)).getOrder(ids[i]);
            assertTrue(o.side == Side.BUY);
            assertEq(o.owner, ALICE);
        }
        for (uint256 i = 3; i < 6; i++) {
            Order memory o = LimitOrdersFacet(address(diamond)).getOrder(ids[i]);
            assertTrue(o.side == Side.SELL);
            assertEq(o.owner, ALICE);
        }
        // Order IDs should be sequential
        for (uint256 i = 1; i < 6; i++) {
            assertEq(ids[i], ids[i - 1] + 1);
        }
    }

    function test_batchPlaceOrders_mixedOutcomes() public {
        // BUY YES + SELL NO in same batch
        uint256 qty = 50e18;
        uint256 buyCollateral = _collateral(50, qty);

        _fundAndApprove(ALICE, buyCollateral);
        _splitAndApprove(ALICE, qty); // need NO tokens for SELL NO

        BatchOrderParams[] memory orders = new BatchOrderParams[](2);
        orders[0] = BatchOrderParams(0, Side.BUY, 50, qty, 0); // BUY YES
        orders[1] = BatchOrderParams(1, Side.SELL, 50, qty, 0); // SELL NO

        vm.prank(ALICE);
        uint256[] memory ids = BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);

        assertEq(ids.length, 2);
        Order memory buyOrder = LimitOrdersFacet(address(diamond)).getOrder(ids[0]);
        assertEq(buyOrder.outcomeId, 0);
        assertTrue(buyOrder.side == Side.BUY);

        Order memory sellOrder = LimitOrdersFacet(address(diamond)).getOrder(ids[1]);
        assertEq(sellOrder.outcomeId, 1);
        assertTrue(sellOrder.side == Side.SELL);
    }

    function test_batchPlaceOrders_revertEmptyBatch() public {
        BatchOrderParams[] memory orders = new BatchOrderParams[](0);
        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.EmptyBatch.selector);
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);
    }

    function test_batchPlaceOrders_revertBatchTooLarge() public {
        BatchOrderParams[] memory orders = new BatchOrderParams[](21);
        for (uint256 i; i < 21; i++) {
            orders[i] = BatchOrderParams(0, Side.BUY, 50, 100e18, 0);
        }
        _fundAndApprove(ALICE, _collateral(50, 100e18) * 21);
        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.BatchTooLarge.selector);
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);
    }

    function test_batchPlaceOrders_revertMarketNotActive() public {
        _fundAndApprove(ALICE, _collateral(50, 100e18));
        BatchOrderParams[] memory orders = new BatchOrderParams[](1);
        orders[0] = BatchOrderParams(0, Side.BUY, 50, 100e18, 0);

        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.MarketNotActive.selector);
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(999, orders);
    }

    function test_batchPlaceOrders_revertInsufficientCollateral() public {
        // Fund only enough for 1 order, try to place 2
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty)); // only enough for 1

        BatchOrderParams[] memory orders = new BatchOrderParams[](2);
        orders[0] = BatchOrderParams(0, Side.BUY, tick, qty, 0);
        orders[1] = BatchOrderParams(0, Side.BUY, tick, qty, 0);

        vm.prank(ALICE);
        vm.expectRevert(); // ERC20 transferFrom will revert
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);
    }

    function test_batchPlaceOrders_aggregatedTransfer() public {
        // Place 5 BUY orders — should result in a single aggregated collateral transfer
        uint256 tick = 50;
        uint256 qty = 20e18;
        uint256 totalCollateral = _collateral(tick, qty) * 5;

        _fundAndApprove(ALICE, totalCollateral);

        BatchOrderParams[] memory orders = new BatchOrderParams[](5);
        for (uint256 i; i < 5; i++) {
            orders[i] = BatchOrderParams(0, Side.BUY, tick, qty, 0);
        }

        vm.prank(ALICE);
        uint256[] memory ids = BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);

        assertEq(ids.length, 5);
        // All collateral moved from ALICE to Diamond
        assertEq(collateral.balanceOf(ALICE), 0);
        assertEq(collateral.balanceOf(address(diamond)), totalCollateral);
    }

    function test_batchPlaceOrders_withExpiry() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 futureExpiry = block.timestamp + 1 hours;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        BatchOrderParams[] memory orders = new BatchOrderParams[](1);
        orders[0] = BatchOrderParams(0, Side.BUY, tick, qty, futureExpiry);

        vm.prank(ALICE);
        uint256[] memory ids = BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, orders);

        Order memory o = LimitOrdersFacet(address(diamond)).getOrder(ids[0]);
        assertEq(o.expiry, futureExpiry);
    }

    // =========================================================================
    // batchCancelOrders
    // =========================================================================

    function test_batchCancelOrders_multiple() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 perOrder = _collateral(tick, qty);
        _fundAndApprove(ALICE, perOrder * 3);

        // Place 3 orders individually
        vm.startPrank(ALICE);
        uint256 id1 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        uint256 id2 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        uint256 id3 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        vm.stopPrank();

        assertEq(collateral.balanceOf(ALICE), 0);

        // Batch cancel all 3
        uint256[] memory cancelIds = new uint256[](3);
        cancelIds[0] = id1;
        cancelIds[1] = id2;
        cancelIds[2] = id3;

        vm.prank(ALICE);
        uint256 cancelled = BatchOrdersFacet(address(diamond)).batchCancelOrders(cancelIds);

        assertEq(cancelled, 3);
        // All collateral refunded
        assertEq(collateral.balanceOf(ALICE), perOrder * 3);
        // Orders deleted
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(id1).id, 0);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(id2).id, 0);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(id3).id, 0);
    }

    function test_batchCancelOrders_revertNotOwner() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.prank(BOB);
        vm.expectRevert("Unauthorized cancel");
        BatchOrdersFacet(address(diamond)).batchCancelOrders(ids);
    }

    function test_batchCancelOrders_revertEmptyBatch() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.EmptyBatch.selector);
        BatchOrdersFacet(address(diamond)).batchCancelOrders(ids);
    }

    function test_batchCancelOrders_revertBatchTooLarge() public {
        uint256[] memory ids = new uint256[](101);
        for (uint256 i; i < 101; i++) {
            ids[i] = i + 1;
        }
        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.BatchTooLarge.selector);
        BatchOrdersFacet(address(diamond)).batchCancelOrders(ids);
    }

    // =========================================================================
    // cancelAndReplace
    // =========================================================================

    function test_cancelAndReplace_basic() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 perOrder = _collateral(tick, qty);
        _fundAndApprove(ALICE, perOrder * 5); // enough for old + new orders

        // Place 2 old orders
        vm.startPrank(ALICE);
        uint256 oldId1 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        uint256 oldId2 = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        vm.stopPrank();

        // Cancel 2 old, place 3 new at different ticks
        uint256[] memory cancelIds = new uint256[](2);
        cancelIds[0] = oldId1;
        cancelIds[1] = oldId2;

        BatchOrderParams[] memory newOrders = new BatchOrderParams[](3);
        newOrders[0] = BatchOrderParams(0, Side.BUY, 40, qty, 0);
        newOrders[1] = BatchOrderParams(0, Side.BUY, 45, qty, 0);
        newOrders[2] = BatchOrderParams(0, Side.BUY, 48, qty, 0);

        vm.prank(ALICE);
        (uint256 cancelled, uint256[] memory newIds) = BatchOrdersFacet(address(diamond)).cancelAndReplace(
            marketId, cancelIds, newOrders
        );

        assertEq(cancelled, 2);
        assertEq(newIds.length, 3);
        // Old orders deleted
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(oldId1).id, 0);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(oldId2).id, 0);
        // New orders exist with correct ticks
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(newIds[0]).tick, 40);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(newIds[1]).tick, 45);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(newIds[2]).tick, 48);
    }

    function test_cancelAndReplace_cancelOnlyPhase() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        uint256[] memory cancelIds = new uint256[](1);
        cancelIds[0] = orderId;
        BatchOrderParams[] memory empty = new BatchOrderParams[](0);

        vm.prank(ALICE);
        (uint256 cancelled, uint256[] memory newIds) = BatchOrdersFacet(address(diamond)).cancelAndReplace(
            marketId, cancelIds, empty
        );

        assertEq(cancelled, 1);
        assertEq(newIds.length, 0);
        assertEq(collateral.balanceOf(ALICE), _collateral(tick, qty));
    }

    function test_cancelAndReplace_placeOnlyPhase() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        uint256[] memory emptyCancel = new uint256[](0);
        BatchOrderParams[] memory newOrders = new BatchOrderParams[](1);
        newOrders[0] = BatchOrderParams(0, Side.BUY, tick, qty, 0);

        vm.prank(ALICE);
        (uint256 cancelled, uint256[] memory newIds) = BatchOrdersFacet(address(diamond)).cancelAndReplace(
            marketId, emptyCancel, newOrders
        );

        assertEq(cancelled, 0);
        assertEq(newIds.length, 1);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(newIds[0]).tick, tick);
    }

    function test_cancelAndReplace_revertEmptyBothPhases() public {
        uint256[] memory emptyCancel = new uint256[](0);
        BatchOrderParams[] memory emptyPlace = new BatchOrderParams[](0);

        vm.prank(ALICE);
        vm.expectRevert(BatchOrdersFacet.EmptyBatch.selector);
        BatchOrdersFacet(address(diamond)).cancelAndReplace(marketId, emptyCancel, emptyPlace);
    }

    function test_cancelAndReplace_atomicRollback() public {
        // If new order placement fails, cancels should also revert
        uint256 tick = 50;
        uint256 qty = 100e18;
        _fundAndApprove(ALICE, _collateral(tick, qty));

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        uint256[] memory cancelIds = new uint256[](1);
        cancelIds[0] = orderId;

        // New order with insufficient funds (cancel frees collateral but we need more)
        BatchOrderParams[] memory newOrders = new BatchOrderParams[](2);
        newOrders[0] = BatchOrderParams(0, Side.BUY, tick, qty, 0);
        newOrders[1] = BatchOrderParams(0, Side.BUY, tick, qty, 0); // no funds for this second one

        vm.prank(ALICE);
        vm.expectRevert(); // revert in ERC20 transferFrom
        BatchOrdersFacet(address(diamond)).cancelAndReplace(marketId, cancelIds, newOrders);

        // Original order still exists (tx was atomic)
        assertGt(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, 0);
    }

    // =========================================================================
    // Gas comparison
    // =========================================================================

    function test_batchPlaceOrders_gasEfficiency() public {
        uint256 tick = 50;
        uint256 qty = 20e18;
        uint256 count = 10;
        uint256 perOrder = _collateral(tick, qty);

        // Measure: 10 individual placeOrder calls
        _fundAndApprove(ALICE, perOrder * count);
        uint256 gasIndividual;
        vm.startPrank(ALICE);
        uint256 gasBefore = gasleft();
        for (uint256 i; i < count; i++) {
            LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
        }
        gasIndividual = gasBefore - gasleft();
        vm.stopPrank();

        // Create a second market for a clean orderbook comparison
        string[] memory outcomes2 = new string[](2);
        outcomes2[0] = "Yes";
        outcomes2[1] = "No";
        uint256 marketId2 = MarketsFacet(address(diamond))
            .createMarket(venueId, "", outcomes2, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        // Measure: batch of 10
        _fundAndApprove(ALICE, perOrder * count);
        BatchOrderParams[] memory orders = new BatchOrderParams[](count);
        for (uint256 i; i < count; i++) {
            orders[i] = BatchOrderParams(0, Side.BUY, tick, qty, 0);
        }
        vm.prank(ALICE);
        uint256 gasBatch;
        gasBefore = gasleft();
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId2, orders);
        gasBatch = gasBefore - gasleft();
        vm.stopPrank();

        // Batch should be cheaper than individual (saves tx overhead + aggregated transfer)
        assertTrue(gasBatch < gasIndividual, "Batch should use less gas than individual calls");
    }
}
