// SPDX-License-Identifier: MIT
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
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {LibPriceMarketStorage} from "../src/storage/LibPriceMarketStorage.sol";
import {LibMarketOracleStorage} from "../src/storage/LibMarketOracleStorage.sol";

/// @title Price Market integration tests
/// @notice Tests Pyth-powered price market creation, resolution, and edge cases.
///         Covers both standard Up/Down markets and Target Strike markets.
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
    event PriceMarketResolvedPyth(uint256 indexed marketId, int64 finalPrice, int64 strikePrice, string outcome);

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

        // Fund the diamond with ETH for receiving Pyth refunds
        vm.deal(CREATOR, 10 ether);
        vm.deal(RESOLVER, 10 ether);

        // Prime MockPyth with initial feed data so getPriceUnsafe works for strike markets
        bytes[] memory initData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        mockPyth.updatePriceFeeds{value: 1}(initData);
    }

    // ---- Helpers ----

    function _buildPythUpdateData(bytes32 feedId, int64 price, uint64 publishTime)
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

    function _createPriceMarket(int64 openPrice) internal returns (uint256 marketId) {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, openPrice, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId,
            ETH_USD_FEED,
            int64(0), // no strike price
            closeTime,
            _upDownOutcomes(),
            TICK_SIZE,
            address(collateral),
            "q:title:ETH Up or Down,description:15 min price market",
            0, // liveness (default)
            new bytes32[](0), // tags
            0, // resolutionWindow (default 60s)
            pythData
        );
    }

    function _createStrikeMarket(int64 strikePrice, uint256 closeTime)
        internal
        returns (uint256 marketId)
    {
        // Strike markets don't need pythUpdateData or ETH — contract reads priceExpo via getPriceUnsafe
        vm.prank(CREATOR);
        marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId,
            ETH_USD_FEED,
            strikePrice,
            closeTime,
            _aboveBelowOutcomes(),
            TICK_SIZE,
            address(collateral),
            "q:title:ETH Above/Below $2500,description:Strike price market",
            0, // liveness (default)
            new bytes32[](0), // tags
            0, // resolutionWindow (default 60s)
            new bytes[](0) // empty — not used for strike markets
        );
    }

    function _resolvePriceMarket(uint256 marketId, int64 closePrice) internal {
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, closePrice, uint64(closeTime));

        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    // ======================================================================
    // PRICE MARKET CREATION (Up/Down with closeTime + outcomes[])
    // ======================================================================

    function test_createPriceMarketPyth_happyPath() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);

        // Verify price market overlay
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
        assertEq(openTime, block.timestamp);
        assertEq(closeTime, block.timestamp + DURATION);
        assertEq(priceExpo, PRICE_EXPO);
        assertEq(finalPrice, int64(0));
        assertEq(resolutionWindow, 60); // default
        assertFalse(resolved);
        assertEq(strikePrice, OPEN_PRICE); // Up/Down: strikePrice == captured open price
        assertEq(openPriceTime, block.timestamp); // VAA publishTime captured

        // Verify standard market was created
        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Active));
        assertEq(reg.venueId, venueId);
        assertEq(reg.creator, CREATOR);

        // Verify trading data
        MarketTradingData memory trading = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertTrue(trading.active);
        assertEq(trading.tickSize, TICK_SIZE);
    }

    function test_createPriceMarketPyth_emitsEvent() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectEmit(true, true, true, true);
        // strikePrice == captured open price for Up/Down markets
        emit PriceMarketCreatedPyth(1, venueId, ETH_USD_FEED, OPEN_PRICE, PRICE_EXPO, block.timestamp, closeTime, 60);

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_createPriceMarketPyth_customResolutionWindow() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0),
            120, // custom 120s window
            pythData
        );

        (, , , , , , uint256 resolutionWindow, , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(resolutionWindow, 120);
    }

    function test_createPriceMarketPyth_refundsExcessETH() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;
        uint256 balBefore = CREATOR.balance;

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1 ether}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );

        // Should have refunded all but 1 wei (the Pyth fee)
        assertEq(CREATOR.balance, balBefore - 1);
    }

    function test_createPriceMarketPyth_revertsPythNotConfigured() public {
        // Deploy a fresh Diamond without Pyth configured
        OddMaki freshDiamond = deployDiamond(address(this));
        VaultFacet(address(freshDiamond)).setCtf(address(ctf));
        ProtocolFacet(address(freshDiamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(freshDiamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(freshDiamond)).setUmaIdentifier(UMA_IDENTIFIER);
        uint256 vid = createDefaultVenue(address(freshDiamond));

        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(LibPriceMarketValidator.PythContractNotConfigured.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(freshDiamond)).createPriceMarketPyth{value: 1}(
            vid, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_createPriceMarketPyth_revertsCloseTimeTooSoon() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + 100; // below MIN_DURATION (300)

        vm.expectRevert(LibPriceMarketValidator.CloseTimeTooSoon.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_createPriceMarketPyth_revertsCloseTimeTooFar() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + 31_536_001; // above MAX_DURATION (1 year)

        vm.expectRevert(LibPriceMarketValidator.CloseTimeTooFar.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_createPriceMarketPyth_customOutcomes() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Higher";
        outcomes[1] = "Lower";

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, outcomes, TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );

        // Resolve and verify outcome uses the custom label
        vm.warp(closeTime);
        int64 closePrice = OPEN_PRICE + 100000000;

        vm.expectEmit(true, false, false, true);
        // strikePrice == OPEN_PRICE for Up/Down markets
        emit PriceMarketResolvedPyth(marketId, closePrice, OPEN_PRICE, "Higher");

        _resolvePriceMarket(marketId, closePrice);
    }

    function test_createPriceMarketPyth_revertsNegativeStrikePrice() public {
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(LibPriceMarketValidator.ZeroStrikePrice.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(-100), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    // ======================================================================
    // PRICE MARKET RESOLUTION (Up/Down)
    // ======================================================================

    function test_resolvePriceMarketPyth_upWins() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);

        // Warp past closeTime
        vm.warp(block.timestamp + DURATION);

        // Resolve with higher price -> Up wins
        int64 closePrice = OPEN_PRICE + 100000000; // +$1
        _resolvePriceMarket(marketId, closePrice);

        // Verify price market resolved
        (, , , , , int64 finalPrice, , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);

        // Verify market status is Resolved and trading disabled
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));
        MarketTradingData memory trading = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertFalse(trading.active);
    }

    function test_resolvePriceMarketPyth_downWins() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        int64 closePrice = OPEN_PRICE - 100000000; // -$1
        _resolvePriceMarket(marketId, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
    }

    function test_resolvePriceMarketPyth_equalPriceIsUp() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        // Equal price -> Up wins (finalPrice >= strikePrice)
        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, OPEN_PRICE, OPEN_PRICE, "Up");

        _resolvePriceMarket(marketId, OPEN_PRICE);

        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }

    function test_resolvePriceMarketPyth_emitsEvent() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        int64 closePrice = OPEN_PRICE + 100000000;
        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, OPEN_PRICE, "Up");

        _resolvePriceMarket(marketId, closePrice);
    }

    function test_resolvePriceMarketPyth_refundsExcessETH() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE + 1, uint64(closeTime));

        uint256 balBefore = RESOLVER.balance;
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1 ether}(marketId, pythData);

        assertEq(RESOLVER.balance, balBefore - 1); // only 1 wei used
    }

    function test_resolvePriceMarketPyth_revertsBeforeCloseTime() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        // Don't warp -- still before closeTime

        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));

        vm.expectRevert(LibPriceMarketValidator.CloseTimeNotReached.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarketPyth_revertsIfAlreadyResolved() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        _resolvePriceMarket(marketId, OPEN_PRICE + 1);

        // Try to resolve again
        (, , , uint256 closeTime, , , , , , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE + 1, uint64(closeTime));

        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    function test_resolvePriceMarketPyth_revertsNotPriceMarket() public {
        // Create a regular market (not a price market)
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        uint256 regularMarketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, uint64(block.timestamp));

        vm.expectRevert(LibPriceMarketValidator.NotPriceMarket.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(regularMarketId, pythData);
    }

    function test_canResolvePriceMarket_returnsFalseForNonPriceMarket() public {
        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(999));
    }

    function test_canResolvePriceMarket_lifecycle() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);

        // Before closeTime
        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));

        // After closeTime
        vm.warp(block.timestamp + DURATION);
        assertTrue(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));

        // After resolution
        _resolvePriceMarket(marketId, OPEN_PRICE + 1);
        assertFalse(PriceMarketFacet(address(diamond)).canResolvePriceMarket(marketId));
    }

    // ======================================================================
    // STRIKE MARKET CREATION
    // ======================================================================

    function test_createStrikeMarket_happyPath() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        // Verify price market overlay
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
        assertEq(strikePrice, STRIKE_PRICE); // Explicit strike price stored
        assertEq(openPriceTime, 0); // Strike markets don't capture an opening price

        // Verify standard market was created
        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Active));
    }

    function test_createStrikeMarket_emitsEvent() public {
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectEmit(true, true, true, true);
        emit PriceMarketCreatedPyth(1, venueId, ETH_USD_FEED, STRIKE_PRICE, PRICE_EXPO, block.timestamp, closeTime, 60);

        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, closeTime, _aboveBelowOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, new bytes[](0)
        );
    }

    function test_createStrikeMarket_revertsCloseTimeTooSoon() public {
        uint256 closeTime = block.timestamp + 100; // below MIN_DURATION

        vm.expectRevert(LibPriceMarketValidator.CloseTimeTooSoon.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, closeTime, _aboveBelowOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, new bytes[](0)
        );
    }

    function test_createStrikeMarket_revertsCloseTimeTooFar() public {
        uint256 closeTime = block.timestamp + 31_536_001; // above MAX_DURATION (1 year)

        vm.expectRevert(LibPriceMarketValidator.CloseTimeTooFar.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth(
            venueId, ETH_USD_FEED, STRIKE_PRICE, closeTime, _aboveBelowOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, new bytes[](0)
        );
    }

    function test_createStrikeMarket_noEthRequired() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 balBefore = CREATOR.balance;

        // Strike market: no ETH needed (no Pyth update), everything is refunded
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        // Creator balance unchanged — no ETH consumed
        assertEq(CREATOR.balance, balBefore);
        assertTrue(PriceMarketFacet(address(diamond)).isPriceMarket(marketId));
    }

    function test_createStrikeMarket_refundsAllEthIfSent() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 balBefore = CREATOR.balance;

        // Even if ETH is sent, it should all be refunded for strike markets
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1 ether}(
            venueId, ETH_USD_FEED, STRIKE_PRICE, closeTime, _aboveBelowOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, new bytes[](0)
        );

        // All ETH refunded
        assertEq(CREATOR.balance, balBefore);
    }

    // ======================================================================
    // STRIKE MARKET RESOLUTION
    // ======================================================================

    function test_resolveStrikeMarket_aboveWins() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        vm.warp(closeTime);

        // Price above strike -> "Above" wins
        int64 closePrice = STRIKE_PRICE + 100000000; // $2600

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, STRIKE_PRICE, "Above");

        _resolvePriceMarket(marketId, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
    }

    function test_resolveStrikeMarket_belowWins() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        vm.warp(closeTime);

        // Price below strike -> "Below" wins
        int64 closePrice = STRIKE_PRICE - 100000000; // $2400

        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, STRIKE_PRICE, "Below");

        _resolvePriceMarket(marketId, closePrice);

        (, , , , , int64 finalPrice, , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
        assertEq(finalPrice, closePrice);
    }

    function test_resolveStrikeMarket_equalIsAbove() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);

        vm.warp(closeTime);

        // Price equals strike -> "Above" wins (finalPrice >= strikePrice)
        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, STRIKE_PRICE, STRIKE_PRICE, "Above");

        _resolvePriceMarket(marketId, STRIKE_PRICE);

        (, , , , , , , bool resolved, , ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertTrue(resolved);
    }

    function test_upDownMarkets_strikeEqualsOpenPrice() public {
        // Standard Up/Down market: strikePrice == captured open price
        uint256 marketId = _createPriceMarket(OPEN_PRICE);

        // Verify strikePrice == OPEN_PRICE (auto-set from captured Pyth price)
        (, , , , , , , , int64 strikePrice, ) = PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(strikePrice, OPEN_PRICE);

        vm.warp(block.timestamp + DURATION);

        // Price above strikePrice -> "Up" wins
        int64 closePrice = OPEN_PRICE + 100000000;
        vm.expectEmit(true, false, false, true);
        emit PriceMarketResolvedPyth(marketId, closePrice, OPEN_PRICE, "Up");

        _resolvePriceMarket(marketId, closePrice);
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

    event PythContractUpdated(address indexed pythContract);

    function test_isPriceMarket_falseForNonExistent() public {
        assertFalse(PriceMarketFacet(address(diamond)).isPriceMarket(999));
    }

    // ======================================================================
    // DOUBLE-RESOLUTION GUARD
    // ======================================================================

    function test_doubleResolution_pythThenUmaFails() public {
        uint256 marketId = _createPriceMarket(OPEN_PRICE);
        vm.warp(block.timestamp + DURATION);

        // Resolve via Pyth first
        _resolvePriceMarket(marketId, OPEN_PRICE + 1);

        // Market is now Resolved -- UMA assert should fail because market is not Active
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));
    }

    function test_doubleResolution_strikeMarket() public {
        uint256 closeTime = block.timestamp + DURATION;
        uint256 marketId = _createStrikeMarket(STRIKE_PRICE, closeTime);
        vm.warp(closeTime);

        _resolvePriceMarket(marketId, STRIKE_PRICE + 1);

        // Verify resolved
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint8(reg.status), uint8(MarketStatus.Resolved));

        // Try to resolve again -- should revert
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, STRIKE_PRICE + 1, uint64(closeTime));
        vm.expectRevert(LibPriceMarketValidator.PriceMarketAlreadyResolved.selector);
        vm.prank(RESOLVER);
        PythResolutionFacet(address(diamond)).resolvePriceMarketPyth{value: 1}(marketId, pythData);
    }

    // ======================================================================
    // OPENING-PRICE STALENESS GUARD (ODD-21)
    // ======================================================================

    function test_createPriceMarketPyth_revertsStaleOpenPriceVaa() public {
        // Warp far enough that stale/fresh publishTimes are cleanly separated.
        vm.warp(10_000);

        // VAA is older than DEFAULT_OPEN_MAX_STALENESS (300s) → must revert.
        uint64 stalePublishTime = uint64(block.timestamp - 301);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, stalePublishTime);
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_createPriceMarketPyth_acceptsFreshOpenPriceVaa() public {
        vm.warp(10_000);

        // VAA publishTime just inside the staleness window.
        uint64 freshPublishTime = uint64(block.timestamp - 299);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, freshPublishTime);
        uint256 closeTime = block.timestamp + DURATION;

        vm.prank(CREATOR);
        uint256 marketId = PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );

        (, , , , , , , , int64 strikePrice, uint256 openPriceTime) =
            PriceMarketFacet(address(diamond)).getPriceMarket(marketId);
        assertEq(strikePrice, OPEN_PRICE);
        assertEq(openPriceTime, uint256(freshPublishTime));
    }

    function test_createPriceMarketPyth_revertsFutureVaaBeyondSkew() public {
        vm.warp(10_000);

        // VAA publishTime beyond the small forward skew (10s) → must revert.
        uint64 futurePublishTime = uint64(block.timestamp + 11);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, futurePublishTime);
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_setOpenMaxStaleness_onlyOwner() public {
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSignature("NotContractOwner(address,address)", CREATOR, address(this)));
        PythResolutionFacet(address(diamond)).setOpenMaxStaleness(60);
    }

    function test_setOpenMaxStaleness_tightensWindow() public {
        vm.warp(10_000);
        PythResolutionFacet(address(diamond)).setOpenMaxStaleness(60);
        assertEq(PythResolutionFacet(address(diamond)).getOpenMaxStaleness(), 60);

        // A VAA 61s old used to be fresh under the default 300s window but is now rejected.
        uint64 publishTime = uint64(block.timestamp - 61);
        bytes[] memory pythData = _buildPythUpdateData(ETH_USD_FEED, OPEN_PRICE, publishTime);
        uint256 closeTime = block.timestamp + DURATION;

        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        vm.prank(CREATOR);
        PythResolutionFacet(address(diamond)).createPriceMarketPyth{value: 1}(
            venueId, ETH_USD_FEED, int64(0), closeTime, _upDownOutcomes(), TICK_SIZE, address(collateral),
            "q:title:Test,description:Test", 0, new bytes32[](0), 0, pythData
        );
    }

    function test_getOpenMaxStaleness_returnsDefault() public {
        assertEq(
            PythResolutionFacet(address(diamond)).getOpenMaxStaleness(),
            LibPriceMarketStorage.DEFAULT_OPEN_MAX_STALENESS
        );
    }
}
