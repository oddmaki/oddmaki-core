// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {TagsFacet} from "../src/facets/TagsFacet.sol";
import {LibTagValidator} from "../src/validators/LibTagValidator.sol";
import {LibMarketGroupValidator} from "../src/validators/LibMarketGroupValidator.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @title Tags facet integration tests
/// @notice Tests TagsFacet: market and group tagging, tag queries, and validation.
contract TagsFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public venueId;

    address constant CREATOR = address(0xC8EA);
    address constant ALICE = address(0xA11CE);
    uint256 constant TICK_SIZE = 1e16;

    // Events for expectEmit
    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed venueId,
        address indexed creator,
        bytes32 conditionId,
        address collateralToken,
        uint256 tickSize,
        string question,
        string[] outcomes,
        uint256 groupId,
        bytes32[] tags
    );
    event MarketGroupCreated(
        uint256 indexed groupId, uint256 indexed venueId, address indexed creator, string question, uint256 timestamp, bytes32[] tags
    );
    event MarketTagsUpdated(uint256 indexed marketId, bytes32[] tags);
    event MarketGroupTagsUpdated(uint256 indexed groupId, bytes32[] tags);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));

        // Fund CREATOR for market creation fees
        collateral.mint(CREATOR, 1000e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), type(uint256).max);
    }

    // ---- Helper ----

    function _makeTags(uint256 count) internal pure returns (bytes32[] memory) {
        bytes32[] memory tags = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            tags[i] = bytes32(bytes(string(abi.encodePacked("tag", i))));
        }
        return tags;
    }

    function _createMarketWithTags(bytes32[] memory tags) internal returns (uint256) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        return MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, tags
        );
    }

    function _createGroupWithTags(bytes32[] memory tags) internal returns (uint256) {
        vm.prank(CREATOR);
        return MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria", address(collateral), TICK_SIZE, 0, 0, tags
        );
    }

    // ====================
    // createMarket + tags
    // ====================

    function test_createMarket_emitsTagsInEvent() public {
        bytes32[] memory tags = new bytes32[](2);
        tags[0] = bytes32("sports");
        tags[1] = bytes32("crypto");

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        vm.prank(CREATOR);
        // Check that the MarketCreated event includes tags (check non-indexed data)
        vm.expectEmit(true, true, true, false);
        emit MarketCreated(1, venueId, CREATOR, bytes32(0), address(collateral), TICK_SIZE, "", outcomes, 0, tags);
        MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, tags
        );
    }

    function test_createMarket_emptyTagsAllowed() public {
        bytes32[] memory tags = new bytes32[](0);
        uint256 marketId = _createMarketWithTags(tags);
        assertEq(marketId, 1);
    }

    function test_createMarket_maxTagsAllowed() public {
        bytes32[] memory tags = _makeTags(5);
        uint256 marketId = _createMarketWithTags(tags);
        assertEq(marketId, 1);
    }

    function test_createMarket_tooManyTagsReverts() public {
        bytes32[] memory tags = _makeTags(6);
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        vm.expectRevert(LibTagValidator.TooManyTags.selector);
        MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, tags
        );
    }

    // ====================
    // createMarketGroup + tags
    // ====================

    function test_createMarketGroup_emitsTagsInEvent() public {
        bytes32[] memory tags = new bytes32[](1);
        tags[0] = bytes32("sports");

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, false);
        emit MarketGroupCreated(1, venueId, CREATOR, "Who will win?", block.timestamp, tags);
        MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria", address(collateral), TICK_SIZE, 0, 0, tags
        );
    }

    function test_createMarketGroup_tooManyTagsReverts() public {
        bytes32[] memory tags = _makeTags(6);
        vm.prank(CREATOR);
        vm.expectRevert(LibTagValidator.TooManyTags.selector);
        MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who?", "desc", address(collateral), TICK_SIZE, 0, 0, tags
        );
    }

    // ====================
    // updateMarketTags
    // ====================

    function test_updateMarketTags_emitsEvent() public {
        uint256 marketId = _createMarketWithTags(new bytes32[](0));

        bytes32[] memory newTags = new bytes32[](2);
        newTags[0] = bytes32("politics");
        newTags[1] = bytes32("world");

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketTagsUpdated(marketId, newTags);
        TagsFacet(address(diamond)).updateMarketTags(marketId, newTags);
    }

    function test_updateMarketTags_onlyCreatorCanCall() public {
        uint256 marketId = _createMarketWithTags(new bytes32[](0));

        bytes32[] memory newTags = new bytes32[](1);
        newTags[0] = bytes32("sports");

        vm.prank(ALICE);
        vm.expectRevert(TagsFacet.NotMarketCreator.selector);
        TagsFacet(address(diamond)).updateMarketTags(marketId, newTags);
    }

    function test_updateMarketTags_tooManyTagsReverts() public {
        uint256 marketId = _createMarketWithTags(new bytes32[](0));

        bytes32[] memory tooMany = _makeTags(6);
        vm.prank(CREATOR);
        vm.expectRevert(LibTagValidator.TooManyTags.selector);
        TagsFacet(address(diamond)).updateMarketTags(marketId, tooMany);
    }

    function test_updateMarketTags_emptyTagsAllowed() public {
        uint256 marketId = _createMarketWithTags(_makeTags(3));

        // Update to empty — clears tags
        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketTagsUpdated(marketId, new bytes32[](0));
        TagsFacet(address(diamond)).updateMarketTags(marketId, new bytes32[](0));
    }

    // ====================
    // updateMarketGroupTags
    // ====================

    function test_updateMarketGroupTags_emitsEvent() public {
        uint256 groupId = _createGroupWithTags(new bytes32[](0));

        bytes32[] memory newTags = new bytes32[](1);
        newTags[0] = bytes32("entertainment");

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketGroupTagsUpdated(groupId, newTags);
        TagsFacet(address(diamond)).updateMarketGroupTags(groupId, newTags);
    }

    function test_updateMarketGroupTags_onlyCreatorCanCall() public {
        uint256 groupId = _createGroupWithTags(new bytes32[](0));

        bytes32[] memory tags = new bytes32[](1);
        tags[0] = bytes32("sports");

        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        TagsFacet(address(diamond)).updateMarketGroupTags(groupId, tags);
    }

    function test_updateMarketGroupTags_tooManyTagsReverts() public {
        uint256 groupId = _createGroupWithTags(new bytes32[](0));

        bytes32[] memory tooMany = _makeTags(6);
        vm.prank(CREATOR);
        vm.expectRevert(LibTagValidator.TooManyTags.selector);
        TagsFacet(address(diamond)).updateMarketGroupTags(groupId, tooMany);
    }
}
