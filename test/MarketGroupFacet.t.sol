// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {LibMarketGroupValidator} from "../src/validators/LibMarketGroupValidator.sol";
import {MarketGroupData, MarketGroupItem, MarketRegistryData, MarketTradingData, MarketStatus} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract MarketGroupFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public venueId;

    address constant CREATOR = address(0xC8EA);
    address constant ALICE = address(0xA11CE);
    uint256 constant TICK_SIZE = 1e16;

    // Event declarations for expectEmit
    event MarketGroupCreated(
        uint256 indexed groupId, uint256 indexed venueId, address indexed creator, string question, uint256 timestamp, bytes32[] tags
    );
    event MarketAddedToGroup(uint256 indexed groupId, uint256 indexed marketId, string marketName, string marketQuestion);
    event PlaceholderMarketsAdded(uint256 indexed groupId, uint256[] marketIds, uint256 count);
    event PlaceholderActivated(
        uint256 indexed groupId, uint256 indexed marketId, string marketName, string marketQuestion, uint256 timestamp
    );
    event MarketGroupActivated(uint256 indexed groupId, uint256 marketCount, uint256 timestamp);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));
    }

    // ---- Helpers ----

    function _createGroup() internal returns (uint256) {
        vm.prank(CREATOR);
        return MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria here", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );
    }

    function _addMarket(uint256 groupId, string memory name, string memory question) internal returns (uint256) {
        vm.prank(CREATOR);
        return MarketsFacet(address(diamond)).addMarket(groupId, name, question);
    }

    function _createGroupWithMarkets(uint256 count) internal returns (uint256 groupId, uint256[] memory marketIds) {
        groupId = _createGroup();
        marketIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            marketIds[i] = _addMarket(groupId, "Market", "Will market win?");
        }
    }

    // =========================================================================
    // createMarketGroup
    // =========================================================================

    function test_createMarketGroup_returnsIdOne() public {
        uint256 groupId = _createGroup();
        assertEq(groupId, 1);
    }

    function test_createMarketGroup_storesCorrectData() public {
        uint256 groupId = _createGroup();
        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);

        assertEq(group.groupId, 1);
        assertEq(group.marketIds.length, 0);
        assertEq(group.totalMarkets, 0);
        assertEq(keccak256(bytes(group.question)), keccak256(bytes("Who will win?")));
        assertEq(keccak256(bytes(group.description)), keccak256(bytes("Resolution criteria here")));
        assertEq(uint256(group.status), uint256(MarketStatus.Draft));
        assertEq(group.resolvedMarketId, 0);
        assertEq(group.creator, CREATOR);
        assertEq(group.venueId, venueId);
        assertEq(address(group.collateralToken), address(collateral));
        assertEq(group.tickSize, TICK_SIZE);
    }

    function test_createMarketGroup_emitsEvent() public {
        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketGroupCreated(1, venueId, CREATOR, "Who will win?", block.timestamp, new bytes32[](0));
        MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );
    }

    function test_createMarketGroup_revertsOnEmptyQuestion() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.InvalidQuestion.selector);
        MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "", "desc", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );
    }

    function test_createMarketGroup_incrementsId() public {
        uint256 id1 = _createGroup();
        uint256 id2 = _createGroup();
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    // =========================================================================
    // addMarket
    // =========================================================================

    function test_addMarket_createsMarketInDraftStatus() public {
        uint256 groupId = _createGroup();
        uint256 marketId = _addMarket(groupId, "Warriors", "Will Warriors win?");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(uint256(reg.status), uint256(MarketStatus.Draft));
    }

    function test_addMarket_setsGroupIdOnMarket() public {
        uint256 groupId = _createGroup();
        uint256 marketId = _addMarket(groupId, "Warriors", "Will Warriors win?");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertEq(reg.groupId, groupId);
    }

    function test_addMarket_marketNotActiveForTrading() public {
        uint256 groupId = _createGroup();
        uint256 marketId = _addMarket(groupId, "Warriors", "Will Warriors win?");

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertFalse(td.active);
    }

    function test_addMarket_addsToGroupMarketIds() public {
        uint256 groupId = _createGroup();
        uint256 market1 = _addMarket(groupId, "Warriors", "Will Warriors win?");
        uint256 market2 = _addMarket(groupId, "Lakers", "Will Lakers win?");

        uint256[] memory ids = MarketGroupFacet(address(diamond)).getGroupMarketIds(groupId);
        assertEq(ids.length, 2);
        assertEq(ids[0], market1);
        assertEq(ids[1], market2);
    }

    function test_addMarket_storesGroupItem() public {
        uint256 groupId = _createGroup();
        uint256 marketId = _addMarket(groupId, "Warriors", "Will Warriors win?");

        MarketGroupItem memory item = MarketGroupFacet(address(diamond)).getMarketGroupItem(marketId);
        assertFalse(item.isPlaceholder);
        assertEq(keccak256(bytes(item.marketName)), keccak256(bytes("Warriors")));
    }

    function test_addMarket_emitsEvent() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        vm.expectEmit(true, true, false, true);
        emit MarketAddedToGroup(groupId, 1, "Warriors", "Will Warriors win?");
        MarketsFacet(address(diamond)).addMarket(groupId, "Warriors", "Will Warriors win?");
    }

    function test_addMarket_revertsIfNotCreator() public {
        uint256 groupId = _createGroup();
        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        MarketsFacet(address(diamond)).addMarket(groupId, "Warriors", "Will Warriors win?");
    }

    function test_addMarket_revertsIfGroupNotDraft() public {
        (uint256 groupId,) = _createGroupWithMarkets(2);
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.GroupNotDraft.selector);
        MarketsFacet(address(diamond)).addMarket(groupId, "New", "New question?");
    }

    function test_addMarket_revertsIfGroupNotFound() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.MarketGroupNotFound.selector);
        MarketsFacet(address(diamond)).addMarket(999, "Name", "Question?");
    }

    // =========================================================================
    // addPlaceholderMarkets
    // =========================================================================

    function test_addPlaceholderMarkets_createsCorrectCount() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        uint256[] memory ids = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 3);
        assertEq(ids.length, 3);

        uint256[] memory groupIds = MarketGroupFacet(address(diamond)).getGroupMarketIds(groupId);
        assertEq(groupIds.length, 3);
    }

    function test_addPlaceholderMarkets_marketsArePlaceholders() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        uint256[] memory ids = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);

        for (uint256 i = 0; i < ids.length; i++) {
            MarketGroupItem memory item = MarketGroupFacet(address(diamond)).getMarketGroupItem(ids[i]);
            assertTrue(item.isPlaceholder);
            assertEq(bytes(item.marketName).length, 0);
        }
    }

    function test_addPlaceholderMarkets_marketsAreDraft() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        uint256[] memory ids = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);

        for (uint256 i = 0; i < ids.length; i++) {
            MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(ids[i]);
            assertEq(uint256(reg.status), uint256(MarketStatus.Draft));
        }
    }

    function test_addPlaceholderMarkets_revertsIfNotCreator() public {
        uint256 groupId = _createGroup();
        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);
    }

    // =========================================================================
    // activateMarketGroup
    // =========================================================================

    function test_activateMarketGroup_setsGroupActive() public {
        (uint256 groupId,) = _createGroupWithMarkets(2);
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(uint256(group.status), uint256(MarketStatus.Active));
    }

    function test_activateMarketGroup_locksTotalMarkets() public {
        (uint256 groupId,) = _createGroupWithMarkets(3);
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(group.totalMarkets, 3);
    }

    function test_activateMarketGroup_activatesNonPlaceholders() public {
        (uint256 groupId, uint256[] memory marketIds) = _createGroupWithMarkets(2);
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        for (uint256 i = 0; i < marketIds.length; i++) {
            MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[i]);
            assertEq(uint256(reg.status), uint256(MarketStatus.Active));

            MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketIds[i]);
            assertTrue(td.active);
        }
    }

    function test_activateMarketGroup_placeholdersRemainDraft() public {
        uint256 groupId = _createGroup();
        uint256 market1 = _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 1);

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        // Non-placeholder should be Active
        MarketRegistryData memory reg1 = MarketsFacet(address(diamond)).getMarketRegistryData(market1);
        assertEq(uint256(reg1.status), uint256(MarketStatus.Active));

        // Placeholder should remain Draft
        MarketRegistryData memory reg2 = MarketsFacet(address(diamond)).getMarketRegistryData(placeholders[0]);
        assertEq(uint256(reg2.status), uint256(MarketStatus.Draft));

        MarketTradingData memory td2 = MarketsFacet(address(diamond)).getMarketTradingData(placeholders[0]);
        assertFalse(td2.active);
    }

    function test_activateMarketGroup_emitsEvent() public {
        (uint256 groupId,) = _createGroupWithMarkets(3);

        vm.prank(CREATOR);
        vm.expectEmit(true, false, false, true);
        emit MarketGroupActivated(groupId, 3, block.timestamp);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    function test_activateMarketGroup_revertsOnInsufficientMarkets_zero() public {
        uint256 groupId = _createGroup();

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.InsufficientMarkets.selector);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    function test_activateMarketGroup_revertsOnInsufficientMarkets_one() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Only", "Only market?");

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.InsufficientMarkets.selector);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    function test_activateMarketGroup_revertsIfNotCreator() public {
        (uint256 groupId,) = _createGroupWithMarkets(2);

        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    function test_activateMarketGroup_revertsIfAlreadyActive() public {
        (uint256 groupId,) = _createGroupWithMarkets(2);
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.GroupNotDraft.selector);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    // -- M-9: All-placeholder activation --

    function test_M9_activateMarketGroup_revertsWithAllPlaceholders() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 3);

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.InsufficientMarkets.selector);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
    }

    function test_M9_activateMarketGroup_succeedsWithOneRealAndPlaceholders() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(uint256(group.status), uint256(MarketStatus.Active));
    }

    // =========================================================================
    // activatePlaceholder
    // =========================================================================

    function test_activatePlaceholder_updatesItem() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 1);
        uint256 phId = placeholders[0];

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, phId, "Lakers", "Will Lakers win?");

        MarketGroupItem memory item = MarketGroupFacet(address(diamond)).getMarketGroupItem(phId);
        assertFalse(item.isPlaceholder);
        assertEq(keccak256(bytes(item.marketName)), keccak256(bytes("Lakers")));
    }

    function test_activatePlaceholder_activatesMarket() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 1);
        uint256 phId = placeholders[0];

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, phId, "Lakers", "Will Lakers win?");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(phId);
        assertEq(uint256(reg.status), uint256(MarketStatus.Active));

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(phId);
        assertTrue(td.active);
    }

    function test_activatePlaceholder_emitsEvent() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 1);
        uint256 phId = placeholders[0];

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        vm.expectEmit(true, true, false, true);
        emit PlaceholderActivated(groupId, phId, "Lakers", "Will Lakers win?", block.timestamp);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, phId, "Lakers", "Will Lakers win?");
    }

    function test_activatePlaceholder_revertsIfNotPlaceholder() public {
        uint256 groupId = _createGroup();
        uint256 market1 = _addMarket(groupId, "Warriors", "Will Warriors win?");
        _addMarket(groupId, "Lakers", "Will Lakers win?");

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.MarketNotPlaceholder.selector);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, market1, "New", "New?");
    }

    function test_activatePlaceholder_revertsIfGroupNotActive() public {
        uint256 groupId = _createGroup();
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);

        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.GroupNotActive.selector);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, placeholders[0], "Name", "Question?");
    }

    function test_activatePlaceholder_revertsIfNotCreator() public {
        uint256 groupId = _createGroup();
        _addMarket(groupId, "Warriors", "Will Warriors win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 1);

        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, placeholders[0], "Name", "Question?");
    }

    // =========================================================================
    // Full lifecycle
    // =========================================================================

    function test_fullLifecycle_createAddActivate() public {
        // Create group
        uint256 groupId = _createGroup();

        // Add 3 markets
        uint256 m1 = _addMarket(groupId, "Warriors", "Will Warriors win?");
        uint256 m2 = _addMarket(groupId, "Lakers", "Will Lakers win?");
        uint256 m3 = _addMarket(groupId, "Celtics", "Will Celtics win?");

        // Verify group data before activation
        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(group.marketIds.length, 3);
        assertEq(group.totalMarkets, 0); // Not yet locked
        assertEq(uint256(group.status), uint256(MarketStatus.Draft));

        // Verify all markets are Draft
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m1).status), uint256(MarketStatus.Draft));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m2).status), uint256(MarketStatus.Draft));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m3).status), uint256(MarketStatus.Draft));

        // Activate group
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        // Verify group activated
        group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(group.totalMarkets, 3);
        assertEq(uint256(group.status), uint256(MarketStatus.Active));

        // Verify all markets are Active
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m1).status), uint256(MarketStatus.Active));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m2).status), uint256(MarketStatus.Active));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m3).status), uint256(MarketStatus.Active));

        // Verify trading is active
        assertTrue(MarketsFacet(address(diamond)).getMarketTradingData(m1).active);
        assertTrue(MarketsFacet(address(diamond)).getMarketTradingData(m2).active);
        assertTrue(MarketsFacet(address(diamond)).getMarketTradingData(m3).active);

        // Verify groupId set on all markets
        assertEq(MarketsFacet(address(diamond)).getMarketRegistryData(m1).groupId, groupId);
        assertEq(MarketsFacet(address(diamond)).getMarketRegistryData(m2).groupId, groupId);
        assertEq(MarketsFacet(address(diamond)).getMarketRegistryData(m3).groupId, groupId);
    }

    function test_fullLifecycle_withPlaceholders() public {
        // Create group
        uint256 groupId = _createGroup();

        // Add 2 real markets + 2 placeholders
        uint256 m1 = _addMarket(groupId, "Warriors", "Will Warriors win?");
        uint256 m2 = _addMarket(groupId, "Lakers", "Will Lakers win?");
        vm.prank(CREATOR);
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(groupId, 2);
        uint256 ph1 = placeholders[0];
        uint256 ph2 = placeholders[1];

        // Activate group
        vm.prank(CREATOR);
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);

        // Verify totalMarkets locked at 4
        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(group.totalMarkets, 4);

        // Real markets should be Active
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m1).status), uint256(MarketStatus.Active));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(m2).status), uint256(MarketStatus.Active));

        // Placeholders should remain Draft
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(ph1).status), uint256(MarketStatus.Draft));
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(ph2).status), uint256(MarketStatus.Draft));

        // Activate placeholder 1
        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, ph1, "Celtics", "Will Celtics win?");

        // Verify ph1 is now Active
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(ph1).status), uint256(MarketStatus.Active));
        assertTrue(MarketsFacet(address(diamond)).getMarketTradingData(ph1).active);
        MarketGroupItem memory item1 = MarketGroupFacet(address(diamond)).getMarketGroupItem(ph1);
        assertFalse(item1.isPlaceholder);
        assertEq(keccak256(bytes(item1.marketName)), keccak256(bytes("Celtics")));

        // ph2 still Draft
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(ph2).status), uint256(MarketStatus.Draft));

        // Activate placeholder 2
        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).activatePlaceholder(groupId, ph2, "Heat", "Will Heat win?");

        // Verify ph2 is now Active
        assertEq(uint256(MarketsFacet(address(diamond)).getMarketRegistryData(ph2).status), uint256(MarketStatus.Active));
        assertTrue(MarketsFacet(address(diamond)).getMarketTradingData(ph2).active);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    function test_getMarketGroup_revertsOnNonexistent() public {
        vm.expectRevert(LibMarketGroupValidator.MarketGroupNotFound.selector);
        MarketGroupFacet(address(diamond)).getMarketGroup(999);
    }

    function test_getGroupMarketIds_revertsOnNonexistent() public {
        vm.expectRevert(LibMarketGroupValidator.MarketGroupNotFound.selector);
        MarketGroupFacet(address(diamond)).getGroupMarketIds(999);
    }

    function test_getGroupMarketIds_returnsCorrectIds() public {
        uint256 groupId = _createGroup();
        uint256 m1 = _addMarket(groupId, "A", "Q?");
        uint256 m2 = _addMarket(groupId, "B", "Q?");

        uint256[] memory ids = MarketGroupFacet(address(diamond)).getGroupMarketIds(groupId);
        assertEq(ids.length, 2);
        assertEq(ids[0], m1);
        assertEq(ids[1], m2);
    }

    function test_getNextGroupId() public {
        assertEq(MarketGroupFacet(address(diamond)).getNextGroupId(), 0);
        _createGroup();
        assertEq(MarketGroupFacet(address(diamond)).getNextGroupId(), 1);
        _createGroup();
        assertEq(MarketGroupFacet(address(diamond)).getNextGroupId(), 2);
    }

    function test_getMarketGroupItem_defaultsForNonGroupedMarket() public {
        MarketGroupItem memory item = MarketGroupFacet(address(diamond)).getMarketGroupItem(999);
        assertFalse(item.isPlaceholder);
        assertEq(bytes(item.marketName).length, 0);
    }
}
