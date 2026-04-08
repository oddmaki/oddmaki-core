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
import {MarketTradingData, Side} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title Surplus Fix Tests
 * @notice TDD tests for:
 *   Finding 1 — Ceiling division in checkMintFeasibility
 *   Finding 2A — Surplus routing to protocol treasury in mint/merge fills
 *
 * Tests 1-3 are designed to FAIL before implementation and PASS after,
 * confirming the issues exist and are fixed.
 * Tests 4-6 should PASS both before and after (regression guards).
 */
contract SurplusFixTest is Test, DiamondSetup {
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

    // Fee config: 100 bps venue, 30 bps creator
    uint256 constant VENUE_FEE_BPS = 100;
    uint256 constant CREATOR_FEE_BPS = 30;
    uint256 constant PROTOCOL_FEE_BPS = 20;
    uint256 constant OPERATOR_FEE_BPS = 10;
    // Total = 20 + 100 + 10 = 130 bps (creator is sub-split of venue, not additive)
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
            "Surplus Fix Venue",
            "",
            address(0), // public trading
            address(0), // public creation
            FEE_RECIPIENT,
            VENUE_FEE_BPS, // 100 bps
            CREATOR_FEE_BPS, // 30 bps
            TICK_SIZE,
            5e6, // marketCreationFee
            0,
            1e6
        );

        // Create market
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
    // Finding 1: Ceiling division — should FAIL before fix, PASS after
    // =========================================================================

    /**
     * @notice Bids summing to 101 should be REJECTED with ceiling division.
     *
     * Math: fullPriceTicks=100, totalFeeBps=130
     *   Floor: minRequired = floor(100 * 10130 / 10000) = floor(101.3) = 101  ← allows sum=101
     *   Ceiling: minRequired = ceil(100 * 10130 / 10000) = ceil(101.3) = 102  ← rejects sum=101
     *
     * This test FAILS before the fix because the floor-based check permits the fill.
     */
    function test_mintFeasibility_rejectsBorderlineBids() public {
        uint256 yesTick = 61;
        uint256 noTick = 40; // sum = 101
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 0, "sum=101 should be rejected with ceiling division");
    }

    // =========================================================================
    // Finding 2A: Mint surplus routing — should FAIL before fix, PASS after
    // =========================================================================

    /**
     * @notice Mint fill with bids summing well above min should route surplus to treasury.
     *
     * yesBid=65 + noBid=40 = 105 (well above min ~102)
     * surplus = yesCollateral + noCollateral - qty - totalFee
     * Treasury should receive: protocolFee + remainder + surplus
     *
     * FAILS before fix because surplus stays in Diamond.
     */
    function test_mintFill_surplusRoutedToTreasury() public {
        uint256 yesTick = 65;
        uint256 noTick = 40; // sum = 105
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

        uint256 treasuryReceived = collateral.balanceOf(TREASURY) - treasuryBefore;

        // Calculate expected amounts
        uint256 yesCollateral = _collateral(yesTick, qty);
        uint256 noCollateral = _collateral(noTick, qty);
        uint256 totalDeposited = yesCollateral + noCollateral;

        // Fee components (fee base = qty for mint fills)
        uint256 protocolFee = (qty * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 creatorFee = (qty * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 venueNetFee = (qty * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        uint256 operatorFee = (qty * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFeeComponents = protocolFee + creatorFee + venueNetFee + operatorFee;
        uint256 expectedTotal = (qty * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 remainder = expectedTotal > totalFeeComponents ? expectedTotal - totalFeeComponents : 0;

        // Surplus = what buyers deposited - split cost - all fees
        uint256 surplus = totalDeposited - qty - expectedTotal;

        // Treasury should receive: protocolFee + remainder + surplus
        uint256 expectedTreasuryTotal = protocolFee + remainder + surplus;

        assertEq(treasuryReceived, expectedTreasuryTotal, "treasury should receive protocol fee + remainder + surplus");
    }

    // =========================================================================
    // Finding 2A: Merge surplus routing — should FAIL before fix, PASS after
    // =========================================================================

    /**
     * @notice Merge fill with asks summing well below max should route surplus to treasury.
     *
     * yesAsk=45 + noAsk=45 = 90 (well below maxAllowed ~98)
     * surplus = qty - yesCollateral - noCollateral - totalFee
     * Treasury should receive: protocolFee + remainder + surplus
     *
     * FAILS before fix because surplus stays in Diamond.
     */
    function test_mergeFill_surplusRoutedToTreasury() public {
        uint256 yesAsk = 45;
        uint256 noAsk = 45; // sum = 90
        uint256 qty = 100e18;

        // ALICE holds YES tokens, BOB holds NO tokens
        _splitForUser(ALICE, qty);
        _splitForUser(BOB, qty);

        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, yesAsk, qty, 0);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.SELL, noAsk, qty, 0);

        uint256 treasuryBefore = collateral.balanceOf(TREASURY);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        uint256 treasuryReceived = collateral.balanceOf(TREASURY) - treasuryBefore;

        // Calculate expected amounts
        uint256 yesCollateral = _collateral(yesAsk, qty);
        uint256 noCollateral = _collateral(noAsk, qty);

        // Fee components (fee base = qty for merge fills)
        uint256 protocolFee = (qty * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 creatorFee = (qty * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 venueNetFee = (qty * (VENUE_FEE_BPS - CREATOR_FEE_BPS)) / BPS_DENOMINATOR;
        uint256 operatorFee = (qty * OPERATOR_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFeeComponents = protocolFee + creatorFee + venueNetFee + operatorFee;
        uint256 expectedTotal = (qty * TOTAL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 remainder = expectedTotal > totalFeeComponents ? expectedTotal - totalFeeComponents : 0;

        // Surplus = merge released (qty) - seller payouts - all fees
        uint256 surplus = qty - yesCollateral - noCollateral - expectedTotal;

        // Treasury should receive: protocolFee + remainder + surplus
        uint256 expectedTreasuryTotal = protocolFee + remainder + surplus;

        assertEq(treasuryReceived, expectedTreasuryTotal, "treasury should receive protocol fee + remainder + surplus");
    }

    // =========================================================================
    // Regression guards — should PASS both before and after
    // =========================================================================

    /**
     * @notice Bids summing to 104 should always fill (above both floor=101 and ceiling=102).
     */
    function test_mintFeasibility_acceptsSufficientBids() public {
        uint256 yesTick = 62;
        uint256 noTick = 42; // sum = 104
        uint256 qty = 100e18;

        _mintAndApprove(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, yesTick, qty, 0);

        _mintAndApprove(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 1, Side.BUY, noTick, qty, 0);

        vm.prank(OPERATOR);
        uint256 fillCount = MatchingFacet(address(diamond)).matchOrders(marketId, 10);
        assertEq(fillCount, 1, "sum=104 should always fill");
    }

    /**
     * @notice Mint fill without treasury should not revert (backward compatible).
     */
    function test_mintFill_noTreasury_noRevert() public {
        // Deploy fresh diamond without treasury
        OddMaki d2 = deployDiamond(address(this));
        MockCTF ctf2 = new MockCTF();
        MockERC20 col2 = new MockERC20("T2", "T2", 6);
        VaultFacet(address(d2)).setCtf(address(ctf2));
        ProtocolFacet(address(d2)).setCollateralWhitelisted(address(col2), true);
        // NOTE: no setProtocolTreasury call — fees disabled

        uint256 vid = VenueFacet(address(d2)).createVenue(
            "No Fee Venue", "", address(0), address(0), address(this), 100, 0, TICK_SIZE, 5e6, 0, 1e6
        );

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        uint256 mid = MarketsFacet(address(d2)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(col2), 0, 0, new bytes32[](0)
        );

        uint256 yesTick = 60;
        uint256 noTick = 40;
        uint256 qty = 100e18;

        col2.mint(ALICE, _collateral(yesTick, qty));
        vm.prank(ALICE);
        col2.approve(address(d2), _collateral(yesTick, qty));
        vm.prank(ALICE);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 0, Side.BUY, yesTick, qty, 0);

        col2.mint(CAROL, _collateral(noTick, qty));
        vm.prank(CAROL);
        col2.approve(address(d2), _collateral(noTick, qty));
        vm.prank(CAROL);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 1, Side.BUY, noTick, qty, 0);

        uint256 fillCount = MatchingFacet(address(d2)).matchOrders(mid, 10);
        assertEq(fillCount, 1, "should fill without treasury (no fees)");
    }

    /**
     * @notice Merge fill without treasury should not revert (backward compatible).
     */
    function test_mergeFill_noTreasury_noRevert() public {
        // Deploy fresh diamond without treasury
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
        uint256 mid = MarketsFacet(address(d2)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(col2), 0, 0, new bytes32[](0)
        );

        uint256 yesAsk = 45;
        uint256 noAsk = 45;
        uint256 qty = 100e18;

        // Split tokens for ALICE and BOB
        col2.mint(ALICE, qty);
        vm.startPrank(ALICE);
        col2.approve(address(d2), qty);
        VaultFacet(address(d2)).splitPosition(mid, qty);
        ctf2.setApprovalForAll(address(d2), true);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 0, Side.SELL, yesAsk, qty, 0);
        vm.stopPrank();

        col2.mint(BOB, qty);
        vm.startPrank(BOB);
        col2.approve(address(d2), qty);
        VaultFacet(address(d2)).splitPosition(mid, qty);
        ctf2.setApprovalForAll(address(d2), true);
        LimitOrdersFacet(address(d2)).placeOrder(mid, 1, Side.SELL, noAsk, qty, 0);
        vm.stopPrank();

        uint256 fillCount = MatchingFacet(address(d2)).matchOrders(mid, 10);
        assertEq(fillCount, 1, "should fill merge without treasury (no fees)");
    }

    // =========================================================================
    // withdrawERC20 tests
    // =========================================================================

    function test_withdrawERC20_ownerCanWithdraw() public {
        // Seed the Diamond with some collateral
        uint256 amount = 1000e6;
        collateral.mint(address(diamond), amount);

        address recipient = address(0xBEEF);
        uint256 before = collateral.balanceOf(recipient);

        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), recipient, amount);

        assertEq(collateral.balanceOf(recipient) - before, amount, "recipient received tokens");
        assertEq(collateral.balanceOf(address(diamond)), 0, "diamond drained");
    }

    function test_withdrawERC20_nonOwnerReverts() public {
        collateral.mint(address(diamond), 1000e6);

        vm.prank(ALICE);
        vm.expectRevert();
        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), ALICE, 1000e6);
    }

    function test_withdrawERC20_zeroTokenReverts() public {
        vm.expectRevert("Invalid token");
        ProtocolFacet(address(diamond)).withdrawERC20(address(0), address(this), 100);
    }

    function test_withdrawERC20_zeroRecipientReverts() public {
        vm.expectRevert("Invalid recipient");
        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), address(0), 100);
    }

    function test_withdrawERC20_zeroAmountReverts() public {
        vm.expectRevert("Zero amount");
        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), address(this), 0);
    }

    function test_withdrawERC20_emitsEvent() public {
        uint256 amount = 500e6;
        collateral.mint(address(diamond), amount);

        address recipient = address(0xBEEF);
        vm.expectEmit(true, true, false, true);
        emit ERC20Withdrawn(address(collateral), recipient, amount);
        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), recipient, amount);
    }

    function test_withdrawERC20_insufficientBalanceReverts() public {
        // Diamond has no collateral balance
        vm.expectRevert();
        ProtocolFacet(address(diamond)).withdrawERC20(address(collateral), address(this), 1000e6);
    }

    // Mirror event for expectEmit
    event ERC20Withdrawn(address indexed token, address indexed recipient, uint256 amount);
}
