// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MarketTradingData, Order, Side} from "../src/interfaces/Types.sol";
import {LibOrderExpiryService} from "../src/services/LibOrderExpiryService.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title OrderExpiry integration tests
 * @notice Tests LimitOrdersFacet.expireOrders: full refund to owner, no penalty, correct skip logic.
 */
contract OrderExpiryTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant TICK = 50;
    uint256 constant QTY = 100e18;
    uint256 constant COLLATERAL_AMOUNT = (TICK * QTY * TICK_SIZE) / 1e18;
    uint256 constant EXPIRY_DELTA = 1 hours;

    address constant ALICE = address(0xA11CE);
    address constant KEEPER = address(0xBEEF);

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
    // BUY order expiry
    // -------------------------------------------------------------------------

    function test_expireBuyOrder_fullRefund() public {
        // Place BUY order with a near-future expiry
        collateral.mint(ALICE, COLLATERAL_AMOUNT);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), COLLATERAL_AMOUNT);
        uint256 expiry = block.timestamp + EXPIRY_DELTA;
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, TICK, QTY, expiry);
        vm.stopPrank();

        // Collateral is now locked in diamond
        assertEq(collateral.balanceOf(ALICE), 0, "collateral locked");
        assertEq(collateral.balanceOf(address(diamond)), COLLATERAL_AMOUNT, "diamond holds collateral");

        // Advance time past expiry
        vm.warp(expiry + 1);

        // Anyone can call expireOrders; KEEPER does it here
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(KEEPER);
        (uint256 expiredCount, uint256 rewardEarned) = LimitOrdersFacet(address(diamond)).expireOrders(marketId, ids);

        // Order removed, full collateral back to ALICE
        assertEq(expiredCount, 1, "one order expired");
        assertEq(rewardEarned, 0, "no keeper reward");
        assertEq(collateral.balanceOf(ALICE), COLLATERAL_AMOUNT, "full refund to owner");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, 0, "order deleted");
    }

    // -------------------------------------------------------------------------
    // SELL order expiry
    // -------------------------------------------------------------------------

    function test_expireSellOrder_fullRefund() public {
        // Split QTY collateral to get exactly QTY YES + QTY NO tokens
        collateral.mint(ALICE, QTY);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), QTY);
        VaultFacet(address(diamond)).splitPosition(marketId, QTY);

        // Approve diamond to take outcome tokens for the SELL order
        ctf.setApprovalForAll(address(diamond), true);

        uint256 expiry = block.timestamp + EXPIRY_DELTA;
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, TICK, QTY, expiry);
        vm.stopPrank();

        // YES tokens are now locked in diamond
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), 0, "YES tokens locked");
        assertEq(ctf.balanceOf(address(diamond), positionIds[0]), QTY, "diamond holds YES");

        // Advance past expiry
        vm.warp(expiry + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(KEEPER);
        (uint256 expiredCount, uint256 rewardEarned) = LimitOrdersFacet(address(diamond)).expireOrders(marketId, ids);

        assertEq(expiredCount, 1, "one order expired");
        assertEq(rewardEarned, 0, "no reward");
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), QTY, "full YES tokens returned");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, 0, "order deleted");
    }

    // -------------------------------------------------------------------------
    // Skip logic
    // -------------------------------------------------------------------------

    function test_expireOrders_notExpired_skipped() public {
        collateral.mint(ALICE, COLLATERAL_AMOUNT);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), COLLATERAL_AMOUNT);
        uint256 expiry = block.timestamp + EXPIRY_DELTA;
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, TICK, QTY, expiry);
        vm.stopPrank();

        // Do NOT advance time — order is still live
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        (uint256 expiredCount,) = LimitOrdersFacet(address(diamond)).expireOrders(marketId, ids);

        assertEq(expiredCount, 0, "no orders expired");
        assertEq(collateral.balanceOf(ALICE), 0, "collateral still locked");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, orderId, "order still exists");
    }

    function test_expireOrders_noExpiry_skipped() public {
        // GTC order (expiry = 0) should never expire
        collateral.mint(ALICE, COLLATERAL_AMOUNT);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), COLLATERAL_AMOUNT);
        uint256 orderId = LimitOrdersFacet(address(diamond))
            .placeOrder(
                marketId,
                0,
                Side.BUY,
                TICK,
                QTY,
                0 // expiry = 0 means GTC
            );
        vm.stopPrank();

        // Warp far into the future
        vm.warp(block.timestamp + 365 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        (uint256 expiredCount,) = LimitOrdersFacet(address(diamond)).expireOrders(marketId, ids);

        assertEq(expiredCount, 0, "GTC order never expires");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, orderId, "order still exists");
    }

    function test_expireOrders_wrongMarket_skipped() public {
        // Create a second market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        uint256 otherMarketId =
            MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        // Place order on the FIRST market
        collateral.mint(ALICE, COLLATERAL_AMOUNT);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), COLLATERAL_AMOUNT);
        uint256 expiry = block.timestamp + EXPIRY_DELTA;
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, TICK, QTY, expiry);
        vm.stopPrank();

        vm.warp(expiry + 1);

        // Try to expire using the SECOND market's ID — should skip
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        (uint256 expiredCount,) = LimitOrdersFacet(address(diamond)).expireOrders(otherMarketId, ids);

        assertEq(expiredCount, 0, "wrong market skipped");
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, orderId, "order untouched");
    }
}
