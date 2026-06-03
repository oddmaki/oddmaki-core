// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {DpmMarketFacet} from "../src/facets/DpmMarketFacet.sol";
import {DpmTradingFacet} from "../src/facets/DpmTradingFacet.sol";
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {BatchOrdersFacet} from "../src/facets/BatchOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {PythResolutionFacet} from "../src/facets/PythResolutionFacet.sol";
import {PriceMarketFacet} from "../src/facets/PriceMarketFacet.sol";
import {LibDpmValidator} from "../src/validators/LibDpmValidator.sol";
import {DpmMarket, MarketRegistryData, Side, MarketOrderType} from "../src/interfaces/Types.sol";
import {BatchOrderParams} from "../src/interfaces/IBatchOrders.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";
import {MockPythUnique} from "./helpers/MockPythUnique.sol";

/**
 * @title DPM market end-to-end tests
 * @notice Drives the full DPM lifecycle through the diamond: intent, lazy transition, dynamic
 *         Pennock entries, resolution + claim, no-contest / invalid refunds, and the cross-mode
 *         guard. The default venue here has the protocol treasury unset, so trading fees are
 *         disabled — this lets the worked example reproduce the exact $50 pool. A dedicated test
 *         enables fees and checks the entry-fee solvency invariant separately.
 */
