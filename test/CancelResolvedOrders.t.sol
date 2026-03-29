// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {MarketRegistryData, MarketTradingData, Order, Side} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";

/**
 * @title CancelResolvedOrders integration tests
 * @notice Tests the permissionless batch cancel of orders on resolved markets (audit H-4).
 */
contract CancelResolvedOrdersTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockUmaOracle public umaOracle;
    uint256 public marketId;
    uint256 public venueId;
    bytes32 public questionId;

    uint256 constant TICK_SIZE = 1e16;
    bytes32 constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant ASSERTER = address(0xA553E7);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        umaOracle = new MockUmaOracle();

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(diamond)).setUmaIdentifier(UMA_IDENTIFIER);

        venueId = createDefaultVenue(address(diamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );
        questionId = MarketsFacet(address(diamond)).getMarketRegistryData(marketId).questionId;
    }

    // ---- Helpers ----

    function _placeBuyOrder(address user, uint256 tick, uint256 qty) internal returns (uint256) {
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;
        collateral.mint(user, col);
        vm.prank(user);
        collateral.approve(address(diamond), col);
        vm.prank(user);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);
    }

    function _placeSellOrder(address user, uint256 tick, uint256 qty) internal returns (uint256) {
        collateral.mint(user, qty);
        vm.startPrank(user);
        collateral.approve(address(diamond), qty);
        VaultFacet(address(diamond)).splitPosition(marketId, qty);
        ctf.setApprovalForAll(address(diamond), true);
        vm.stopPrank();
        vm.prank(user);
        return LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);
    }

    function _resolveMarketYes() internal {
        collateral.mint(ASSERTER, 1e18);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), 1e18);
        vm.prank(ASSERTER);
        bytes32 assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "Yes");
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");
    }

    // ---- Tests ----

    function test_batchCancel_buyOrder_refundsCollateral() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;
        uint256 orderId = _placeBuyOrder(ALICE, tick, qty);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 1);
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId).id, 0);
        assertEq(collateral.balanceOf(ALICE), col);
    }

    function test_batchCancel_sellOrder_refundsOutcomeTokens() public {
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 orderId = _placeSellOrder(ALICE, tick, qty);

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        uint256 posId = td.positionIds[0];
        assertEq(ctf.balanceOf(ALICE, posId), 0);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 1);
        assertEq(ctf.balanceOf(ALICE, posId), qty);
    }

    function test_batchCancel_permissionless_nonOwnerCanCancel() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e18);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        // BOB calls cancel — not the order owner
        vm.prank(BOB);
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 1);
        // Refund still goes to ALICE (the order owner)
        uint256 col = (50 * 100e18 * TICK_SIZE) / 1e18;
        assertEq(collateral.balanceOf(ALICE), col);
    }

    function test_batchCancel_revertsOnActiveMarket() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.expectRevert(LimitOrdersFacet.MarketNotResolved.selector);
        LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);
    }

    function test_batchCancel_skipsAlreadyDeletedOrders() public {
        uint256 orderId1 = _placeBuyOrder(ALICE, 50, 100e18);
        uint256 orderId2 = _placeBuyOrder(ALICE, 60, 50e18);

        // ALICE cancels order1 before market resolves
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).cancelOrder(orderId1);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](2);
        ids[0] = orderId1; // already deleted
        ids[1] = orderId2; // still active

        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 1); // only orderId2 cancelled
        assertEq(LimitOrdersFacet(address(diamond)).getOrder(orderId2).id, 0);
    }

    function test_batchCancel_mixedBuyAndSell() public {
        uint256 buyTick = 40;
        uint256 buyQty = 200e18;
        uint256 sellTick = 70;
        uint256 sellQty = 150e18;

        uint256 buyOrderId = _placeBuyOrder(ALICE, buyTick, buyQty);
        uint256 sellOrderId = _placeSellOrder(BOB, sellTick, sellQty);

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        uint256 posId = td.positionIds[0];

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](2);
        ids[0] = buyOrderId;
        ids[1] = sellOrderId;
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 2);

        // Verify refunds
        uint256 buyCol = (buyTick * buyQty * TICK_SIZE) / 1e18;
        assertEq(collateral.balanceOf(ALICE), buyCol);
        assertEq(ctf.balanceOf(BOB, posId), sellQty);
    }

    function test_batchCancel_revertsBatchTooLarge() public {
        _placeBuyOrder(ALICE, 50, 100e18);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](101);
        for (uint256 i = 0; i < 101; i++) {
            ids[i] = 1;
        }

        vm.expectRevert(LimitOrdersFacet.BatchTooLarge.selector);
        LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);
    }

    function test_batchCancel_revertsOrderInWrongMarket() public {
        uint256 orderId = _placeBuyOrder(ALICE, 50, 100e18);

        // Create a second market and resolve it
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        uint256 marketId2 = MarketsFacet(address(diamond)).createMarket(
            venueId, "q2", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );
        bytes32 questionId2 = MarketsFacet(address(diamond)).getMarketRegistryData(marketId2).questionId;

        collateral.mint(ASSERTER, 1e18);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), 1e18);
        vm.prank(ASSERTER);
        bytes32 assertionId2 = ResolutionFacet(address(diamond)).assertMarketOutcome(questionId2, "Yes");
        ResolutionFacet(address(diamond)).settleAssertion(assertionId2);
        ResolutionFacet(address(diamond)).reportResolution(marketId2, "Yes");

        // Try to cancel order from marketId using marketId2
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.expectRevert("Order not in market");
        LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId2, ids);
    }

    function test_batchCancel_emptyArrayReturnsZero() public {
        _resolveMarketYes();

        uint256[] memory ids = new uint256[](0);
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 0);
    }

    function test_batchCancel_multipleOrdersSameTick() public {
        uint256 tick = 50;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;

        uint256 orderId1 = _placeBuyOrder(ALICE, tick, qty);
        uint256 orderId2 = _placeBuyOrder(ALICE, tick, qty);

        _resolveMarketYes();

        uint256[] memory ids = new uint256[](2);
        ids[0] = orderId1;
        ids[1] = orderId2;
        uint256 cancelled = LimitOrdersFacet(address(diamond)).cancelOrdersOnResolvedMarket(marketId, ids);

        assertEq(cancelled, 2);
        assertEq(collateral.balanceOf(ALICE), col * 2);
    }
}
