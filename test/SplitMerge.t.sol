// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketTradingData} from "../src/interfaces/Types.sol";
import {LibMarketContextService} from "../src/services/LibMarketContextService.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/**
 * @title SplitMerge integration tests
 * @notice Tests VaultFacet.splitPosition and VaultFacet.mergePositions via the Diamond.
 *         splitPosition: collateral in → YES + NO outcome tokens out.
 *         mergePositions: YES + NO outcome tokens in → collateral out.
 */
contract SplitMergeTest is Test, DiamondSetup {
    event PositionSplit(address indexed trader, uint256 indexed marketId, uint256 amount);
    event PositionsMerged(address indexed trader, uint256 indexed marketId, uint256 amount);
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public marketId;
    uint256 public venueId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    address constant ALICE = address(0xA11CE);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        marketId =
            MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        positionIds[0] = td.positionIds[0];
        positionIds[1] = td.positionIds[1];
    }

    // -------------------------------------------------------------------------
    // splitPosition
    // -------------------------------------------------------------------------

    function test_splitPosition_mintsOutcomeTokens() public {
        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);

        vm.prank(ALICE);
        collateral.approve(address(diamond), amount);

        vm.prank(ALICE);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);

        // ALICE receives YES and NO tokens; collateral moves to CTF
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), amount, "YES balance");
        assertEq(ctf.balanceOf(ALICE, positionIds[1]), amount, "NO balance");
        assertEq(collateral.balanceOf(ALICE), 0, "collateral spent");
        assertEq(collateral.balanceOf(address(ctf)), amount, "collateral in CTF");
    }

    function test_splitPosition_emitsPositionSplitEvent() public {
        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);
        vm.prank(ALICE);
        collateral.approve(address(diamond), amount);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit PositionSplit(ALICE, marketId, amount);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);
    }

    function test_splitPosition_revertsForInactiveMarket() public {
        collateral.mint(ALICE, 100e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), 100e6);

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        VaultFacet(address(diamond)).splitPosition(999, 100e6);
    }

    // -------------------------------------------------------------------------
    // mergePositions
    // -------------------------------------------------------------------------

    function test_mergePositions_returnsCollateral() public {
        uint256 amount = 100e6;

        // First split to get outcome tokens
        collateral.mint(ALICE, amount);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), amount);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);

        // Approve diamond to take outcome tokens back
        ctf.setApprovalForAll(address(diamond), true);
        VaultFacet(address(diamond)).mergePositions(marketId, amount);
        vm.stopPrank();

        // YES and NO tokens are burned; collateral returns to ALICE
        assertEq(ctf.balanceOf(ALICE, positionIds[0]), 0, "YES burned");
        assertEq(ctf.balanceOf(ALICE, positionIds[1]), 0, "NO burned");
        assertEq(collateral.balanceOf(ALICE), amount, "collateral returned");
    }

    function test_mergePositions_emitsPositionsMergedEvent() public {
        uint256 amount = 100e6;
        collateral.mint(ALICE, amount);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), amount);
        VaultFacet(address(diamond)).splitPosition(marketId, amount);

        ctf.setApprovalForAll(address(diamond), true);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit PositionsMerged(ALICE, marketId, amount);
        VaultFacet(address(diamond)).mergePositions(marketId, amount);
        vm.stopPrank();
    }

    function test_splitThenMerge_partialAmount() public {
        uint256 split = 200e6;
        uint256 merge = 80e6;

        collateral.mint(ALICE, split);
        vm.startPrank(ALICE);
        collateral.approve(address(diamond), split);
        VaultFacet(address(diamond)).splitPosition(marketId, split);

        ctf.setApprovalForAll(address(diamond), true);
        VaultFacet(address(diamond)).mergePositions(marketId, merge);
        vm.stopPrank();

        assertEq(ctf.balanceOf(ALICE, positionIds[0]), split - merge, "remaining YES");
        assertEq(ctf.balanceOf(ALICE, positionIds[1]), split - merge, "remaining NO");
        assertEq(collateral.balanceOf(ALICE), merge, "partial collateral returned");
    }
}
