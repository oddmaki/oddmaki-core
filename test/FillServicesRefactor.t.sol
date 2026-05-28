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
import {MarketTradingData, Side} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title FillServicesRefactorTest
 * @notice Regression coverage for the PR-1 extraction of `_executeFill` helpers
 *         out of `LibNormalFillService`, `LibMintFillService`, and
 *         `LibMergeFillService`. These cases pin behaviors that depend on the
 *         exact body that was moved into the new helpers — if a future change
 *         (or this refactor) drifts the math, these will fail before any
 *         downstream consumer (market-take service, matching engine) does.
 *
 *         Venue is configured to mirror the production scenario reported by
 *         a real user: protocol=50, venue=50, creator=0, operator=10 → total 110 bps.
 *         minRequiredTicks (mint) = ceil(100 * 10110 / 10000) = 102.
 *         maxAllowedTicks  (merge) = floor(100 *  9890 / 10000) =  98.
 */
contract FillServicesRefactorTest is Test, DiamondSetup {
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
    event OrderFilled(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 qty,
        uint256 priceTick
    );

    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16; // 1 tick = 1%
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE; // 100

    // Venue config matching the user-reported production setup
    uint256 constant PROTOCOL_FEE_BPS = 50;
    uint256 constant VENUE_FEE_BPS = 50;
    uint256 constant CREATOR_FEE_BPS = 0;
    // OPERATOR_FEE_BPS = 10 (protocol constant)
    // TOTAL_FEE_BPS = 110

    address constant ALICE = address(0xA11CE); // YES buyer / YES seller
    address constant CAROL = address(0xCA801); // NO  buyer / NO  seller
    address constant BOB   = address(0xB0B);   // 3rd party
    address constant OPERATOR = address(0x0FE8A70E);
    address constant TREASURY = address(0x7EA5);
    address constant FEE_RECIPIENT = address(0xFEE);
    address constant MARKET_CREATOR = address(0xC8EA);

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
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);
        ProtocolFacet(address(diamond)).setProtocolFeeBps(PROTOCOL_FEE_BPS);

        vm.prank(MARKET_CREATOR);
        venueId = VenueFacet(address(diamond)).createVenue(
            "Refactor Test Venue",
            "",
            address(0), // public trading
            address(0), // public creation
            FEE_RECIPIENT,
            VENUE_FEE_BPS,
            CREATOR_FEE_BPS,
            TICK_SIZE,
            0,
            0,
            1e6
        );

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Up";
        outcomes[1] = "Down";
        vm.prank(MARKET_CREATOR);
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // -----------------------------------------------------------------------
    // Mint-to-fill — user's exact production scenario
    // -----------------------------------------------------------------------

    /// @notice Up@47 + Down@55 sums to 102 = minRequiredTicks → mint cross fires.
    function test_mintFill_userScenario_47_plus_55_crosses() public {
        uint256 upTick = 47;
        uint256 downTick = 55;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(upTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, upTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(downTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, downTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "47 + 55 = 102 must cross at 110 bps fees");

        assertEq(ctf.balanceOf(ALICE, positionIds[0]), qty, "ALICE received Up");
        assertEq(ctf.balanceOf(CAROL, positionIds[1]), qty, "CAROL received Down");
    }

    /// @notice Up@47 + Down@54 sums to 101 = minRequiredTicks - 1 → mint must NOT fire.
    ///         This is the exact state where the user originally hit "won't cross."
    function test_mintFill_userScenario_47_plus_54_doesNotCross() public {
        uint256 upTick = 47;
        uint256 downTick = 54;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(upTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, upTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(downTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, downTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "101 ticks total must NOT cross (1 tick below threshold)");
    }

    /// @notice Mint fill emits the original `MintFill` event with the refactored helper.
    function test_mintFill_eventStillEmitted_postRefactor() public {
        uint256 upTick = 47;
        uint256 downTick = 55;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(upTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, upTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(downTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, downTick, qty, 0);

        // yesOrderId=1, noOrderId=2 (allocated in placement order)
        vm.expectEmit(true, true, true, true);
        emit MintFill(marketId, qty, 1, 2, upTick, downTick);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    // -----------------------------------------------------------------------
    // Merge-to-fill — boundary parity
    // -----------------------------------------------------------------------

    /// @notice maxAllowedTicks (merge) = floor(100 * 9890 / 10000) = 98.
    ///         Up_ask=48 + Down_ask=50 = 98 → at boundary, must cross.
    function test_mergeFill_atBoundary_crosses() public {
        uint256 upAsk = 48;
        uint256 downAsk = 50;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, upAsk, qty, 0);

        _splitForUser(CAROL, qty);
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, downAsk, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "48 + 50 = 98 must cross at 110 bps fees");
    }

    /// @notice Up_ask=48 + Down_ask=51 = 99 > maxAllowedTicks → must NOT cross.
    function test_mergeFill_oneOverBoundary_doesNotCross() public {
        uint256 upAsk = 48;
        uint256 downAsk = 51;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, upAsk, qty, 0);

        _splitForUser(CAROL, qty);
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, downAsk, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "99 ticks total must NOT cross merge at 110 bps");
    }

    // -----------------------------------------------------------------------
    // Normal-fill taker fee buffer — affordable-qty reduction still active
    // -----------------------------------------------------------------------

    /// @notice Buyer (taker) bids at ask price exactly with 110 bps fees → must
    ///         reduce qty so the deposit covers ask + fee. Refactor preserves
    ///         the `affordableQty` branch.
    function test_normalFill_buyerTaker_feeBufferReducesQty() public {
        uint256 tick = 50; // both bid and ask at 50
        uint256 qty = 100e18;

        // Seller (maker) places first
        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // Buyer (taker) bids same tick — fee makes them unable to afford full qty
        _mintAndApprove(BOB, _collateral(tick, qty));
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Buyer should NOT receive the full qty (fee buffer reduces).
        // Affordable = qty * 50 * 10000 / (50 * 10110) ≈ qty * 0.9891
        uint256 buyerTokens = ctf.balanceOf(BOB, positionIds[0]);
        assertLt(buyerTokens, qty, "fee buffer must reduce taker qty");
        assertGt(buyerTokens, 0, "some fill expected");
    }

    // -----------------------------------------------------------------------
    // Refactor parity: events + last-trade tick recorded the same way
    // -----------------------------------------------------------------------

    function test_mintFill_lastTradeTicksRecorded() public {
        uint256 upTick = 50;
        uint256 downTick = 55; // 105 > 102 → crosses with surplus
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(upTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, upTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(downTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, downTick, qty, 0);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertEq(td.lastTradeTick[0], upTick, "Up lastTradeTick");
        assertEq(td.lastTradeTick[1], downTick, "Down lastTradeTick");
    }

    function test_mergeFill_eventStillEmitted_postRefactor() public {
        uint256 upAsk = 48;
        uint256 downAsk = 50;
        uint256 qty = 100e18;

        _splitForUser(ALICE, qty);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, upAsk, qty, 0);

        _splitForUser(CAROL, qty);
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, downAsk, qty, 0);

        // yesOrderId=1, noOrderId=2
        vm.expectEmit(true, true, true, true);
        emit MergeFill(marketId, qty, 1, 2, upAsk, downAsk);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }

    function test_normalFill_eventStillEmitted_postRefactor() public {
        uint256 tick = 60;
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(tick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, qty, 0);

        _splitForUser(BOB, qty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, qty, 0);

        // buyOrderId=1, sellOrderId=2, marketId, outcomeId=0, qty, priceTick=tick
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(1, 2, marketId, 0, qty, tick);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
    }
}
