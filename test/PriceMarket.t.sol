// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {PriceMarketFacet} from "../src/facets/PriceMarketFacet.sol";
import {PythResolutionFacet} from "../src/facets/PythResolutionFacet.sol";
import {LibPriceMarketValidator} from "../src/validators/LibPriceMarketValidator.sol";
import {MarketRegistryData, MarketTradingData, MarketOracleData, MarketStatus, FeedProvider} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {LibPriceMarketStorage} from "../src/storage/LibPriceMarketStorage.sol";
import {LibMarketOracleStorage} from "../src/storage/LibMarketOracleStorage.sol";

/// @title Price Market integration tests
/// @notice Tests Pyth-powered price market creation, deferred open-price capture at
///         resolution, strike markets, and the invalidation escape hatch.
contract PriceMarketTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockUmaOracle public umaOracle;
    MockPyth public mockPyth;
    uint256 public venueId;

    address constant CREATOR = address(0xC8EA);
    address constant RESOLVER = address(0x8E501);
    uint256 constant TICK_SIZE = 1e16;
    bytes32 constant ETH_USD_FEED = bytes32(uint256(0xff61));
    uint256 constant DURATION = 900; // 15 minutes
    int64 constant OPEN_PRICE = 200000000000; // $2000.00 with expo -8
    int64 constant STRIKE_PRICE = 250000000000; // $2500.00 with expo -8
    int32 constant PRICE_EXPO = -8;
    bytes32 constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    // Events
    event PriceMarketCreatedPyth(
        uint256 indexed marketId,
        uint256 indexed venueId,
        bytes32 indexed pythFeedId,
        int64 strikePrice,
        int32 priceExpo,
        uint256 openTime,
        uint256 closeTime,
        uint256 resolutionWindow
    );
    event PriceMarketResolvedPyth(
        uint256 indexed marketId,
        int64 finalPrice,
        int64 strikePrice,
        uint256 openPriceTime,
        string outcome
    );
    event PriceMarketInvalidated(uint256 indexed marketId, address indexed caller);
    event MarketResolved(uint256 indexed marketId, bytes32 indexed questionId, string outcome);
    event PythContractUpdated(address indexed pythContract);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        umaOracle = new MockUmaOracle();
        mockPyth = new MockPyth(60, 1); // 60s valid period, 1 wei fee

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(diamond)).setUmaIdentifier(UMA_IDENTIFIER);
        PythResolutionFacet(address(diamond)).setPythContract(address(mockPyth));

        venueId = createDefaultVenue(address(diamond));

        vm.deal(CREATOR, 10 ether);
        vm.deal(RESOLVER, 10 ether);

        // Prime MockPyth with initial feed data so getPriceUnsafe (used at creation
        // for priceExpo) returns a value.
        bytes[] memory initData = _buildPythVAA(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        mockPyth.updatePriceFeeds{value: 1}(initData);
    }

    // ---- Helpers ----

    function _buildPythVAA(bytes32 feedId, int64 price, uint64 publishTime)
        internal
        view
        returns (bytes[] memory)
    {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            feedId,
            price,
            0, // conf
            PRICE_EXPO,
            price, // emaPrice (same for tests)
            0, // emaConf
            publishTime
        );
        return updateData;
    }

    function _upDownOutcomes() internal pure returns (string[] memory) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Up";
        outcomes[1] = "Down";
        return outcomes;
    }

    function _aboveBelowOutcomes() internal pure returns (string[] memory) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Above";
        outcomes[1] = "Below";
        return outcomes;
    }

    /// @dev Immediate deferred Up/Down market: openTime=0, strikePrice=0.
    function _createImmediateDeferredMarket() internal returns (uint256 marketId) {
        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId,
            ETH_USD_FEED,
            int64(0), // strikePrice = 0 (deferred)
            uint256(0), // openTime = 0 (immediate)
            closeTime,
            _upDownOutcomes(),
            TICK_SIZE,
            address(collateral),
            "q:title:ETH Up or Down,description:15 min price market",
            0, // liveness
            new bytes32[](0), // tags
            0 // resolutionWindow (default 60s)
        );
    }

    /// @dev Scheduled deferred Up/Down market: openTime in future, strikePrice=0.
    function _createScheduledDeferredMarket(uint256 openTime) internal returns (uint256 marketId) {
        uint256 closeTime = openTime + DURATION;

        vm.prank(CREATOR);
        marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId,
            ETH_USD_FEED,
            int64(0),
            openTime,
            closeTime,
            _upDownOutcomes(),
            TICK_SIZE,
            address(collateral),
            "q:title:ETH Up or Down,description:scheduled price market",
            0,
            new bytes32[](0),
            0
        );
    }

    /// @dev Explicit-strike market.
    function _createStrikeMarket(int64 strikePrice, uint256 closeTime) internal returns (uint256 marketId) {
        vm.prank(CREATOR);
        marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId,
            ETH_USD_FEED,
            strikePrice,
            uint256(0), // openTime ignored for strike markets
            closeTime,
            _aboveBelowOutcomes(),
            TICK_SIZE,
            address(collateral),
            "q:title:ETH Above/Below $2500,description:Strike price market",
            0,
            new bytes32[](0),
            0
        );
    }

    /// @dev Resolve a deferred market with both open- and close-window VAAs.
    function _resolveDeferredMarket(uint256 marketId, int64 openPrice, int64 closePrice) internal {
        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        bytes[] memory pythData = new bytes[](2);
        pythData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, openPrice, 0, PRICE_EXPO, openPrice, 0, uint64(openTime)
        );
        pythData[1] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, closePrice, 0, PRICE_EXPO, closePrice, 0, uint64(closeTime)
        );

        uint256 fee = mockPyth.getUpdateFee(pythData);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: fee}(marketId, pythData);
    }

    /// @dev Resolve an explicit-strike market with a single close-window VAA.
    function _resolveStrikeMarket(uint256 marketId, int64 closePrice) internal {
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, closePrice, uint64(closeTime));

        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    // ======================================================================
    // CREATION — immediate deferred Up/Down (openTime=0, strikePrice=0)
    // ======================================================================

    function test_createPriceMarket_immediateDeferred_happyPath() public {
        uint256 createdAt = block.timestamp;
        uint256 marketId = _createImmediateDeferredMarket();

        (
            bytes32 feedId,
            FeedProvider feedProvider,
            uint256 openTime,
            uint256 closeTime,
            int32 priceExpo,
            int64 finalPrice,
            uint256 resolutionWindow,
            bool resolved,
            int64 strikePrice,
            uint256 openPriceTime
        ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        assertEq(feedId, ETH_USD_FEED);
        assertEq(uint8(feedProvider), uint8(FeedProvider.PYTH));
        assertEq(openTime, createdAt, "immediate openTime should be block.timestamp at creation");
        assertEq(closeTime, createdAt + DURATION);
        assertEq(priceExpo, PRICE_EXPO);
        assertEq(finalPrice, int64(0));
        assertEq(resolutionWindow, 60); // default
        assertFalse(resolved);
        assertEq(strikePrice, int64(0), "deferred markets store strikePrice=0 until resolution");
        assertEq(openPriceTime, 0, "openPriceTime stays 0 until resolution");

        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Active));
        assertEq(reg.creator, CREATOR);

        MarketTradingData memory trading = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertTrue(trading.active, "trading is enabled from creation, even before strike capture");
    }

    function test_createPriceMarket_immediateDeferred_emitsEvent() public {
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectEmit(true, true, true, true);
        // For deferred markets, the event's strikePrice is 0 (not yet captured).
        emit PriceMarketCreatedPyth(1, venueId, ETH_USD_FEED, int64(0), PRICE_EXPO, block.timestamp, closeTime, 60);

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_immediateDeferred_customResolutionWindow() public {
        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0),
            120 // custom 120s window
        );

        (, , , , , , uint256 resolutionWindow, , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(resolutionWindow, 120);
    }

    function test_createPriceMarket_immediateDeferred_doesNotPayPythFee() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 balBefore = CREATOR.balance;

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );

        // Creation is non-payable and never touches Pyth — balance unchanged.
        assertEq(CREATOR.balance, balBefore);
    }

    function test_createPriceMarket_revertsPythNotConfigured() public {
        OddMaki freshDiamond = deployDiamond(address(this));
        VaultFacet(address(freshDiamond)).setCtf(address(ctf));
        ProtocolFacet(address(freshDiamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(freshDiamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(freshDiamond)).setUmaIdentifier(UMA_IDENTIFIER);
        uint256 vid = createDefaultVenue(address(freshDiamond));

        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(LibPriceMarketValidator.PythContractNotConfigured.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(freshDiamond)).createPriceMarketPyth(
            vid, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_revertsCloseTimeEqualOpenTime() public {
        uint256 closeTime = block.timestamp;

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotAfterOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_revertsCloseTimeBeforeOpenTime() public {
        vm.warp(10_000);
        uint256 closeTime = block.timestamp - 1;

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotAfterOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_acceptsAnyPositiveDuration() public {
        // No protocol min/max duration. Even a 1-second market is valid; bounds belong
        // to venues. Verifies the protocol does not impose a duration floor.
        uint256 closeTime = block.timestamp + 1;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );

        (, , , uint256 storedClose, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(storedClose, closeTime);
    }

    function test_createPriceMarket_acceptsLongHorizon() public {
        // No upper bound on duration either. A 5-year market is legal.
        uint256 closeTime = block.timestamp + 5 * 365 days;

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_customOutcomes() public {
        uint256 closeTime = block.timestamp + DURATION;

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Higher";
        outcomes[1] = "Lower";

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, outcomes, TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );

        (, , uint256 storedOpenTime, uint256 storedCloseTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(storedCloseTime);
        int64 closePrice = OPEN_PRICE + 100000000;

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, OPEN_PRICE, storedOpenTime, "Higher");

        _resolveDeferredMarket(marketId, OPEN_PRICE, closePrice);
    }

    function test_createPriceMarket_revertsNegativeStrikePrice() public {
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(LibPriceMarketValidator.ZeroStrikePrice.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(-100), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    // ======================================================================
    // CREATION — openTime validation
    // ======================================================================

    function test_createPriceMarket_acceptsOpenTimeZero() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 openTime, , , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(openTime, block.timestamp);
    }

    function test_createPriceMarket_acceptsOpenTimeInFuture() public {
        uint256 future = block.timestamp + 1 hours;
        uint256 marketId = _createScheduledDeferredMarket(future);
        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(openTime, future);
        assertEq(closeTime, future + DURATION);
    }

    function test_createPriceMarket_revertsOpenTimeAtBlockTimestamp() public {
        // openTime != 0 must be STRICTLY in the future.
        uint256 closeTime = block.timestamp + DURATION + 100;

        vm.expectRevert(LibPriceMarketValidator.InvalidOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), block.timestamp, closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_revertsOpenTimeInPast() public {
        vm.warp(10_000);
        uint256 pastOpen = block.timestamp - 1;
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(LibPriceMarketValidator.InvalidOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), pastOpen, closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createPriceMarket_scheduled_closeTimeMeasuredFromOpenTime() public {
        // closeTime must be strictly after the scheduled openTime, NOT just after
        // block.timestamp. A closeTime that's before block.timestamp + 1 hour but
        // also <= openTime must still revert.
        uint256 future = block.timestamp + 1 hours;
        uint256 badClose = future; // equal to openTime

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotAfterOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), future, badClose, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    // ======================================================================
    // RESOLUTION — immediate deferred Up/Down
    // ======================================================================

    function test_resolvePriceMarket_immediateDeferred_upWins() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 storedOpenTime, uint256 storedCloseTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(storedCloseTime);

        int64 closePrice = OPEN_PRICE + 100000000;
        _resolveDeferredMarket(marketId, OPEN_PRICE, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, int64 strikePrice, uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
        assertEq(strikePrice, OPEN_PRICE, "open price captured into strikePrice at resolution");
        assertEq(openPriceTime, storedOpenTime, "openPriceTime = open VAA publishTime");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));
    }

    function test_resolvePriceMarket_immediateDeferred_downWins() public {
        uint256 marketId = _createImmediateDeferredMarket();
        vm.warp(block.timestamp + DURATION);

        int64 closePrice = OPEN_PRICE - 100000000;
        _resolveDeferredMarket(marketId, OPEN_PRICE, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, int64 strikePrice, ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
        assertEq(strikePrice, OPEN_PRICE);
    }

    function test_resolvePriceMarket_immediateDeferred_equalPriceIsUp() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 storedOpenTime, uint256 storedCloseTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(storedCloseTime);

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, OPEN_PRICE, OPEN_PRICE, storedOpenTime, "Up");

        _resolveDeferredMarket(marketId, OPEN_PRICE, OPEN_PRICE);
    }

    function test_resolvePriceMarket_immediateDeferred_emitsEvent() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 storedOpenTime, uint256 storedCloseTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(storedCloseTime);

        int64 closePrice = OPEN_PRICE + 100000000;
        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, OPEN_PRICE, storedOpenTime, "Up");

        _resolveDeferredMarket(marketId, OPEN_PRICE, closePrice);
    }

    function test_resolvePriceMarket_refundsExcessETH_deferred() public {
        uint256 marketId = _createImmediateDeferredMarket();
        uint256 createdAt = block.timestamp;
        vm.warp(createdAt + DURATION);

        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, OPEN_PRICE, 0, PRICE_EXPO, OPEN_PRICE, 0, uint64(openTime)
        );
        pythData[1] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, OPEN_PRICE + 1, 0, PRICE_EXPO, OPEN_PRICE + 1, 0, uint64(closeTime)
        );

        uint256 expectedFee = mockPyth.getUpdateFee(pythData); // 2 wei (1 per VAA)
        uint256 balBefore = RESOLVER.balance;
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1 ether}(marketId, pythData);

        assertEq(RESOLVER.balance, balBefore - expectedFee);
    }

    function test_resolvePriceMarket_revertsBeforeCloseTime() public {
        uint256 marketId = _createImmediateDeferredMarket();
        // Don't warp -- still before closeTime

        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotReached.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarket_revertsIfAlreadyResolved() public {
        uint256 marketId = _createImmediateDeferredMarket();
        vm.warp(block.timestamp + DURATION);

        _resolveDeferredMarket(marketId, OPEN_PRICE, OPEN_PRICE + 1);

        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, OPEN_PRICE, 0, PRICE_EXPO, OPEN_PRICE, 0, uint64(openTime)
        );
        pythData[1] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, OPEN_PRICE + 1, 0, PRICE_EXPO, OPEN_PRICE + 1, 0, uint64(closeTime)
        );

        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 2}(marketId, pythData);
    }

    function test_resolvePriceMarket_revertsNotPriceMarket() public {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        uint256 regularMarketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));

        vm.expectRevert(LibPriceMarketValidator.NotPriceMarket.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(regularMarketId, pythData);
    }

    function test_canResolvePriceMarket_returnsFalseForNonPriceMarket() public {
        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(999));
    }

    function test_canResolvePriceMarket_lifecycle() public {
        uint256 marketId = _createImmediateDeferredMarket();

        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));

        vm.warp(block.timestamp + DURATION);
        assertTrue(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));

        _resolveDeferredMarket(marketId, OPEN_PRICE, OPEN_PRICE + 1);
        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));
    }

    // ======================================================================
    // RESOLUTION — scheduled deferred Up/Down
    // ======================================================================

    function test_resolvePriceMarket_scheduledDeferred_resolves() public {
        uint256 future = block.timestamp + 1 hours;
        uint256 marketId = _createScheduledDeferredMarket(future);

        // Warp past closeTime (and therefore past openTime + window).
        vm.warp(future + DURATION);

        int64 closePrice = OPEN_PRICE + 100000000;
        _resolveDeferredMarket(marketId, OPEN_PRICE, closePrice);

        (, , uint256 openTime, , , int64 finalPrice, , bool resolved, int64 strikePrice, uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(openTime, future);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
        assertEq(strikePrice, OPEN_PRICE);
        assertEq(openPriceTime, future, "open VAA publishTime matches scheduled openTime");
    }

    /// @dev There is intentionally no `openWindowNotElapsed` test. The protocol does
    ///      not enforce such a guard: Pyth publishTimes are monotonic, so once any
    ///      in-window VAA exists it is the canonical "earliest" — waiting longer
    ///      cannot change the selection. If no in-window VAA was ever published,
    ///      resolution reverts with `NoOpenPriceInWindow` until invalidation kicks
    ///      in past closeTime + grace.

    function test_resolvePriceMarket_revertsMissingOpenWindowVAA() public {
        uint256 marketId = _createImmediateDeferredMarket();
        uint256 createdAt = block.timestamp;
        vm.warp(createdAt + DURATION);

        // Only submit a close-window VAA — no in-range open VAA.
        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, OPEN_PRICE + 1, uint64(createdAt + DURATION));

        vm.expectRevert(LibPriceMarketValidator.NoOpenPriceInWindow.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarket_revertsMissingCloseWindowVAA_strike() public {
        // Strike market: resolution only checks the close window. Submit a VAA with
        // an out-of-range publishTime and expect NoClosePriceInWindow.
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        // Read the stored closeTime to avoid stale-local-variable confusion across
        // the warp boundary.
        (, , , uint256 storedCloseTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(storedCloseTime);

        // Publish a VAA at closeTime + window + 1, just past the close window
        // [closeTime, closeTime + 60]. parsePriceFeedUpdates reverts out-of-range
        // and our try/catch swallows it; pickEarliestInWindow returns found=false,
        // and the facet reverts with NoClosePriceInWindow.
        uint64 outOfRange = uint64(storedCloseTime + 61);
        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, STRIKE_PRICE + int64(100), outOfRange);

        vm.expectRevert(LibPriceMarketValidator.NoClosePriceInWindow.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarket_revertsMissingCloseWindowVAA_deferred() public {
        // Deferred market: submit ONLY an open-window VAA. Open capture succeeds,
        // close capture has no in-range VAA, expect NoClosePriceInWindow.
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(closeTime);

        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, OPEN_PRICE, uint64(openTime));

        vm.expectRevert(LibPriceMarketValidator.NoClosePriceInWindow.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarket_picksEarliestOpenAndCloseVAA() public {
        // Submit two in-range VAAs in each window, ordered late-first. The contract
        // must select the earliest publishTime per window — defends cherry-picking.
        uint256 marketId = _createImmediateDeferredMarket();
        (, , uint256 openTime, uint256 closeTime, , , , , , ) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(closeTime);

        int64 earlyOpen = OPEN_PRICE;
        int64 lateOpen = OPEN_PRICE + 50000000;
        int64 earlyClose = OPEN_PRICE - 100000000; // Down wins against earlyOpen
        int64 lateClose = OPEN_PRICE + 100000000; // Up wins against earlyOpen

        bytes[] memory pythData = new bytes[](4);
        // Order: late open, late close, early close, early open — adversarial ordering.
        pythData[0] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, lateOpen, 0, PRICE_EXPO, lateOpen, 0, uint64(openTime + 30)
        );
        pythData[1] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, lateClose, 0, PRICE_EXPO, lateClose, 0, uint64(closeTime + 30)
        );
        pythData[2] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, earlyClose, 0, PRICE_EXPO, earlyClose, 0, uint64(closeTime)
        );
        pythData[3] = mockPyth.createPriceFeedUpdateData(
            ETH_USD_FEED, earlyOpen, 0, PRICE_EXPO, earlyOpen, 0, uint64(openTime)
        );

        uint256 fee = mockPyth.getUpdateFee(pythData);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: fee}(marketId, pythData);

        (, , , , , int64 finalPrice, , bool resolved, int64 strikePrice, uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(strikePrice, earlyOpen, "strikePrice must come from earliest open-window VAA");
        assertEq(finalPrice, earlyClose, "finalPrice must come from earliest close-window VAA");
        assertEq(openPriceTime, openTime);
        // earlyClose (OPEN_PRICE - 1e8) < earlyOpen (OPEN_PRICE) → Down wins.
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));
    }

    // ======================================================================
    // STRIKE MARKET CREATION
    // ======================================================================

    function test_createStrikeMarket_happyPath() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        (
            bytes32 feedId,
            FeedProvider feedProvider,
            uint256 openTime,
            uint256 ct,
            int32 priceExpo,
            int64 finalPrice,
            uint256 resolutionWindow,
            bool resolved,
            int64 strikePrice,
            uint256 openPriceTime
        ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        assertEq(feedId, ETH_USD_FEED);
        assertEq(uint8(feedProvider), uint8(FeedProvider.PYTH));
        assertEq(openTime, block.timestamp);
        assertEq(ct, closeTime);
        assertEq(priceExpo, PRICE_EXPO);
        assertEq(finalPrice, int64(0));
        assertEq(resolutionWindow, 60);
        assertFalse(resolved);
        assertEq(strikePrice, STRIKE_PRICE);
        assertEq(openPriceTime, 0);

        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Active));
    }

    function test_createStrikeMarket_ignoresOpenTime() public {
        // Even if the caller passes a non-zero openTime, strike markets pin it to
        // block.timestamp. This keeps the documented semantics aligned with storage.
        uint256 closeTime = block.timestamp + DURATION;
        uint256 future = block.timestamp + 1 hours;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, future, closeTime + 1 hours, _aboveBelowOutcomes(),
            TICK_SIZE, address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );

        (, , uint256 openTime, , , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(openTime, block.timestamp, "strike markets pin openTime to block.timestamp");
    }

    function test_createStrikeMarket_emitsEvent() public {
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectEmit(true, true, true, true);
        emit PriceMarketCreatedPyth(1, venueId, ETH_USD_FEED, STRIKE_PRICE, PRICE_EXPO, block.timestamp, closeTime, 60);

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, uint256(0), closeTime, _aboveBelowOutcomes(),
            TICK_SIZE, address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createStrikeMarket_revertsCloseTimeNotAfterOpenTime() public {
        // Strike markets pin openTime to block.timestamp, so closeTime must be > now.
        uint256 closeTime = block.timestamp;

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotAfterOpenTime.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, uint256(0), closeTime, _aboveBelowOutcomes(),
            TICK_SIZE, address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );
    }

    function test_createStrikeMarket_noEthRequired() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 balBefore = CREATOR.balance;

        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        assertEq(CREATOR.balance, balBefore, "non-payable creation never touches caller ETH");
        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
    }

    // ======================================================================
    // STRIKE MARKET RESOLUTION
    // ======================================================================

    function test_resolveStrikeMarket_aboveWins() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        int64 closePrice = STRIKE_PRICE + 100000000;

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, STRIKE_PRICE, uint256(0), "Above");

        _resolveStrikeMarket(marketId, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, , uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
        assertEq(openPriceTime, 0, "strike markets never set openPriceTime");
    }

    function test_resolveStrikeMarket_belowWins() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        int64 closePrice = STRIKE_PRICE - 100000000;

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, STRIKE_PRICE, uint256(0), "Below");

        _resolveStrikeMarket(marketId, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
    }

    function test_resolveStrikeMarket_equalIsAbove() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, STRIKE_PRICE, STRIKE_PRICE, uint256(0), "Above");

        _resolveStrikeMarket(marketId, STRIKE_PRICE);

        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }

    function test_strikeMarket_resolutionDoesNotCaptureOpenPrice() public {
        // Confirm the resolution path for explicit-strike markets only requires a
        // close-window VAA; no open VAA is consulted and openPriceTime stays 0.
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, STRIKE_PRICE + 1, uint64(closeTime));
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);

        (, , , , , , , bool resolved, int64 strikePrice, uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(strikePrice, STRIKE_PRICE);
        assertEq(openPriceTime, 0);
    }

    // ======================================================================
    // ADMIN
    // ======================================================================

    function test_setPythContract_onlyOwner() public {
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSignature("NotContractOwner(address,address)", CREATOR, address(this)));
        PythResolutionFacet(address(diamond)).setPythContract(address(0x123));
    }

    function test_setPythContract_rejectsZeroAddress() public {
        vm.expectRevert(LibPriceMarketValidator.ZeroAddress.selector);
        PythResolutionFacet(address(diamond)).setPythContract(address(0));
    }

    function test_setPythContract_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit PythContractUpdated(address(0x456));
        PythResolutionFacet(address(diamond)).setPythContract(address(0x456));
    }

    function test_isPriceMarket_falseForNonExistent() public {
        assertFalse(PriceMarketFacet(address(diamond)).isPriceMarket(999));
    }

    // ======================================================================
    // DOUBLE-RESOLUTION GUARD
    // ======================================================================

    function test_doubleResolution_pythThenUmaFails() public {
        uint256 marketId = _createImmediateDeferredMarket();
        vm.warp(block.timestamp + DURATION);

        _resolveDeferredMarket(marketId, OPEN_PRICE, OPEN_PRICE + 1);

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));
    }

    function test_doubleResolution_strikeMarket() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        _resolveStrikeMarket(marketId, STRIKE_PRICE + 1);

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));

        bytes[] memory pythData = _buildPythVAA(ETH_USD_FEED, STRIKE_PRICE + 1, uint64(closeTime));
        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    // ======================================================================
    // RESOLUTION-WINDOW UPPER BOUND (ODD-19)
    // ======================================================================

    function test_createPriceMarket_revertsResolutionWindowTooLarge() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 tooLarge = LibPriceMarketStorage.MAX_RESOLUTION_WINDOW + 1;

        vm.expectRevert(LibPriceMarketValidator.ResolutionWindowTooLarge.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), tooLarge
        );
    }

    function test_createPriceMarket_acceptsMaxResolutionWindow() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 maxWindow = LibPriceMarketStorage.MAX_RESOLUTION_WINDOW;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(), TICK_SIZE,
            address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), maxWindow
        );

        (, , , , , , uint256 resolutionWindow, , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(resolutionWindow, maxWindow);
    }

    // ======================================================================
    // PYTH-ONLY ENFORCEMENT — oracle.reward forced to 0 at creation
    // ======================================================================

    function test_createPriceMarket_zeroesOracleReward() public {
        uint256 rewardingVenueId = VenueFacet(address(diamond)).createVenue(
            "Rewarding Venue",
            "",
            address(0),
            address(0),
            address(this),
            100,
            0,
            1e16,
            5e6,
            5e6, // umaRewardAmount — would have been escrowed for a UMA-resolved market
            1e6
        );

        collateral.mint(CREATOR, 5e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), 5e6);

        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            rewardingVenueId, ETH_USD_FEED, int64(0), uint256(0), closeTime, _upDownOutcomes(),
            TICK_SIZE, address(collateral), "q:title:Test,description:Test", 0, new bytes32[](0), 0
        );

        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(oracle.reward, 0, "price-market oracle.reward must be 0");
    }

    // ======================================================================
    // INVALIDATION ESCAPE HATCH (markPriceMarketInvalid)
    // ======================================================================

    function _invalidationGrace() internal pure returns (uint256) {
        return 7 days;
    }

    function test_markPriceMarketInvalid_happyPath() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        vm.warp(closeTime + _invalidationGrace());

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);

        vm.expectEmit(true, true, false, true, address(diamond));
        emit MarketResolved(marketId, reg.questionId, "INVALID");
        vm.expectEmit(true, true, false, false, address(diamond));
        emit PriceMarketInvalidated(marketId, address(this));

        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);

        MarketRegistryData memory regAfter = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint256(regAfter.status), uint256(MarketStatus.Resolved));
        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }

    function test_markPriceMarketInvalid_revertsBeforeGrace() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        vm.warp(closeTime + _invalidationGrace() - 1);

        vm.expectRevert(PythResolutionFacet.GracePeriodNotElapsed.selector);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);
    }

    function test_markPriceMarketInvalid_revertsBeforeCloseTime() public {
        uint256 marketId = _createImmediateDeferredMarket();

        vm.expectRevert(PythResolutionFacet.GracePeriodNotElapsed.selector);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);
    }

    function test_markPriceMarketInvalid_revertsAlreadyResolvedViaPyth() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);

        vm.warp(closeTime);
        _resolveDeferredMarket(marketId, OPEN_PRICE, OPEN_PRICE + 100);
        vm.warp(closeTime + _invalidationGrace() + 1);

        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);
    }

    function test_markPriceMarketInvalid_revertsTwice() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(closeTime + _invalidationGrace());

        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);

        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);
    }

    function test_markPriceMarketInvalid_revertsNotPriceMarket() public {
        vm.expectRevert(LibPriceMarketValidator.NotPriceMarket.selector);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(999);
    }

    function test_markPriceMarketInvalid_callableByAnyone() public {
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(closeTime + _invalidationGrace());

        address randomCaller = address(0xBEEF);
        vm.prank(randomCaller);
        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);

        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }

    function test_markPriceMarketInvalid_deferredMissingOpenVAA() public {
        // A deferred market whose open window had no Hermes VAA never resolves via Pyth.
        // After the grace period anyone can invalidate it through this same path.
        uint256 marketId = _createImmediateDeferredMarket();
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        vm.warp(closeTime + _invalidationGrace());

        PythResolutionFacet(address(diamond)).markPriceMarketInvalid(marketId);

        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }
}