contract DpmMarketTest is Test, DiamondSetup {
    OddMaki internal diamond;
    MockCTF internal ctf;
    MockERC20 internal collateral;
    MockUmaOracle internal umaOracle;
    MockPythUnique internal mockPyth;
    uint256 internal venueId;

    bytes32 internal constant ETH_USD_FEED = bytes32(uint256(0xff61));
    int32 internal constant PRICE_EXPO = -8;
    int64 internal constant STRIKE_PRICE = 2500e8; // $2500
    address internal constant RESOLVER = address(0x8E501);

    address internal constant CREATOR = address(0xC8EA);
    address internal constant ASSERTER = address(0xA553E7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA801);
    address internal constant DAVE = address(0xDA7E);

    uint256 internal constant USDC = 1e6;
    uint256 internal constant YES = 0;
    uint256 internal constant NO = 1;
    bytes32 internal constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        umaOracle = new MockUmaOracle();

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(diamond)).setUmaIdentifier(UMA_IDENTIFIER);

        mockPyth = new MockPythUnique(60, 1); // 60s valid period, 1 wei fee
        PythResolutionFacet(address(diamond)).setPythContract(address(mockPyth));
        vm.deal(RESOLVER, 1 ether);
        // Prime the feed so getPriceUnsafe (read at creation for the exponent) returns a value.
        bytes[] memory initData = new bytes[](1);
        initData[0] = mockPyth.createPriceFeedUpdateData(ETH_USD_FEED, 2000e8, 0, PRICE_EXPO, 2000e8, 0, uint64(block.timestamp));
        mockPyth.updatePriceFeeds{value: 1}(initData);

        venueId = createDefaultVenue(address(diamond));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _market() internal view returns (DpmMarketFacet) {
        return DpmMarketFacet(address(diamond));
    }

    function _trade() internal view returns (DpmTradingFacet) {
        return DpmTradingFacet(address(diamond));
    }

    function _createMarket(uint256 openTime, uint256 closeTime) internal returns (uint256 marketId) {
        // Creator pays the 5 USDC venue creation fee (umaReward is 0 on the default venue).
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        marketId = _market().createDpmMarket(
            venueId, "", outcomes, address(collateral), 0, 7200, openTime, closeTime, new bytes32[](0)
        );
        vm.stopPrank();
    }

    function _fund(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(diamond), amount);
    }

    function _enterIntent(address user, uint256 marketId, uint256 outcome, uint256 amount) internal {
        _fund(user, amount);
        vm.prank(user);
        _trade().enterIntent(marketId, outcome, amount);
    }

    function _enter(address user, uint256 marketId, uint256 outcome, uint256 amount) internal returns (uint256 shares) {
        _fund(user, amount);
        vm.prank(user);
        shares = _trade().enter(marketId, outcome, amount, 0); // minSharesOut 0 (slippage opt-out in tests)
    }

    /// @dev Drive the shared UMA resolution path: assert -> settle -> report. `outcome` of "Yes"/"No"
    ///      picks the winner; anything else (e.g. "Invalid") yields the [1,1] split payout.
    function _resolve(uint256 marketId, string memory outcome) internal {
        bytes32 qid = MarketsFacet(address(diamond)).getMarketRegistryData(marketId).questionId;
        collateral.mint(ASSERTER, 10 * USDC);
        vm.startPrank(ASSERTER);
        collateral.approve(address(diamond), 10 * USDC);
        bytes32 assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(qid, outcome);
        vm.stopPrank();
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
        ResolutionFacet(address(diamond)).reportResolution(marketId, outcome);
    }

    function _pool(uint256 marketId) internal view returns (uint256) {
        return _market().getMarketCollateral(marketId, YES) + _market().getMarketCollateral(marketId, NO);
    }

    // =========================================================================
    // Intent phase
    // =========================================================================

    function test_intent_enterAndExit_isOneToOne() public {
        uint256 marketId = _createMarket(block.timestamp + 1000, block.timestamp + 2000);

        _enterIntent(ALICE, marketId, YES, 10 * USDC);
        assertEq(_market().getIntentStake(marketId, ALICE, YES), 10 * USDC, "intent recorded");
        assertEq(collateral.balanceOf(ALICE), 0, "collateral pulled");

        vm.prank(ALICE);
        _trade().exitIntent(marketId, YES, 4 * USDC);
        assertEq(_market().getIntentStake(marketId, ALICE, YES), 6 * USDC, "partial exit");
        assertEq(collateral.balanceOf(ALICE), 4 * USDC, "1:1 refund");

        vm.prank(ALICE);
        _trade().exitIntent(marketId, YES, 6 * USDC);
        assertEq(_market().getIntentStake(marketId, ALICE, YES), 0, "full exit");
        assertEq(collateral.balanceOf(ALICE), 10 * USDC, "fully refunded 1:1");
    }

    function test_intent_exitMoreThanStaked_reverts() public {
        uint256 marketId = _createMarket(block.timestamp + 1000, block.timestamp + 2000);
        _enterIntent(ALICE, marketId, YES, 10 * USDC);
        vm.prank(ALICE);
        vm.expectRevert(LibDpmValidator.InsufficientIntentStake.selector);
        _trade().exitIntent(marketId, YES, 11 * USDC);
    }

    function test_intent_enterAfterOpenTime_reverts() public {
        uint256 openTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(openTime, openTime + 1000);
        vm.warp(openTime);
        _fund(ALICE, 1 * USDC);
        vm.prank(ALICE);
        vm.expectRevert(LibDpmValidator.NotIntentPhase.selector);
        _trade().enterIntent(marketId, YES, 1 * USDC);
    }

    // =========================================================================
    // Intent -> DPM transition (lazy, par, fee-free)
    // =========================================================================

    function test_transition_seedsMarketAndFoldsUserAtPar() public {
        uint256 openTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(openTime, openTime + 1000);

        // Two intent backers on opposite sides before openTime.
        _enterIntent(ALICE, marketId, YES, 30 * USDC);
        _enterIntent(BOB, marketId, NO, 10 * USDC);

        vm.warp(openTime);

        // Alice's first open-phase action seeds the market (M_i = N_i = intentTotals_i) and folds her
        // own intent at par, then applies her fresh $10 YES buy dynamically (both sides now live).
        uint256 freshShares = _enter(ALICE, marketId, YES, 10 * USDC);

        DpmMarket memory m = _market().getDpmMarket(marketId);
        assertTrue(m.poolInitialized, "pool seeded");

        // Market totals: M_yes = 30 (seed) + 10 (net buy); N_yes = 30 (par) + dynamic shares.
        assertEq(_market().getMarketCollateral(marketId, YES), 40 * USDC, "M_yes seed + buy");
        assertEq(_market().getMarketCollateral(marketId, NO), 10 * USDC, "M_no seed");
        assertApproxEqAbs(freshShares, 2_876_820, 50, "fresh buy priced dynamically");

        // Alice transitioned at par: her 30 intent -> 30 shares + 30 paid, plus the fresh buy.
        assertEq(_market().getIntentStake(marketId, ALICE, YES), 0, "Alice intent folded");
        assertEq(_market().getUserPaid(marketId, ALICE, YES), 40 * USDC, "paid = 30 intent + 10 buy");
        assertApproxEqAbs(_market().getUserShares(marketId, ALICE, YES), 30 * USDC + 2_876_820, 50, "30 par + fresh");

        // Bob has not acted post-open: still un-transitioned (intent intact, no live shares).
        assertEq(_market().getIntentStake(marketId, BOB, NO), 10 * USDC, "Bob intent pending");
        assertEq(_market().getUserShares(marketId, BOB, NO), 0, "Bob not transitioned");

        // Bob's first action transitions him at par (gross), fee-free, then applies his buy.
        _enter(BOB, marketId, NO, 5 * USDC);
        assertEq(_market().getIntentStake(marketId, BOB, NO), 0, "Bob transitioned");
        assertGe(_market().getUserShares(marketId, BOB, NO), 10 * USDC, "10 par + buy shares");
        assertEq(_market().getUserPaid(marketId, BOB, NO), 15 * USDC, "paid = 10 intent + 5 buy");
    }

    // =========================================================================
    // Open phase — par-until-contested then dynamic
    // =========================================================================

    function test_open_parUntilContested() public {
        uint256 marketId = _createMarket(0, block.timestamp + 1000); // immediate open, no intent

        // First YES buy: NO side empty => par, 1 share per $1.
        uint256 sYes = _enter(ALICE, marketId, YES, 10 * USDC);
        assertEq(sYes, 10 * USDC, "par first YES");

        // First NO buy: M_no == 0 => still par even though N_yes > 0.
        uint256 sNo = _enter(CAROL, marketId, NO, 10 * USDC);
        assertEq(sNo, 10 * USDC, "par first NO");

        // Now both sides live => dynamic: a YES buy gets fewer shares than at par.
        uint256 sDyn = _enter(BOB, marketId, YES, 10 * USDC);
        assertLt(sDyn, 10 * USDC, "dynamic pricing engaged");
    }

    // =========================================================================
    // Worked example (docs/dpm-pricing-math.md) — fee-free, exact pool
    // =========================================================================

    function test_workedExample_resolvesToFiftyDollars() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);

        uint256 aliceShares = _enter(ALICE, marketId, YES, 10 * USDC); // par
        uint256 bobShares = _enter(BOB, marketId, YES, 20 * USDC); // par
        _enter(CAROL, marketId, NO, 10 * USDC); // par
        uint256 daveShares = _enter(DAVE, marketId, YES, 10 * USDC); // dynamic

        assertEq(aliceShares, 10 * USDC);
        assertEq(bobShares, 20 * USDC);
        assertApproxEqAbs(daveShares, 2_876_820, 50, "Dave ~2.8768 shares");

        assertEq(_market().getMarketCollateral(marketId, YES), 40 * USDC, "M_yes");
        assertEq(_market().getMarketCollateral(marketId, NO), 10 * USDC, "M_no");
        assertEq(_pool(marketId), 50 * USDC, "pool == $50");

        vm.warp(closeTime);
        _resolve(marketId, "Yes");

        uint256 a = _claim(ALICE, marketId);
        uint256 b = _claim(BOB, marketId);
        uint256 d = _claim(DAVE, marketId);
        uint256 c = _claim(CAROL, marketId); // NO loser -> 0

        assertApproxEqAbs(a, 13_04 * (USDC / 100), USDC / 100, "Alice ~ $13.04");
        assertApproxEqAbs(b, 26_08 * (USDC / 100), USDC / 100, "Bob ~ $26.08");
        assertApproxEqAbs(d, 10_88 * (USDC / 100), USDC / 100, "Dave ~ $10.88");
        assertEq(c, 0, "Carol lost");

        uint256 total = a + b + d + c;
        assertLe(total, 50 * USDC, "payouts <= pool");
        assertLe(50 * USDC - total, 3, "floor dust < 1 micro-USDC per winner");
    }

    /// @dev Resolve a strike DPM price market via Pyth with a single close-window VAA.
    function _resolvePyth(uint256 marketId, int64 closePrice, uint256 closeTime) internal {
        // Note: hoist the uint64 casts into locals — nesting `uint64(closeTime - 1)` directly in the
        // call args trips a via_ir codegen quirk (spurious arithmetic panic) on this toolchain.
        uint64 pub = uint64(closeTime);
        uint64 prev = pub - 1;
        bytes memory vaa = mockPyth.createPriceFeedUpdateDataUnique(
            ETH_USD_FEED, closePrice, 0, PRICE_EXPO, closePrice, 0, prev, pub
        );
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = vaa;
        uint256 fee = mockPyth.getUpdateFee(pythData);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: fee}(marketId, pythData);
    }

    function _claim(address user, uint256 marketId) internal returns (uint256 payout) {
        uint256 before = collateral.balanceOf(user);
        vm.prank(user);
        payout = _trade().claim(marketId);
        assertEq(collateral.balanceOf(user) - before, payout, "payout transferred");
    }

    // =========================================================================
    // Resolution edge cases
    // =========================================================================

    function test_noContest_winningSideEmpty_refundsAll() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);

        // Everyone backs NO; nobody backs YES.
        _enter(ALICE, marketId, NO, 10 * USDC);
        _enter(BOB, marketId, NO, 5 * USDC);

        vm.warp(closeTime);
        _resolve(marketId, "Yes"); // YES wins but N_yes == 0 -> no-contest

        // Refund == each backer's net paid (fee-free here, so == deposit).
        assertEq(_claim(ALICE, marketId), 10 * USDC, "Alice refunded");
        assertEq(_claim(BOB, marketId), 5 * USDC, "Bob refunded");
    }

    function test_invalidResolution_splitPayout_refundsAll() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);

        _enter(ALICE, marketId, YES, 10 * USDC);
        _enter(BOB, marketId, NO, 6 * USDC);

        vm.warp(closeTime);
        _resolve(marketId, "Invalid"); // unrecognized -> [1,1]

        assertEq(_claim(ALICE, marketId), 10 * USDC, "Alice refunded on invalid");
        assertEq(_claim(BOB, marketId), 6 * USDC, "Bob refunded on invalid");
    }

    function test_invalid_refundsUntransitionedIntentGross() public {
        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createMarket(openTime, closeTime);

        _enterIntent(ALICE, marketId, YES, 10 * USDC); // never transitions
        vm.warp(closeTime);
        _resolve(marketId, "Invalid");

        // Un-transitioned intent is refunded gross (no fee was ever charged on intent).
        assertEq(_claim(ALICE, marketId), 10 * USDC, "gross intent refunded");
    }

    function test_claim_doubleClaim_reverts() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);
        _enter(ALICE, marketId, YES, 10 * USDC);
        _enter(BOB, marketId, NO, 10 * USDC);
        vm.warp(closeTime);
        _resolve(marketId, "Yes");

        _claim(ALICE, marketId);
        vm.prank(ALICE);
        vm.expectRevert(LibDpmValidator.AlreadyClaimed.selector);
        _trade().claim(marketId);
    }

    function test_claim_beforeResolved_reverts() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);
        _enter(ALICE, marketId, YES, 10 * USDC);
        vm.warp(closeTime); // closed but not resolved
        vm.prank(ALICE);
        vm.expectRevert(LibDpmValidator.NotResolved.selector);
        _trade().claim(marketId);
    }

    // =========================================================================
    // Price (Pyth) DPM markets — same pool, Pyth resolution
    // =========================================================================

    function test_priceMarket_pythResolution_winnerPaid() public {
        uint256 closeTime = block.timestamp + 1000;

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Above";
        outcomes[1] = "Below";

        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        // Immediate open (no intent), explicit strike $2500, Pyth-resolved.
        uint256 marketId = _market().createDpmPriceMarket(
            venueId, ETH_USD_FEED, STRIKE_PRICE, 0, closeTime, outcomes, address(collateral), "q:t:ETH,description:x", 0, new bytes32[](0), 0
        );
        vm.stopPrank();

        assertTrue(_market().isDpmMarket(marketId), "price market is a DPM market");

        // Par entries on both sides of the pool.
        _enter(ALICE, marketId, 0, 10 * USDC); // Above
        _enter(BOB, marketId, 1, 10 * USDC); // Below

        vm.warp(closeTime);
        // Close price $3000 >= strike $2500 => Above (outcome 0) wins. Resolved via the shared
        // LibResolutionService path, writing the CTF numerators claim() reads — no UMA assertion.
        _resolvePyth(marketId, 3000e8, closeTime);

        // DPM claim works identically to the UMA path: Above winner gets par refund + losers' pool.
        assertEq(_claim(ALICE, marketId), 20 * USDC, "Above winner paid from Pyth-resolved pool");
        assertEq(_claim(BOB, marketId), 0, "Below loser");
    }

    /// @notice A DPM price market MUST emit PriceMarketCreatedPyth (now owned by LibPriceMarketService,
    ///         like MarketCreated is owned by LibMarketCreationService). Without it the subgraph never
    ///         creates the PriceMarket overlay / flags isPriceMarket, so resolution can't be indexed.
    function test_priceMarket_emitsPriceMarketCreatedPythForIndexer() public {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Above";
        outcomes[1] = "Below";
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);

        vm.recordLogs();
        _market().createDpmPriceMarket(
            venueId, ETH_USD_FEED, STRIKE_PRICE, 0, block.timestamp + 1000, outcomes, address(collateral), "q:t,description:x", 0, new bytes32[](0), 0
        );
        vm.stopPrank();

        bytes32 topic =
            keccak256("PriceMarketCreatedPyth(uint256,uint256,bytes32,int64,int32,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                found = true;
                // feedId is the 3rd indexed topic — sanity-check it carries the overlay data.
                assertEq(logs[i].topics[3], ETH_USD_FEED, "event carries the feed id");
            }
        }
        assertTrue(found, "createDpmPriceMarket must emit PriceMarketCreatedPyth");
    }

    // =========================================================================
    // Fee path + solvency (fees enabled)
    // =========================================================================

    function test_enter_chargesFee_andStaysSolvent() public {
        // Enable protocol fees so getMarketFees returns non-zero for new markets.
        ProtocolFacet(address(diamond)).setProtocolTreasury(address(0xFEE5));
        ProtocolFacet(address(diamond)).setProtocolFeeBps(20);

        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(0, closeTime);

        uint256 diamondBefore = collateral.balanceOf(address(diamond));
        _enter(ALICE, marketId, YES, 100 * USDC);

        // Net into the pool = amount - fee; fee left custody to recipients.
        uint256 pool = _pool(marketId);
        assertLt(pool, 100 * USDC, "fee deducted from pool");
        // Solvency: the pool equals the collateral the diamond actually gained from this entry.
        assertEq(collateral.balanceOf(address(diamond)) - diamondBefore, pool, "Sigma M_i == custody delta");
    }

    /// @dev Enable fees: protocol 20bps + venue 100bps + operator 10bps = 130bps total.
    address internal constant PROTOCOL_TREASURY = address(0xFEE5);

    function _enableFees() internal {
        ProtocolFacet(address(diamond)).setProtocolTreasury(PROTOCOL_TREASURY);
        ProtocolFacet(address(diamond)).setProtocolFeeBps(20);
    }

    function test_intentFee_chargedAtSeed_winnerPaysAndOperatorGoesToProtocol() public {
        _enableFees(); // 130 bps total

        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createMarket(openTime, closeTime);

        // Pure intent on both sides; nobody trades during open.
        _enterIntent(ALICE, marketId, YES, 100 * USDC);
        _enterIntent(BOB, marketId, NO, 100 * USDC);

        vm.warp(closeTime);
        _resolve(marketId, "Yes");

        // First claim triggers the seed, which charges the intent fee on the whole pool.
        // feeBps = 130; fee per side = 100e6 * 130 / 10000 = 1.3e6; pool nets to 98.7e6 per side.
        uint256 protoBefore = collateral.balanceOf(PROTOCOL_TREASURY); // ignore the creation-fee cut
        uint256 a = _claim(ALICE, marketId); // YES winner (triggers seed + intent fee)
        uint256 b = _claim(BOB, marketId); // NO loser

        // Winner: net basis 98.7 + full losers' pool 98.7 = 197.4 USDC. Fee WAS charged (basis < 100).
        assertEq(a, 197_400_000, "winner paid on net basis + net losers' pool");
        assertEq(b, 0, "loser gets nothing");

        // Conservation: deposits (200) == winner payout (197.4) + fees (2.6). No draining.
        assertEq(a + 2_600_000, 200 * USDC, "deposits == payouts + fees");

        // Operator slice (10bps) folded into protocol: protocol gets (20+10)/130 of 2.6e6 = 0.6e6.
        // (Without the fold it would be 0.4e6 to protocol + 0.2e6 to the claimer.)
        assertEq(collateral.balanceOf(PROTOCOL_TREASURY) - protoBefore, 600_000, "operator fee routed to protocol");

        // Pool fully paid out (only sub-unit dust may remain locked).
        assertLe(_pool(marketId), 200 * USDC, "no over-draw");
    }

    function test_intentFee_noFreeRideVsDynamic_andStaysSolvent() public {
        _enableFees();

        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createMarket(openTime, closeTime);

        // Intent backers + a dynamic entrant after open: all paths pay the fee.
        _enterIntent(ALICE, marketId, YES, 50 * USDC);
        _enterIntent(BOB, marketId, YES, 50 * USDC);
        _enterIntent(CAROL, marketId, NO, 80 * USDC);
        uint256 totalDeposited = 180 * USDC;

        // Snapshot the protocol treasury after creation (ignores the creation-fee cut) so the delta
        // captures the intent seed fee + Dave's dynamic fee, both taken before any claim.
        uint256 protoBefore = collateral.balanceOf(PROTOCOL_TREASURY);

        vm.warp(openTime);
        // Dave enters dynamically (pays fee on his amount); also triggers the market seed (intent fee).
        _enter(DAVE, marketId, YES, 20 * USDC);
        totalDeposited += 20 * USDC;

        vm.warp(closeTime);
        _resolve(marketId, "Yes");

        uint256 paidOut = _claim(ALICE, marketId) + _claim(BOB, marketId) + _claim(DAVE, marketId)
            + _claim(CAROL, marketId);
        uint256 feesCollected = collateral.balanceOf(PROTOCOL_TREASURY) - protoBefore;
        // Venue fee recipient is address(this); we assert on the protocol slice only.

        // Self-funding: nothing minted, nothing drained. Everything paid out + every fee taken must
        // not exceed what was deposited, and the residual is only rounding dust left in custody.
        assertLe(paidOut, totalDeposited, "payouts never exceed deposits");
        assertGt(feesCollected, 0, "fees were actually collected at transition");
        assertLe(_pool(marketId), totalDeposited, "pool never over-drawn");
    }

    function testFuzz_intentPlusFees_neverDrainsPool(uint64 y1, uint64 y2, uint64 n1, uint64 n2) public {
        _enableFees();

        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createMarket(openTime, closeTime);

        // Random intent on both sides (bounded to keep amounts sane), two backers per side.
        uint256 sy1 = bound(uint256(y1), 1 * USDC, 1e12);
        uint256 sy2 = bound(uint256(y2), 1 * USDC, 1e12);
        uint256 sn1 = bound(uint256(n1), 1 * USDC, 1e12);
        uint256 sn2 = bound(uint256(n2), 1 * USDC, 1e12);
        uint256 deposited = sy1 + sy2 + sn1 + sn2;

        _enterIntent(ALICE, marketId, YES, sy1);
        _enterIntent(BOB, marketId, YES, sy2);
        _enterIntent(CAROL, marketId, NO, sn1);
        _enterIntent(DAVE, marketId, NO, sn2);

        vm.warp(closeTime);
        _resolve(marketId, "Yes");

        // Every winner pays the fee (charged at seed); losers get nothing. The pool can never pay
        // out more than was deposited — this is the load-bearing "no draining" guarantee.
        uint256 paidOut = _claim(ALICE, marketId) + _claim(BOB, marketId) + _claim(CAROL, marketId)
            + _claim(DAVE, marketId);
        assertLe(paidOut, deposited, "payouts never exceed deposits");
        // And the fee was actually taken: winners receive strictly less than the full gross pool.
        assertLt(paidOut, deposited, "intent fee was charged (winners share < gross pool)");
    }

    // =========================================================================
    // N-outcome (categorical) DPM markets
    // =========================================================================

    function _createCategorical(string[] memory outcomes, uint256 openTime, uint256 closeTime)
        internal
        returns (uint256 marketId)
    {
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        marketId = _market().createDpmMarket(
            venueId, "", outcomes, address(collateral), 0, 7200, openTime, closeTime, new bytes32[](0)
        );
        vm.stopPrank();
    }

    function test_nOutcome_election_resolveAndClaim() public {
        uint256 closeTime = block.timestamp + 1000;
        string[] memory outcomes = new string[](3);
        outcomes[0] = "Alice";
        outcomes[1] = "Bob";
        outcomes[2] = "Carol";
        uint256 marketId = _createCategorical(outcomes, 0, closeTime); // immediate open, no intent

        assertEq(_market().getDpmMarket(marketId).outcomeCount, 3, "3-way market");

        // One backer per candidate, all par (each is first on its outcome).
        _enter(ALICE, marketId, 0, 10 * USDC);
        _enter(BOB, marketId, 1, 10 * USDC);
        _enter(CAROL, marketId, 2, 10 * USDC);
        assertEq(_pool(marketId) + _market().getMarketCollateral(marketId, 2), 30 * USDC, "pool == $30");

        vm.warp(closeTime);
        _resolve(marketId, "Bob"); // UMA: assert "Bob" -> settle true -> report (3-vector [0,1,0])

        // Bob wins the whole losers' pool (sole outcome-1 backer): 10 paid + (20/10)*10 = $30 = pool.
        assertEq(_claim(BOB, marketId), 30 * USDC, "Bob wins the full pool");
        assertEq(_claim(ALICE, marketId), 0, "Alice (lost) gets 0");
        assertEq(_claim(CAROL, marketId), 0, "Carol (lost) gets 0");
    }

    function test_nOutcome_proRataAmongWinners() public {
        uint256 closeTime = block.timestamp + 1000;
        string[] memory outcomes = new string[](3);
        outcomes[0] = "Alice";
        outcomes[1] = "Bob";
        outcomes[2] = "Carol";
        uint256 marketId = _createCategorical(outcomes, 0, closeTime);

        // Two backers on Bob (the winner), one on each loser. All par.
        _enter(ALICE, marketId, 1, 30 * USDC); // Bob backer
        _enter(BOB, marketId, 1, 10 * USDC); // Bob backer
        _enter(CAROL, marketId, 0, 20 * USDC); // Alice backer (loses)
        _enter(DAVE, marketId, 2, 20 * USDC); // Carol backer (loses)
        // pool = 80; M_bob = 40; losers' pool M_other = 40; N_bob = 40 (par).

        vm.warp(closeTime);
        _resolve(marketId, "Bob");

        // Each Bob share redeems paid + (M_other / N_bob) = paid + (40/40)*shares = 2x stake.
        assertEq(_claim(ALICE, marketId), 60 * USDC, "Alice (Bob, 30) -> 60");
        assertEq(_claim(BOB, marketId), 20 * USDC, "Bob (Bob, 10) -> 20");
        assertEq(_claim(CAROL, marketId), 0, "Carol backer lost");
        assertEq(_claim(DAVE, marketId), 0, "Dave backer lost");
    }

    function test_nOutcome_outcomeCountBounds_revert() public {
        string[] memory one = new string[](1);
        one[0] = "Solo";
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        vm.expectRevert(LibDpmValidator.InvalidOutcomeCount.selector);
        _market().createDpmMarket(
            venueId, "", one, address(collateral), 0, 7200, 0, block.timestamp + 1000, new bytes32[](0)
        );
        vm.stopPrank();
    }

    /// @notice Regression guard: relaxing createMarket for DPM must NOT let a regular binary CLOB
    ///         market be created with > 2 outcomes (it would be a broken, vault-less market).
    function test_binaryProtection_clobCreateRejectsThreeOutcomes() public {
        string[] memory three = new string[](3);
        three[0] = "A";
        three[1] = "B";
        three[2] = "C";
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        vm.expectRevert(); // InvalidOutcomesLength — CLOB markets are binary (allowMultiOutcome = false)
        MarketsFacet(address(diamond)).createMarket(
            venueId, "", three, 1e16, address(collateral), 0, 7200, new bytes32[](0)
        );
        vm.stopPrank();
    }

    function test_priceMarket_rejectsNonBinary() public {
        string[] memory three = new string[](3);
        three[0] = "Up";
        three[1] = "Flat";
        three[2] = "Down";
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        vm.expectRevert(); // price markets are binary; createMarket.InvalidOutcomesLength
        _market().createDpmPriceMarket(
            venueId, ETH_USD_FEED, STRIKE_PRICE, 0, block.timestamp + 1000, three, address(collateral), "q:t", 0, new bytes32[](0), 0
        );
        vm.stopPrank();
    }

    function test_nOutcome_addLateOutcome_thenResolveToIt() public {
        uint256 closeTime = block.timestamp + 1000;
        string[] memory outcomes = new string[](3);
        outcomes[0] = "Alice";
        outcomes[1] = "Bob";
        outcomes[2] = "Carol";
        uint256 marketId = _createCategorical(outcomes, 0, closeTime);

        _enter(ALICE, marketId, 0, 10 * USDC); // Alice
        _enter(BOB, marketId, 1, 10 * USDC); // Bob

        // Dave joins the race mid-market. The test contract is the venue operator (createDefaultVenue).
        uint256 daveIdx = _market().addDpmOutcome(marketId, "Dave");
        assertEq(daveIdx, 3, "Dave is the 4th outcome (index 3)");
        assertEq(_market().getDpmMarket(marketId).outcomeCount, 4, "market is now 4-way");

        // The new outcome starts empty -> par-until-contested for its first backer.
        uint256 daveShares = _enter(CAROL, marketId, 3, 20 * USDC);
        assertEq(daveShares, 20 * USDC, "par on the freshly-added outcome");

        vm.warp(closeTime);
        _resolve(marketId, "Dave"); // assert the late candidate by name; computePayouts maps it to slot 3

        // pool = 40; M_dave = 20; M_other = 20; N_dave = 20 -> Carol redeems 20 + (20/20)*20 = $40.
        assertEq(_claim(CAROL, marketId), 40 * USDC, "late winner paid the full pool");
        assertEq(_claim(ALICE, marketId), 0, "loser 0");
        assertEq(_claim(BOB, marketId), 0, "loser 0");
    }

    function test_addLateOutcome_guards() public {
        uint256 closeTime = block.timestamp + 1000;
        string[] memory outcomes = new string[](3);
        outcomes[0] = "Alice";
        outcomes[1] = "Bob";
        outcomes[2] = "Carol";
        uint256 marketId = _createCategorical(outcomes, 0, closeTime);

        // Non-operator cannot add.
        vm.prank(ALICE);
        vm.expectRevert();
        _market().addDpmOutcome(marketId, "Dave");

        // Duplicate label rejected.
        vm.expectRevert(LibDpmValidator.DuplicateOutcome.selector);
        _market().addDpmOutcome(marketId, "Bob");

        // Empty label rejected.
        vm.expectRevert(LibDpmValidator.EmptyOutcomeLabel.selector);
        _market().addDpmOutcome(marketId, "");

        // Cannot add once trading has closed.
        vm.warp(closeTime);
        vm.expectRevert(LibDpmValidator.TradingClosed.selector);
        _market().addDpmOutcome(marketId, "Dave");
    }

    function _threeOutcomes() internal pure returns (string[] memory o) {
        o = new string[](3);
        o[0] = "Alice";
        o[1] = "Bob";
        o[2] = "Carol";
    }

    function test_nOutcome_noContest_winnerUnbacked_refundsAll() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createCategorical(_threeOutcomes(), 0, closeTime);
        _enter(ALICE, marketId, 0, 10 * USDC);
        _enter(BOB, marketId, 1, 10 * USDC);
        // Nobody backs Carol (outcome 2).
        vm.warp(closeTime);
        _resolve(marketId, "Carol"); // Carol wins but N_carol == 0 -> no-contest -> refund all
        assertEq(_claim(ALICE, marketId), 10 * USDC, "Alice refunded");
        assertEq(_claim(BOB, marketId), 10 * USDC, "Bob refunded");
    }

    function test_nOutcome_invalid_refundsAll() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createCategorical(_threeOutcomes(), 0, closeTime);
        _enter(ALICE, marketId, 0, 10 * USDC);
        _enter(BOB, marketId, 1, 7 * USDC);
        _enter(CAROL, marketId, 2, 5 * USDC);
        vm.warp(closeTime);
        _resolve(marketId, "Invalid"); // unrecognized -> all-1s -> refund all
        assertEq(_claim(ALICE, marketId), 10 * USDC, "Alice refunded");
        assertEq(_claim(BOB, marketId), 7 * USDC, "Bob refunded");
        assertEq(_claim(CAROL, marketId), 5 * USDC, "Carol refunded");
    }

    function test_enter_zeroShares_reverts() public {
        // Deep, imbalanced book: a $1 buy on a side holding $1,000,000 floors to 0 shares.
        uint256 marketId = _createMarket(0, block.timestamp + 1000);
        _enter(ALICE, marketId, YES, 1_000_000 * USDC); // huge YES (par)
        _enter(BOB, marketId, NO, 1 * USDC); // tiny NO -> both sides live (dynamic)

        _fund(CAROL, 1 * USDC);
        vm.prank(CAROL);
        vm.expectRevert(LibDpmValidator.ZeroShares.selector); // would silently mint 0 pre-fix
        _trade().enter(marketId, YES, 1 * USDC, 0);
    }

    function test_enter_slippageGuard() public {
        uint256 marketId = _createMarket(0, block.timestamp + 1000);
        _fund(ALICE, 10 * USDC);
        vm.prank(ALICE);
        // Par mints exactly 10e6 shares; demanding 10e6+1 must revert.
        vm.expectRevert(LibDpmValidator.SlippageExceeded.selector);
        _trade().enter(marketId, YES, 10 * USDC, 10 * USDC + 1);
    }

    function test_addLateOutcome_blockedOnPriceMarket() public {
        uint256 closeTime = block.timestamp + 1000;
        string[] memory o = new string[](2);
        o[0] = "Up";
        o[1] = "Down";
        collateral.mint(CREATOR, 5 * USDC);
        vm.startPrank(CREATOR);
        collateral.approve(address(diamond), 5 * USDC);
        uint256 marketId = _market().createDpmPriceMarket(
            venueId, ETH_USD_FEED, STRIKE_PRICE, 0, closeTime, o, address(collateral), "q:t", 0, new bytes32[](0), 0
        );
        vm.stopPrank();
        vm.expectRevert(LibDpmValidator.PriceMarketOutcomesAreFixed.selector);
        _market().addDpmOutcome(marketId, "Flat");
    }

    function test_addLateOutcome_blockedWhileAsserting() public {
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createCategorical(_threeOutcomes(), 0, closeTime);
        _enter(ALICE, marketId, 0, 10 * USDC);

        // Open an assertion against the current outcome set (locks the question).
        bytes32 qid = MarketsFacet(address(diamond)).getMarketRegistryData(marketId).questionId;
        collateral.mint(ASSERTER, 10 * USDC);
        vm.startPrank(ASSERTER);
        collateral.approve(address(diamond), 10 * USDC);
        ResolutionFacet(address(diamond)).assertMarketOutcome(qid, "Alice");
        vm.stopPrank();

        vm.expectRevert(LibDpmValidator.AssertionInFlight.selector);
        _market().addDpmOutcome(marketId, "Dave");
    }

    function test_lateOutcome_addedDuringIntent_seedsAndResolves() public {
        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createCategorical(_threeOutcomes(), openTime, closeTime);

        // Add Dave during the intent phase, then intent-stake on him.
        _market().addDpmOutcome(marketId, "Dave");
        _enterIntent(ALICE, marketId, 0, 10 * USDC); // Alice intent
        _enterIntent(BOB, marketId, 3, 20 * USDC); // Dave intent (the late outcome)

        vm.warp(openTime);
        _enter(CAROL, marketId, 0, 5 * USDC); // first post-open action -> triggers the 4-outcome seed
        // Dave's intent (20) seeded into N[3] (gross, par).
        assertEq(_market().getMarketShares(marketId, 3), 20 * USDC, "Dave intent seeded into the pool");

        vm.warp(closeTime);
        _resolve(marketId, "Dave");
        // Bob (Dave intent 20) is the dominant Dave backer; he wins a share of the losers' pool.
        assertGt(_claim(BOB, marketId), 20 * USDC, "Dave intent backer paid > stake");
        assertEq(_claim(ALICE, marketId), 0, "Alice lost");
    }

    function testFuzz_nOutcome_neverDrainsWithFees(uint64 a, uint64 b, uint64 c, uint64 d) public {
        _enableFees();
        uint256 closeTime = block.timestamp + 1000;
        uint256 marketId = _createCategorical(_threeOutcomes(), 0, closeTime);

        uint256 sa = bound(uint256(a), 1 * USDC, 1e12);
        uint256 sb = bound(uint256(b), 1 * USDC, 1e12);
        uint256 sc = bound(uint256(c), 1 * USDC, 1e12);
        uint256 sd = bound(uint256(d), 1 * USDC, 1e12);
        uint256 deposited = sa + sb + sc + sd;

        _enter(ALICE, marketId, 0, sa);
        _enter(BOB, marketId, 1, sb);
        _enter(CAROL, marketId, 2, sc);
        _enter(DAVE, marketId, 0, sd); // second Alice backer

        vm.warp(closeTime);
        _resolve(marketId, "Alice");

        uint256 paidOut = _claim(ALICE, marketId) + _claim(BOB, marketId) + _claim(CAROL, marketId)
            + _claim(DAVE, marketId);
        assertLe(paidOut, deposited, "N-outcome payouts never exceed deposits");
    }

    // =========================================================================
    // Indexer events
    // =========================================================================

    function test_events_seedAndEnter_carryPoolStateForIndexer() public {
        uint256 openTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(openTime, openTime + 1000);
        _enterIntent(ALICE, marketId, YES, 30 * USDC);
        _enterIntent(BOB, marketId, NO, 10 * USDC);
        vm.warp(openTime);

        vm.recordLogs();
        _enter(CAROL, marketId, YES, 10 * USDC); // first post-open action -> triggers the lazy seed
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 seededTopic = keccak256("DpmPoolSeeded(uint256,uint256[],uint256[])");
        bytes32 enteredTopic = keccak256("DpmEntered(uint256,address,uint256,uint256,uint256,uint256,uint256)");
        bool seenSeed;
        bool seenEnter;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == seededTopic) seenSeed = true;
            if (logs[i].topics[0] == enteredTopic) {
                seenEnter = true;
                // Non-indexed data: outcome, amount, shares, newCollateral, newShares.
                (,,, uint256 newCollateral, uint256 newShares) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(newCollateral, _market().getMarketCollateral(marketId, YES), "DpmEntered carries live M_yes");
                assertEq(newShares, _market().getMarketShares(marketId, YES), "DpmEntered carries live N_yes");
            }
        }
        assertTrue(seenSeed, "the seeding action must emit DpmPoolSeeded");
        assertTrue(seenEnter, "enter must emit DpmEntered");
    }

    // =========================================================================
    // Solvency on void paths WITH fees + intent (regression for the seed-vs-gross-refund bug)
    // =========================================================================

    function test_intentFee_noContest_refundsNet_andStaysSolvent() public {
        _enableFees(); // 130 bps
        uint256 openTime = block.timestamp + 1000;
        uint256 marketId = _createMarket(openTime, openTime + 1000);
        _enterIntent(ALICE, marketId, NO, 100 * USDC);
        _enterIntent(BOB, marketId, NO, 100 * USDC);
        // Nobody backs YES.
        vm.warp(openTime + 1000);
        _resolve(marketId, "Yes"); // YES wins but N_yes == 0 -> no-contest. Alice's claim seeds the pool.

        // Seed charges floor(200·130bps) = 2.6 USDC; each backer is refunded the NET 98.7. The
        // pre-fix code refunded GROSS 100 each and Bob's claim reverted (custody 197.4 < 200).
        uint256 a = _claim(ALICE, marketId);
        uint256 b = _claim(BOB, marketId); // must NOT revert
        assertEq(a, 98_700_000, "Alice net refund");
        assertEq(b, 98_700_000, "Bob net refund");
        assertLe(a + b, 200 * USDC, "refunds never exceed deposits");
    }

    function test_intentFee_seededThenInvalid_refundsNet_andStaysSolvent() public {
        _enableFees();
        uint256 openTime = block.timestamp + 1000;
        uint256 closeTime = openTime + 1000;
        uint256 marketId = _createMarket(openTime, closeTime);
        _enterIntent(ALICE, marketId, YES, 100 * USDC); // pure intent, never transitions
        _enterIntent(BOB, marketId, NO, 100 * USDC); // pure intent, never transitions

        vm.warp(openTime);
        _enter(CAROL, marketId, YES, 50 * USDC); // open-phase enter SEEDS the pool (charges the intent fee)

        vm.warp(closeTime);
        _resolve(marketId, "Invalid"); // [1,1] -> refund all

        uint256 a = _claim(ALICE, marketId); // un-transitioned intent on a SEEDED market -> NET refund
        uint256 b = _claim(BOB, marketId);
        uint256 c = _claim(CAROL, marketId); // dynamic entrant -> net userPaid
        assertEq(a, 98_700_000, "Alice net intent refund");
        assertEq(b, 98_700_000, "Bob net intent refund");
        assertEq(c, 49_350_000, "Carol net dynamic refund");
        assertLe(a + b + c, 250 * USDC, "seeded-invalid refunds never exceed deposits");
    }

    // =========================================================================
    // Cross-mode guard: CLOB entry points reject a DPM market
    // =========================================================================

    function test_crossModeGuard_clobEntryPointsRejectDpm() public {
        uint256 marketId = _createMarket(0, block.timestamp + 1000);
        bytes4 err = LibDpmValidator.MarketIsDpm.selector;

        vm.expectRevert(err);
        MarketOrdersFacet(address(diamond)).placeMarketBuy(marketId, YES, 1 * USDC, 100, MarketOrderType.FAK);

        vm.expectRevert(err);
        MarketOrdersFacet(address(diamond)).placeMarketSell(marketId, YES, 1 * USDC, 100, MarketOrderType.FAK);

        vm.expectRevert(err);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, YES, Side.BUY, 50, 1 * USDC, 0);

        vm.expectRevert(err);
        LimitOrdersFacet(address(diamond)).expireOrders(marketId, new uint256[](0));

        vm.expectRevert(err);
        BatchOrdersFacet(address(diamond)).batchPlaceOrders(marketId, new BatchOrderParams[](0));

        vm.expectRevert(err);
        BatchOrdersFacet(address(diamond)).cancelAndReplace(marketId, new uint256[](0), new BatchOrderParams[](0));

        vm.expectRevert(err);
        MatchingFacet(address(diamond)).matchOrders(marketId, 1);
    }

    // =========================================================================
    // Cross-mode guard on the CTF token surface (Vault split/merge).
    // A binary DPM market has a prepared CTF condition + positionIds (createMarket
    // Step 8 runs for length == 2), but DPM holds no outcome tokens and trades from
    // its own pool — so split/merge must be rejected like the orderbook entry points.
    // =========================================================================

    function test_crossModeGuard_vaultSplitMergeRejectDpm() public {
        uint256 marketId = _createMarket(0, block.timestamp + 1000);
        _fund(DAVE, 50 * USDC);

        vm.prank(DAVE);
        vm.expectRevert(LibDpmValidator.MarketIsDpm.selector);
        VaultFacet(address(diamond)).splitPosition(marketId, 50 * USDC);

        vm.prank(DAVE);
        vm.expectRevert(LibDpmValidator.MarketIsDpm.selector);
        VaultFacet(address(diamond)).mergePositions(marketId, 50 * USDC);
    }
}
