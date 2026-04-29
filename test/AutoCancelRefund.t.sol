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
import {MarketTradingData, Side, Order} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title AutoCancelRefundTest
 * @notice Regression for ODD-16 [C-01]: auto-cancelled BUY remainder stranded taker collateral.
 *         When a BUY taker crosses a smaller SELL maker at bid==ask with fees enabled,
 *         the BUY order's remainder is auto-cancelled. The never-attempted portion of the
 *         buyer's escrow (qty_initial - sellQty) * bid * tickSize must be refunded instead
 *         of silently retained by the Diamond.
 */
contract AutoCancelRefundTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant TREASURY = address(0x7EA5);
    address constant FEE_RECIPIENT = address(0xFEE);
    address constant MARKET_CREATOR = address(0xC8EA);
    address constant OPERATOR = address(0x0FE8A70E);

    uint256 constant VENUE_FEE_BPS = 100;
    uint256 constant CREATOR_FEE_BPS = 30;
    uint256 constant PROTOCOL_FEE_BPS = 50;
    uint256 constant OPERATOR_FEE_BPS = 10;
    uint256 constant TOTAL_FEE_BPS = PROTOCOL_FEE_BPS + VENUE_FEE_BPS + OPERATOR_FEE_BPS; // 160
    uint256 constant BPS_DENOMINATOR = 10_000;

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
            "C-01 Venue",
            "",
            address(0),
            address(0),
            FEE_RECIPIENT,
            VENUE_FEE_BPS,
            CREATOR_FEE_BPS,
            TICK_SIZE,
            5e6,
            0,
            1e6
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

    /**
     * @notice C-01: BUY taker with remainder must be refunded on auto-cancel.
     *
     * Setup: SELL maker 50 at tick=60 (orderId=1), BUY taker 100 at tick=60 (orderId=2).
     * The affordable-reduction trims fill qty to ~49.21; the remaining ~50.79 shares in the
     * BUY order trigger the auto-cancel branch. The never-attempted portion
     * (buyQty - sellQty) = 50 shares worth of escrow (= 30e18) must come back to ALICE.
     */
    function test_c01_autoCancelledBuyRemainder_refundsEscrow() public {
        uint256 tick = 60;
        uint256 buyQty = 100e18;
        uint256 sellQty = 50e18;
        uint256 buyerDeposit = _collateral(tick, buyQty); // 60e18

        // SELL maker first (orderId=1)
        _splitForUser(BOB, sellQty);
        vm.prank(BOB);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, tick, sellQty, 0);

        // BUY taker second (orderId=2) — full deposit escrowed
        _mintAndApprove(ALICE, buyerDeposit);
        vm.prank(ALICE);
        uint256 aliceOrderId =
            LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, tick, buyQty, 0);

        uint256 aliceWalletBefore = collateral.balanceOf(ALICE);
        uint256 vaultBefore = collateral.balanceOf(address(diamond));

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(marketId, 10);

        // Order auto-cancelled
        Order memory aliceOrder = LimitOrdersFacet(address(diamond)).getOrder(aliceOrderId);
        assertEq(aliceOrder.id, 0, "ALICE order auto-cancelled");

        // Mirror the service arithmetic (integer-exact):
        //   affordableQty = baseQty * bestBid * BPS / (bestAsk * (BPS + totalFeeBps))
        uint256 affordableQty =
            (sellQty * tick * BPS_DENOMINATOR) / (tick * (BPS_DENOMINATOR + TOTAL_FEE_BPS));
        uint256 fillCost = _collateral(tick, affordableQty);
        uint256 feeTotal = (fillCost * TOTAL_FEE_BPS) / BPS_DENOMINATOR;

        // Line 116 within-fill refund: baseQty*bid*ts - qty*ask*ts - fee (integer dust near 0)
        uint256 baseDeposit = _collateral(tick, sellQty);
        uint256 withinFillRefund =
            baseDeposit > (fillCost + feeTotal) ? baseDeposit - (fillCost + feeTotal) : 0;

        // Auto-cancel refund: escrow for the never-attempted portion (buyQty - baseQty)
        uint256 expectedAutoCancelRefund = _collateral(tick, buyQty - sellQty);

        uint256 totalRefundToAlice = withinFillRefund + expectedAutoCancelRefund;
        uint256 vaultOutflow = fillCost + feeTotal + totalRefundToAlice;

        assertGt(expectedAutoCancelRefund, 0, "precondition: refund is strictly positive");
        assertEq(
            collateral.balanceOf(ALICE) - aliceWalletBefore,
            totalRefundToAlice,
            "ALICE refund matches never-attempted escrow"
        );
        assertEq(
            vaultBefore - collateral.balanceOf(address(diamond)),
            vaultOutflow,
            "vault decrease == fill cost + fees + refund"
        );

        // Diamond must not strand collateral after the only order in the book is settled.
        assertEq(
            collateral.balanceOf(address(diamond)),
            0,
            "no collateral stranded in Diamond after auto-cancel"
        );

        // Sanity: ALICE got the filled tokens
        assertEq(
            ctf.balanceOf(ALICE, positionIds[0]),
            affordableQty,
            "ALICE received the affordable filled qty of outcome tokens"
        );
    }
}
