// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {MarketRegistryData, MarketTradingData, MarketGroupData, MarketStatus} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";

contract MarketGroupResolutionTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockUmaOracle public umaOracle;
    uint256 public venueId;
    uint256 public groupId;
    uint256[] public marketIds;

    address constant CREATOR = address(0xC8EA);
    address constant ASSERTER = address(0xA553E7);
    uint256 constant TICK_SIZE = 1e16;
    bytes32 constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    // Events
    event MarketResolved(uint256 indexed marketId, bytes32 indexed questionId, string outcome);
    event MarketGroupResolved(uint256 indexed groupId, uint256 indexed winningMarketId);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        umaOracle = new MockUmaOracle();

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(diamond)).setUmaIdentifier(UMA_IDENTIFIER);

        venueId = createDefaultVenue(address(diamond));

        // Create a market group with 3 markets
        vm.prank(CREATOR);
        groupId = MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who will win?", "Resolution criteria", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );

        // Add 3 markets
        marketIds = new uint256[](3);
        vm.startPrank(CREATOR);
        marketIds[0] = MarketsFacet(address(diamond)).addMarket(groupId, "Team A", "Will Team A win?");
        marketIds[1] = MarketsFacet(address(diamond)).addMarket(groupId, "Team B", "Will Team B win?");
        marketIds[2] = MarketsFacet(address(diamond)).addMarket(groupId, "Team C", "Will Team C win?");

        // Activate the group
        MarketGroupFacet(address(diamond)).activateMarketGroup(groupId);
        vm.stopPrank();
    }

    // ---- Helpers ----

    function _getQuestionId(uint256 mid) internal view returns (bytes32) {
        return MarketsFacet(address(diamond)).getMarketRegistryData(mid).questionId;
    }

    function _assertAndSettle(uint256 mid, string memory outcome) internal returns (bytes32 assertionId) {
        bytes32 qid = _getQuestionId(mid);

        collateral.mint(ASSERTER, 1e18);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), 1e18);
        vm.prank(ASSERTER);
        assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(qid, outcome);

        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
    }

    // =========================================================================
    // Cascade resolution — market 0 wins YES
    // =========================================================================

    function test_cascade_market0WinsYes_winnersPayoutsCorrect() public {
        _assertAndSettle(marketIds[0], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");

        // Winner: [1, 0] (YES wins)
        uint256[] memory winnerPayouts = ctf.getReportedPayouts(_getQuestionId(marketIds[0]));
        assertEq(winnerPayouts[0], 1);
        assertEq(winnerPayouts[1], 0);
    }

    function test_cascade_market0WinsYes_siblingsResolvedAsNo() public {
        _assertAndSettle(marketIds[0], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");

        // Sibling 1: [0, 1] (NO wins)
        uint256[] memory sib1Payouts = ctf.getReportedPayouts(_getQuestionId(marketIds[1]));
        assertEq(sib1Payouts[0], 0);
        assertEq(sib1Payouts[1], 1);

        // Sibling 2: [0, 1] (NO wins)
        uint256[] memory sib2Payouts = ctf.getReportedPayouts(_getQuestionId(marketIds[2]));
        assertEq(sib2Payouts[0], 0);
        assertEq(sib2Payouts[1], 1);
    }

    function test_cascade_market0WinsYes_allMarketsResolved() public {
        _assertAndSettle(marketIds[0], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");

        for (uint256 i = 0; i < 3; i++) {
            MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[i]);
            assertTrue(reg.status == MarketStatus.Resolved);
        }
    }

    function test_cascade_market0WinsYes_allTradingDisabled() public {
        _assertAndSettle(marketIds[0], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");

        for (uint256 i = 0; i < 3; i++) {
            MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketIds[i]);
            assertFalse(td.active);
        }
    }

    function test_cascade_market0WinsYes_groupStatusResolved() public {
        _assertAndSettle(marketIds[0], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");

        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertTrue(group.status == MarketStatus.Resolved);
        assertEq(group.resolvedMarketId, marketIds[0]);
    }

    function test_cascade_market0WinsYes_emitsGroupResolvedEvent() public {
        _assertAndSettle(marketIds[0], "Yes");

        vm.expectEmit(true, true, false, false);
        emit MarketGroupResolved(groupId, marketIds[0]);
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Yes");
    }

    // =========================================================================
    // Cascade resolution — market 1 (middle) wins YES
    // =========================================================================

    function test_cascade_market1WinsYes_correctPayouts() public {
        _assertAndSettle(marketIds[1], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[1], "Yes");

        // Winner
        uint256[] memory winnerPayouts = ctf.getReportedPayouts(_getQuestionId(marketIds[1]));
        assertEq(winnerPayouts[0], 1);
        assertEq(winnerPayouts[1], 0);

        // Sibling 0
        uint256[] memory sib0Payouts = ctf.getReportedPayouts(_getQuestionId(marketIds[0]));
        assertEq(sib0Payouts[0], 0);
        assertEq(sib0Payouts[1], 1);

        // Sibling 2
        uint256[] memory sib2Payouts = ctf.getReportedPayouts(_getQuestionId(marketIds[2]));
        assertEq(sib2Payouts[0], 0);
        assertEq(sib2Payouts[1], 1);
    }

    function test_cascade_market1WinsYes_groupResolvedMarketId() public {
        _assertAndSettle(marketIds[1], "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[1], "Yes");

        MarketGroupData memory group = MarketGroupFacet(address(diamond)).getMarketGroup(groupId);
        assertEq(group.resolvedMarketId, marketIds[1]);
    }

    // =========================================================================
    // No cascade on non-YES outcomes
    // =========================================================================

    function test_noCascade_noOutcome_onlyWinnerResolved() public {
        _assertAndSettle(marketIds[0], "No");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "No");

        // Winner is Resolved
        MarketRegistryData memory reg0 = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[0]);
        assertTrue(reg0.status == MarketStatus.Resolved);

        // Siblings still Active (no cascade)
        MarketRegistryData memory reg1 = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[1]);
        assertTrue(reg1.status == MarketStatus.Active);

        MarketRegistryData memory reg2 = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[2]);
        assertTrue(reg2.status == MarketStatus.Active);
    }

    function test_noCascade_invalidOutcome_onlyWinnerResolved() public {
        _assertAndSettle(marketIds[0], "Invalid");
        ResolutionFacet(address(diamond)).reportResolution(marketIds[0], "Invalid");

        // Winner Resolved with split payouts
        MarketRegistryData memory reg0 = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[0]);
        assertTrue(reg0.status == MarketStatus.Resolved);

        uint256[] memory payouts = ctf.getReportedPayouts(_getQuestionId(marketIds[0]));
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 1);

        // Siblings still Active
        MarketRegistryData memory reg1 = MarketsFacet(address(diamond)).getMarketRegistryData(marketIds[1]);
        assertTrue(reg1.status == MarketStatus.Active);
    }

    // =========================================================================
    // Cascade with placeholders
    // =========================================================================

    function test_cascade_skipsDraftPlaceholders() public {
        // Create a new group with 2 real + 1 placeholder
        vm.prank(CREATOR);
        uint256 gid2 = MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Placeholder test?", "Criteria", address(collateral), TICK_SIZE, 0, 0, new bytes32[](0)
        );

        vm.startPrank(CREATOR);
        uint256 m1 = MarketsFacet(address(diamond)).addMarket(gid2, "Real 1", "Will Real 1 win?");
        uint256 m2 = MarketsFacet(address(diamond)).addMarket(gid2, "Real 2", "Will Real 2 win?");
        uint256[] memory placeholders = MarketsFacet(address(diamond)).addPlaceholderMarkets(gid2, 1);
        uint256 placeholder = placeholders[0];

        MarketGroupFacet(address(diamond)).activateMarketGroup(gid2);
        vm.stopPrank();

        // Placeholder is still Draft
        MarketRegistryData memory phReg = MarketsFacet(address(diamond)).getMarketRegistryData(placeholder);
        assertTrue(phReg.status == MarketStatus.Draft);

        // Resolve m1 as Yes — should cascade to m2 but skip placeholder
        bytes32 qid = MarketsFacet(address(diamond)).getMarketRegistryData(m1).questionId;
        collateral.mint(ASSERTER, 1e18);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), 1e18);
        vm.prank(ASSERTER);
        bytes32 aid = ResolutionFacet(address(diamond)).assertMarketOutcome(qid, "Yes");
        ResolutionFacet(address(diamond)).settleAssertion(aid);
        ResolutionFacet(address(diamond)).reportResolution(m1, "Yes");

        // m1: Resolved
        MarketRegistryData memory m1Reg = MarketsFacet(address(diamond)).getMarketRegistryData(m1);
        assertTrue(m1Reg.status == MarketStatus.Resolved);

        // m2: Resolved (cascaded to NO)
        MarketRegistryData memory m2Reg = MarketsFacet(address(diamond)).getMarketRegistryData(m2);
        assertTrue(m2Reg.status == MarketStatus.Resolved);

        // Placeholder: still Draft (skipped by cascade)
        MarketRegistryData memory phRegAfter = MarketsFacet(address(diamond)).getMarketRegistryData(placeholder);
        assertTrue(phRegAfter.status == MarketStatus.Draft);
    }
}
