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
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {OrderBookFacet} from "../src/facets/OrderBookFacet.sol";
import {MarketTradingData, Side, MarketOrderType, MarketBuyResult, MarketSellResult} from "../src/interfaces/Types.sol";
import {LibMarketTakeService} from "../src/services/LibMarketTakeService.sol";
import {LibMarketOrderValidator} from "../src/validators/LibMarketOrderValidator.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title MarketTakeServiceTest
 * @notice End-to-end coverage for PR 3: multi-path market BUY / SELL via
 *         placeMarketBuy / placeMarketSell, including the user-reported
 *         bug scenario (mint-fill against opposite-outcome resting bid).
 *
 *         Venue mirrors the production fee config the user runs:
 *         protocol=50 / venue=50 / creator=0 / operator=10 → totalFeeBps=110.
 */
contract MarketTakeServiceTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    uint256 constant MAX_TICK = 1e18 / TICK_SIZE; // 100

    uint256 constant PROTOCOL_FEE_BPS = 50;
    uint256 constant VENUE_FEE_BPS = 50;
    uint256 constant CREATOR_FEE_BPS = 0;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA801);
    address constant TAKER = address(0x7A4E1);
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

    function _place(address user, uint256 outcomeId, Side side, uint256 tick, uint256 qty) internal {
        vm.prank(user);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, outcomeId, side, tick, qty, 0);
    }

    /// @dev Seed a tiny same-outcome trade so getMarkPrice's last-trade
    ///      fallback returns a defined tick (needed when the implied book
    ///      is crossed or one-sided in test setups).
    function _seedLastTrade(uint256 outcomeId, uint256 tick) internal {
        uint256 q = 1e18;
        // tiny matched trade — uses normal-fill so it's path-agnostic
        _mintAndApprove(BOB, _collateral(tick, q));
        _place(BOB, outcomeId, Side.BUY, tick, q);

        _splitForUser(CAROL, q);
        _place(CAROL, outcomeId, Side.SELL, tick, q);

        MatchingFacet(address(diamond)).matchOrders(marketId, 10);
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
            "PR3 Test Venue",
            "",
            address(0),
            address(0),
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

    // =========================================================================
    // BUY — single-path: normal fill only (same-outcome ask available)
    // =========================================================================

    /// @notice Market BUY against a same-outcome ask with no opposite liquidity.
    function test_buy_normalPath_singleAsk() public {
        // Up has an ASK at 50, no other liquidity. markTick falls back to
        // last-trade; seed a same-outcome trade at 50 so mark is defined.
        _seedLastTrade(0, 50);

        // Place the ASK the taker will consume.
        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 50, 100e18);

        // Taker budget: enough for 50 tokens at 50¢ + 1.1% fees ≈ 25.275 ≈ 26.
        uint256 budget = 30e18;
        _mintAndApprove(TAKER, budget);

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 500 /* 5% slippage */, MarketOrderType.FAK
        );

        assertGt(r.tokensReceived, 0, "taker received Up tokens");
        assertEq(ctf.balanceOf(TAKER, positionIds[0]), r.tokensReceived, "taker actually holds tokens");
        assertGt(r.collateralSpent, 0);
        assertEq(r.collateralSpent + r.unusedCollateral, budget, "budget conserved");
    }

    // =========================================================================
    // BUY — single-path: mint fill (the user-reported scenario)
    // =========================================================================

    /// @notice Up bid at 47 resting, Down asks empty, Down bids at 53/54 resting.
    ///         Market BUY Down with 5% slippage above mark must mint-fill
    ///         against Up at 47 (taker tick = 100 − 47 = 53).
    function test_buy_mintPath_userScenario() public {
        // Seed a Down last-trade so the mark price has a fallback when the
        // implied book is crossed (47 / 46 → crossed → falls to last trade).
        _seedLastTrade(1, 55);

        _mintAndApprove(ALICE, _collateral(47, 100e18));
        _place(ALICE, 0, Side.BUY, 47, 100e18); // Up bid

        _mintAndApprove(BOB, _collateral(53, 100e18));
        _place(BOB, 1, Side.BUY, 53, 100e18);   // Down bid 53

        _mintAndApprove(CAROL, _collateral(54, 100e18));
        _place(CAROL, 1, Side.BUY, 54, 100e18); // Down bid 54

        // Taker market BUYs Down with 5% slippage above mark.
        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);

        // Sanity: mark price for Down — falls to seeded last trade (55) since
        // implied book is crossed. Slippage cap = 55 + ceil(55*500/10000) = 58.
        (uint256 markTick, bool defined) = OrderBookFacet(address(diamond)).getMarkPrice(marketId, 1);
        assertTrue(defined, "Down mark defined via last trade");
        assertEq(markTick, 55, "Down mark = last trade tick");

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 1, budget, 500, MarketOrderType.FAK
        );

        assertGt(r.tokensReceived, 0, "Down tokens received via mint fill");
        assertEq(ctf.balanceOf(TAKER, positionIds[1]), r.tokensReceived);

        // The Up at 47 maker must have been served their Up tokens via the mint.
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), r.tokensReceived, "Up maker received Up tokens");
    }

    // =========================================================================
    // BUY — multi-path: cheapest path picked per step
    // =========================================================================

    /// @notice Two paths available; expect the cheaper one to fill first.
    ///         Up ask at 60 (normal cost ~= 60*(1.011) = 61), Down bid at 50
    ///         (mint cost = 50 + ceil(1.1) = 52). Mint cheaper -> mint first.
    function test_buy_multiPath_picksMintFirstWhenCheaper() public {
        _seedLastTrade(0, 55); // mark for Up

        _splitForUser(BOB, 100e18);
        _place(BOB, 0, Side.SELL, 60, 100e18); // Up ask 60

        _mintAndApprove(CAROL, _collateral(50, 100e18));
        _place(CAROL, 1, Side.BUY, 50, 100e18); // Down bid 50

        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 2000, MarketOrderType.FAK
        );

        // Carol (Down bid maker) must have received Down tokens via mint —
        // proves mint path was used at least once.
        assertGt(ctf.balanceOf(CAROL, positionIds[1]), 0, "Carol got Down tokens (mint path)");
        // Taker got Up tokens.
        assertGt(ctf.balanceOf(TAKER, positionIds[0]), 0, "Taker got Up tokens");
        assertGt(r.collateralSpent, 0);
    }

    // =========================================================================
    // BUY — slippage cap
    // =========================================================================

    /// @notice First-step-anchor semantics: with 0% slippage the take fills
    ///         the first (displayed best) price but cannot walk further into
    ///         worse levels. Anchor locks at the cheapest available cost on
    ///         iteration 0; subsequent steps must be less than or equal to
    ///         that exact cost.
    function test_buy_slippageZero_capsAtFirstLevel() public {
        // Tier 1: 5 tokens at tick 50. Tier 2: 5 tokens at tick 60.
        _splitForUser(BOB, 5e18);
        _place(BOB, 0, Side.SELL, 50, 5e18);

        _splitForUser(CAROL, 5e18);
        _place(CAROL, 0, Side.SELL, 60, 5e18);

        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 0, MarketOrderType.FAK
        );

        // 0% slippage anchors at step-0 cheapest cost (ceil(50 × 1.011) = 51).
        // Tier-2 cost ceil(60 × 1.011) = 61 exceeds the cap, so the loop
        // stops after consuming tier 1.
        assertEq(r.tokensReceived, 5e18, "filled only the first level");
        assertGt(r.unusedCollateral, 0, "remainder refunded - walk capped");
    }

    function test_buy_slippageOverMax_reverts() public {
        _seedLastTrade(0, 50);
        _mintAndApprove(TAKER, 100e18);
        vm.prank(TAKER);
        vm.expectRevert(LibMarketTakeService.SlippageTooHigh.selector);
        MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, 100e18, 5000, MarketOrderType.FAK
        );
    }

    function test_buy_emptyBook_reverts() public {
        // No orders, no trades → take loop finds no liquidity on any path,
        // facet catches `filledQty == 0` and reverts NoLiquidityAvailable.
        _mintAndApprove(TAKER, 100e18);
        vm.prank(TAKER);
        vm.expectRevert(LibMarketOrderValidator.NoLiquidityAvailable.selector);
        MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, 100e18, 500, MarketOrderType.FAK
        );
    }

    /// @notice User-reported regression from mainnet: market has Up bids
    ///         resting at 50 and 56, no other liquidity, no trades. Before
    ///         the first-step-anchor refactor this reverted with
    ///         NoReferencePrice because the mark-price waterfall was
    ///         undefined. After the refactor the take service anchors at
    ///         the cheapest available mint cross and the order fills.
    function test_buy_anchorsAgainstImpliedAskWithoutMark() public {
        _mintAndApprove(ALICE, _collateral(50, 100e18));
        _place(ALICE, 0, Side.BUY, 50, 100e18); // Up bid at 50

        _mintAndApprove(BOB, _collateral(56, 100e18));
        _place(BOB, 0, Side.BUY, 56, 100e18);   // Up bid at 56 (best)

        // Sanity: getMarkPrice for Down is undefined (no midpoint, no trade).
        (uint256 markTick, bool markDefined) =
            OrderBookFacet(address(diamond)).getMarkPrice(marketId, 1);
        assertFalse(markDefined, "Down mark must be undefined");
        assertEq(markTick, 0);

        // Market BUY Down with 5% slippage. Cheapest cross is mint against
        // Up at 56: tick cost = (100 - 56) + ceil(100 * 110/10000) = 44 + 2 = 46.
        // Anchor = 46; cap = 46 + ceil(46 * 5%) = 46 + 3 = 49. 46 ≤ 49 → fills.
        uint256 budget = 50e18;
        _mintAndApprove(TAKER, budget);

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 1, budget, 500, MarketOrderType.FAK
        );

        assertGt(r.tokensReceived, 0, "Down tokens minted via opposite-outcome cross");
        assertEq(ctf.balanceOf(TAKER, positionIds[1]), r.tokensReceived);
        assertGt(ctf.balanceOf(BOB, positionIds[0]), 0, "Up maker got Up tokens via the CTF split");
    }

    /// @notice Pins that the slippage cap is locked at step 0 — a taker
    ///         cannot "self-justify" extra slippage by walking the book.
    ///         The cap snapshotted on iteration 0 binds every subsequent
    ///         step, even if the per-step cheapest cost rises monotonically.
    function test_buy_capLockedAtStepZero() public {
        // Three tiers: 5 tokens at 50, 5 at 60, 5 at 70.
        _splitForUser(BOB, 5e18);
        _place(BOB, 0, Side.SELL, 50, 5e18);

        _splitForUser(CAROL, 5e18);
        _place(CAROL, 0, Side.SELL, 60, 5e18);

        address dave = address(0xDA7E);
        _splitForUser(dave, 5e18);
        _place(dave, 0, Side.SELL, 70, 5e18);

        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);

        // 20% slippage: anchor = ceil(50 * 1.011) = 51, cap = 51 + ceil(51*20%) = 51 + 11 = 62.
        // Tier 1 cost = 51 ≤ 62 → fills. Tier 2 cost = ceil(60*1.011) = 61 ≤ 62 → fills.
        // Tier 3 cost = ceil(70*1.011) = 71 > 62 → stops. Total taken: 10 of 15 available.
        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 2000, MarketOrderType.FAK
        );

        assertEq(r.tokensReceived, 10e18, "tier 3 blocked by step-0 cap");
        assertGt(r.unusedCollateral, 0, "unspent budget refunded");
    }

    // =========================================================================
    // BUY — FOK vs FAK
    // =========================================================================

    function test_buy_FAK_refundsUnusedBudget() public {
        _seedLastTrade(0, 50);

        // Small ask: 10 tokens at 50¢. Taker budgets way more.
        _splitForUser(BOB, 10e18);
        _place(BOB, 0, Side.SELL, 50, 10e18);

        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);
        uint256 balBefore = collateral.balanceOf(TAKER);

        vm.prank(TAKER);
        MarketBuyResult memory r = MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 500, MarketOrderType.FAK
        );

        assertGt(r.unusedCollateral, 0, "FAK returns unspent budget");
        uint256 balAfter = collateral.balanceOf(TAKER);
        // Wallet delta is slightly less than r.collateralSpent because the
        // 10-bps operator fee gets routed to msg.sender (the taker themselves
        // for market orders). Accounting still balances: spent + unused == budget.
        assertLt(balBefore - balAfter, r.collateralSpent);
        assertEq(r.collateralSpent + r.unusedCollateral, budget, "spent + unused == budget");
    }

    function test_buy_FOK_revertsOnPartial() public {
        _seedLastTrade(0, 50);

        _splitForUser(BOB, 10e18);
        _place(BOB, 0, Side.SELL, 50, 10e18);

        uint256 budget = 100e18;
        _mintAndApprove(TAKER, budget);

        vm.prank(TAKER);
        vm.expectRevert(LibMarketOrderValidator.InsufficientLiquidityForFOK.selector);
        MarketOrdersFacet(address(diamond)).placeMarketBuy(
            marketId, 0, budget, 500, MarketOrderType.FOK
        );
    }

    // =========================================================================
    // SELL — mirror coverage (normal + merge paths)
    // =========================================================================

    function test_sell_mergePath_userScenarioMirror() public {
        // Up ask @55 resting + Down ask @45 resting → merge cross feasible.
        // Taker market SELL Down tokens; expected to merge against Up @55.
        _seedLastTrade(1, 50); // Down mark defined

        _splitForUser(ALICE, 100e18);
        _place(ALICE, 0, Side.SELL, 55, 100e18); // Up ask

        _splitForUser(TAKER, 100e18); // give taker Down tokens via split

        vm.prank(TAKER);
        MarketSellResult memory r = MarketOrdersFacet(address(diamond)).placeMarketSell(
            marketId, 1, 50e18 /* sell 50 Down */, 2000, MarketOrderType.FAK
        );

        // Should fill against Up @55 via merge — taker gets net proceeds.
        assertGt(r.collateralReceived, 0, "taker received proceeds");
        assertGt(r.tokensSold, 0, "sold some Down tokens");
        // Alice (Up ask maker) got paid for her tokens.
        assertGt(collateral.balanceOf(ALICE), 0, "Up maker paid out");
    }

    function test_sell_FAK_refundsUnsoldTokens() public {
        _seedLastTrade(0, 50);

        _mintAndApprove(ALICE, _collateral(50, 5e18));
        _place(ALICE, 0, Side.BUY, 50, 5e18); // small bid

        _splitForUser(TAKER, 100e18);
        uint256 takerUpBefore = ctf.balanceOf(TAKER, positionIds[0]);

        vm.prank(TAKER);
        MarketSellResult memory r = MarketOrdersFacet(address(diamond)).placeMarketSell(
            marketId, 0, 100e18, 500, MarketOrderType.FAK
        );

        assertGt(r.unsoldTokens, 0, "FAK returns unsold tokens");
        uint256 takerUpAfter = ctf.balanceOf(TAKER, positionIds[0]);
        // Taker's Up balance reduces by exactly soldQty.
        assertEq(takerUpBefore - takerUpAfter, r.tokensSold, "balance delta == sold");
    }

    function test_sell_FOK_revertsOnPartial() public {
        _seedLastTrade(0, 50);

        _mintAndApprove(ALICE, _collateral(50, 5e18));
        _place(ALICE, 0, Side.BUY, 50, 5e18);

        _splitForUser(TAKER, 100e18);
        vm.prank(TAKER);
        vm.expectRevert(LibMarketOrderValidator.InsufficientLiquidityForFOK.selector);
        MarketOrdersFacet(address(diamond)).placeMarketSell(
            marketId, 0, 100e18, 500, MarketOrderType.FOK
        );
    }
}
