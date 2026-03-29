// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {MarketTradingData, Order, Side, TickLevel, Fill, SettlementPath} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @title OrderBook facet integration tests
/// @notice Tests OrderBookFacet view functions: tick levels, top-of-book, mark price, depth queries.
contract OrderBookFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA801);

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
    // getTopOfBook
    // -------------------------------------------------------------------------

    function test_getTopOfBook_emptyBook_returnsZero() public {
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.BUY), 0);
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.SELL), 0);
    }

    function test_getTopOfBook_afterPlaceOrder() public {
        _mintAndApprove(ALICE, _collateral(50, 100e18));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);

        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.BUY), 50);
        assertEq(OrderBookFacet(address(diamond)).getTopOfBook(marketId, 0, Side.SELL), 0);
    }

    // -------------------------------------------------------------------------
    // getTickLevel
    // -------------------------------------------------------------------------

    function test_getTickLevel_emptyLevel() public {
        TickLevel memory level = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, 50);
        assertEq(level.headOrderId, 0);
        assertEq(level.depth, 0);
        assertEq(level.totalQty, 0);
    }

    function test_getTickLevel_afterPlaceOrder() public {
        _mintAndApprove(ALICE, _collateral(50, 100e18));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);

        TickLevel memory level = OrderBookFacet(address(diamond)).getTickLevel(marketId, 0, Side.BUY, 50);
        assertTrue(level.headOrderId != 0, "head order set");
        assertEq(level.depth, 1, "one order at level");
        assertEq(level.totalQty, 100e18, "total qty");
    }

    // -------------------------------------------------------------------------
    // getMarkPrice
    // -------------------------------------------------------------------------

    function test_getMarkPrice_tightSpread_returnsMidpoint() public {
        // BUY @ 49, SELL @ 51 → spread = 2 <= 10 → midpoint = 50
        _mintAndApprove(ALICE, _collateral(49, 100e18));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 49, 100e18, 0);

        _splitForUser(BOB, 100e18);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 51, 100e18, 0);

        (uint256 price, bool isDefined) = OrderBookFacet(address(diamond)).getMarkPrice(marketId, 0);
        assertTrue(isDefined, "mark price defined");
        assertEq(price, 50, "midpoint of 49 and 51");
    }

    function test_getMarkPrice_wideSpread_fallsBackToLastTrade() public {
        // First create a trade to set lastTradeTick
        uint256 tick = 60;
        uint256 qty = 50e18;
        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Now place wide spread: BUY @ 30, SELL @ 70 → spread = 40 > 10
        _mintAndApprove(ALICE, _collateral(30, 100e18));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 30, 100e18, 0);

        _splitForUser(CAROL, 100e18);
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 70, 100e18, 0);

        (uint256 price, bool isDefined) = OrderBookFacet(address(diamond)).getMarkPrice(marketId, 0);
        assertTrue(isDefined, "mark price defined via lastTrade");
        assertEq(price, tick, "lastTradeTick");
    }

    function test_getMarkPrice_noData_returnsUndefined() public {
        (uint256 price, bool isDefined) = OrderBookFacet(address(diamond)).getMarkPrice(marketId, 0);
        assertFalse(isDefined, "no data");
        assertEq(price, 0);
    }

    function test_getMarkPrice_oneSideOnly_noLastTrade_returnsUndefined() public {
        // Only a BUY order, no SELL, no last trade
        _mintAndApprove(ALICE, _collateral(50, 100e18));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);

        (uint256 price, bool isDefined) = OrderBookFacet(address(diamond)).getMarkPrice(marketId, 0);
        assertFalse(isDefined, "only one side, no last trade");
        assertEq(price, 0);
    }

    // -------------------------------------------------------------------------
    // getFill / getNextFillId
    // -------------------------------------------------------------------------

    function test_getNextFillId_beforeAnyFill() public {
        assertEq(OrderBookFacet(address(diamond)).getNextFillId(), 0, "no fills yet");
    }

    function test_getFill_afterMatching() public {
        uint256 tick = 60;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        uint256 buyOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        uint256 sellOrderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        assertEq(OrderBookFacet(address(diamond)).getNextFillId(), 1, "one fill recorded");

        Fill memory fill = OrderBookFacet(address(diamond)).getFill(1);
        assertEq(fill.id, 1, "fill id");
        assertEq(fill.marketId, marketId, "fill marketId");
        assertTrue(fill.path == SettlementPath.NORMAL, "normal fill path");
        assertEq(fill.order1Id, buyOrderId, "buy order");
        assertEq(fill.order2Id, sellOrderId, "sell order");
        assertEq(fill.qty, qty, "fill qty");
        assertEq(fill.priceTick, tick, "fill price tick");
    }
}
