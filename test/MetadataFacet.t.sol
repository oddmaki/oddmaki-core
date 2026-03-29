// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {MetadataFacet} from "../src/facets/MetadataFacet.sol";
import {LibMarketGroupValidator} from "../src/validators/LibMarketGroupValidator.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

contract MetadataFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public venueId;

    address constant CREATOR = address(0xC8EA);
    address constant ALICE = address(0xA11CE);
    uint256 constant TICK_SIZE = 1e16;

    // Events for expectEmit
    event MarketMetadataUpdated(uint256 indexed marketId, string metadataURI);
    event MarketGroupMetadataUpdated(uint256 indexed groupId, string metadataURI);

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

    // ---- Helpers ----

    function _createMarket() internal returns (uint256) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        return MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );
    }

    function _createGroup() internal returns (uint256) {
        vm.prank(CREATOR);
        return MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );
    }

    // ====================
    // updateMarketMetadata
    // ====================

    function test_updateMarketMetadata_emitsEvent() public {
        uint256 marketId = _createMarket();
        string memory uri = "ipfs://QmTest123";

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketMetadataUpdated(marketId, uri);
        MetadataFacet(address(diamond)).updateMarketMetadata(marketId, uri);
    }

    function test_updateMarketMetadata_onlyCreatorCanCall() public {
        uint256 marketId = _createMarket();

        vm.prank(ALICE);
        vm.expectRevert(MetadataFacet.NotMarketCreator.selector);
        MetadataFacet(address(diamond)).updateMarketMetadata(marketId, "ipfs://QmTest123");
    }

    function test_updateMarketMetadata_emptyURIAllowed() public {
        uint256 marketId = _createMarket();

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketMetadataUpdated(marketId, "");
        MetadataFacet(address(diamond)).updateMarketMetadata(marketId, "");
    }

    function test_updateMarketMetadata_canUpdateMultipleTimes() public {
        uint256 marketId = _createMarket();

        vm.startPrank(CREATOR);

        vm.expectEmit(true, true, true, true);
        emit MarketMetadataUpdated(marketId, "ipfs://QmFirst");
        MetadataFacet(address(diamond)).updateMarketMetadata(marketId, "ipfs://QmFirst");

        vm.expectEmit(true, true, true, true);
        emit MarketMetadataUpdated(marketId, "ipfs://QmSecond");
        MetadataFacet(address(diamond)).updateMarketMetadata(marketId, "ipfs://QmSecond");

        vm.stopPrank();
    }

    // ============================
    // updateMarketGroupMetadata
    // ============================

    function test_updateMarketGroupMetadata_emitsEvent() public {
        uint256 groupId = _createGroup();
        string memory uri = "ipfs://QmGroupTest456";

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketGroupMetadataUpdated(groupId, uri);
        MetadataFacet(address(diamond)).updateMarketGroupMetadata(groupId, uri);
    }

    function test_updateMarketGroupMetadata_onlyCreatorCanCall() public {
        uint256 groupId = _createGroup();

        vm.prank(ALICE);
        vm.expectRevert(LibMarketGroupValidator.NotGroupCreator.selector);
        MetadataFacet(address(diamond)).updateMarketGroupMetadata(groupId, "ipfs://QmTest");
    }

    function test_updateMarketGroupMetadata_emptyURIAllowed() public {
        uint256 groupId = _createGroup();

        vm.prank(CREATOR);
        vm.expectEmit(true, true, true, true);
        emit MarketGroupMetadataUpdated(groupId, "");
        MetadataFacet(address(diamond)).updateMarketGroupMetadata(groupId, "");
    }

    function test_updateMarketGroupMetadata_nonExistentGroupReverts() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibMarketGroupValidator.MarketGroupNotFound.selector);
        MetadataFacet(address(diamond)).updateMarketGroupMetadata(999, "ipfs://QmTest");
    }
}
