// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {VenueData} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";

/// @title Venue facet integration tests
/// @notice Tests VenueFacet: venue creation, updates, fee configuration, oracle params, pause/unpause.
contract VenueFacetTest is Test, DiamondSetup {
    OddMaki public diamond;

    address constant OPERATOR = address(0xABCD);
    address constant FEE_RECIPIENT = address(0xFEE);
    address constant ALICE = address(0xA11CE);

    // Declare event for expectEmit
    event VenueCreated(uint256 indexed venueId, address indexed operator, string name, string metadata);
    event VenueUpdated(uint256 indexed venueId, address indexed operator, string name, string metadata);
    event VenueFeesUpdated(uint256 indexed venueId, uint256 venueFeeBps, uint256 creatorFeeBps);
    event VenueOracleParamsUpdated(uint256 indexed venueId, uint256 umaRewardAmount, uint256 umaMinBond);
    event VenuePaused(uint256 indexed venueId, address indexed operator);
    event VenueUnpaused(uint256 indexed venueId, address indexed operator);

    function setUp() public {
        diamond = deployDiamond(address(this));
    }

    // ---- Helpers ----

    function _createDefaultVenue() internal returns (uint256) {
        vm.prank(OPERATOR);
        return VenueFacet(address(diamond))
            .createVenue("My Venue", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 5e6, 0, 1e6);
    }

    // =========================================================================
    // createVenue
    // =========================================================================

    function test_createVenue_returnsIdOne() public {
        uint256 venueId = _createDefaultVenue();
        assertEq(venueId, 1);
    }

    function test_createVenue_secondVenueReturnsIdTwo() public {
        _createDefaultVenue();
        vm.prank(OPERATOR);
        uint256 id2 = VenueFacet(address(diamond))
            .createVenue("Venue 2", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 5e6, 0, 1e6);
        assertEq(id2, 2);
    }

    function test_createVenue_storesCorrectData() public {
        vm.prank(OPERATOR);
        uint256 venueId = VenueFacet(address(diamond))
            .createVenue(
                "My Venue", "ipfs://meta", address(0x1), address(0x2), FEE_RECIPIENT, 150, 50, 1e16, 10e6, 1e18, 5e18
            );

        VenueData memory v = VenueFacet(address(diamond)).getVenue(venueId);
        assertEq(v.venueId, venueId);
        assertEq(v.operator, OPERATOR);
        assertEq(v.name, "My Venue");
        assertEq(v.metadata, "ipfs://meta");
        assertEq(v.tradingAccessControl, address(0x1));
        assertEq(v.creationAccessControl, address(0x2));
        assertEq(v.feeRecipient, FEE_RECIPIENT);
        assertEq(v.venueFeeBps, 150);
        assertEq(v.creatorFeeBps, 50);
        assertEq(v.defaultTickSize, 1e16);
        assertEq(v.marketCreationFee, 10e6);
        assertEq(v.umaRewardAmount, 1e18);
        assertEq(v.umaMinBond, 5e18);
        assertTrue(v.active);
    }

    function test_createVenue_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit VenueCreated(1, OPERATOR, "My Venue", "");
        vm.prank(OPERATOR);
        VenueFacet(address(diamond))
            .createVenue("My Venue", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 5e6, 0, 1e6);
    }

    // =========================================================================
    // createVenue validation
    // =========================================================================

    function test_createVenue_revertsOnEmptyName() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidVenueName.selector);
        VenueFacet(address(diamond)).createVenue("", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 5e6, 0, 1e6);
    }

    function test_createVenue_revertsOnVenueFeeTooLow() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidVenueFee.selector);
        VenueFacet(address(diamond)).createVenue("V", "", address(0), address(0), FEE_RECIPIENT, 0, 0, 1e16, 5e6, 0, 1e6);
    }

    function test_createVenue_revertsOnVenueFeeTooHigh() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidVenueFee.selector);
        VenueFacet(address(diamond))
            .createVenue("V", "", address(0), address(0), FEE_RECIPIENT, 201, 0, 1e16, 5e6, 0, 1e6);
    }

    function test_createVenue_revertsOnCreatorFeeExceedsVenueFee() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidCreatorFee.selector);
        VenueFacet(address(diamond))
            .createVenue("V", "", address(0), address(0), FEE_RECIPIENT, 100, 101, 1e16, 5e6, 0, 1e6);
    }

    function test_createVenue_revertsOnZeroFeeRecipient() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidFeeRecipient.selector);
        VenueFacet(address(diamond)).createVenue("V", "", address(0), address(0), address(0), 100, 0, 1e16, 5e6, 0, 1e6);
    }

    function test_createVenue_revertsOnLowMarketCreationFee() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidMarketCreationFee.selector);
        VenueFacet(address(diamond)).createVenue("V", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 4e6, 0, 1e6);
    }

    function test_createVenue_revertsOnZeroUmaMinBond() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidUmaMinBond.selector);
        VenueFacet(address(diamond)).createVenue("V", "", address(0), address(0), FEE_RECIPIENT, 100, 0, 1e16, 5e6, 0, 0);
    }

    function test_updateVenueOracleParams_revertsOnZeroUmaMinBond() public {
        uint256 venueId = _createDefaultVenue();
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidUmaMinBond.selector);
        VenueFacet(address(diamond)).updateVenueOracleParams(venueId, 1e18, 0);
    }

    // =========================================================================
    // updateVenue
    // =========================================================================

    function test_updateVenue_updatesFields() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        VenueFacet(address(diamond))
            .updateVenue(venueId, "New Name", "ipfs://new", address(0x1), address(0x2), address(0xBEEF));

        VenueData memory v = VenueFacet(address(diamond)).getVenue(venueId);
        assertEq(v.name, "New Name");
        assertEq(v.metadata, "ipfs://new");
        assertEq(v.tradingAccessControl, address(0x1));
        assertEq(v.creationAccessControl, address(0x2));
        assertEq(v.feeRecipient, address(0xBEEF));
    }

    function test_updateVenue_emitsEvent() public {
        uint256 venueId = _createDefaultVenue();

        vm.expectEmit(true, true, false, true);
        emit VenueUpdated(venueId, OPERATOR, "New", "meta");
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).updateVenue(venueId, "New", "meta", address(0), address(0), FEE_RECIPIENT);
    }

    function test_updateVenue_revertsIfNotOperator() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        VenueFacet(address(diamond)).updateVenue(venueId, "New", "", address(0), address(0), FEE_RECIPIENT);
    }

    function test_updateVenue_revertsOnEmptyName() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidVenueName.selector);
        VenueFacet(address(diamond)).updateVenue(venueId, "", "", address(0), address(0), FEE_RECIPIENT);
    }

    function test_updateVenue_revertsOnZeroFeeRecipient() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.InvalidFeeRecipient.selector);
        VenueFacet(address(diamond)).updateVenue(venueId, "V", "", address(0), address(0), address(0));
    }

    // =========================================================================
    // updateVenueFees
    // =========================================================================

    function test_updateVenueFees_works() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).updateVenueFees(venueId, 150, 30);

        (uint256 vfee, uint256 cfee) = VenueFacet(address(diamond)).getVenueFees(venueId);
        assertEq(vfee, 150);
        assertEq(cfee, 30);
    }

    function test_updateVenueFees_emitsEvent() public {
        uint256 venueId = _createDefaultVenue();

        vm.expectEmit(true, false, false, true);
        emit VenueFeesUpdated(venueId, 150, 30);
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).updateVenueFees(venueId, 150, 30);
    }

    function test_updateVenueFees_revertsIfNotOperator() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        VenueFacet(address(diamond)).updateVenueFees(venueId, 150, 30);
    }

    // =========================================================================
    // updateVenueOracleParams
    // =========================================================================

    function test_updateVenueOracleParams_works() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).updateVenueOracleParams(venueId, 2e18, 10e18);

        VenueData memory v = VenueFacet(address(diamond)).getVenue(venueId);
        assertEq(v.umaRewardAmount, 2e18);
        assertEq(v.umaMinBond, 10e18);
    }

    function test_updateVenueOracleParams_emitsEvent() public {
        uint256 venueId = _createDefaultVenue();

        vm.expectEmit(true, false, false, true);
        emit VenueOracleParamsUpdated(venueId, 2e18, 10e18);
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).updateVenueOracleParams(venueId, 2e18, 10e18);
    }

    // =========================================================================
    // pause / unpause
    // =========================================================================

    function test_pauseVenue_setsInactive() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        VenueData memory v = VenueFacet(address(diamond)).getVenue(venueId);
        assertFalse(v.active);
    }

    function test_pauseVenue_emitsEvent() public {
        uint256 venueId = _createDefaultVenue();

        vm.expectEmit(true, true, false, false);
        emit VenuePaused(venueId, OPERATOR);
        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);
    }

    function test_unpauseVenue_setsActive() public {
        uint256 venueId = _createDefaultVenue();

        vm.startPrank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);
        VenueFacet(address(diamond)).unpauseVenue(venueId);
        vm.stopPrank();

        VenueData memory v = VenueFacet(address(diamond)).getVenue(venueId);
        assertTrue(v.active);
    }

    function test_unpauseVenue_emitsEvent() public {
        uint256 venueId = _createDefaultVenue();

        vm.startPrank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        vm.expectEmit(true, true, false, false);
        emit VenueUnpaused(venueId, OPERATOR);
        VenueFacet(address(diamond)).unpauseVenue(venueId);
        vm.stopPrank();
    }

    function test_pauseVenue_revertsIfNotOperator() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        VenueFacet(address(diamond)).pauseVenue(venueId);
    }

    function test_pauseVenue_revertsOnNonexistent() public {
        vm.prank(OPERATOR);
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        VenueFacet(address(diamond)).pauseVenue(999);
    }

    // =========================================================================
    // getNextVenueId
    // =========================================================================

    function test_getNextVenueId_zeroInitially() public view {
        assertEq(VenueFacet(address(diamond)).getNextVenueId(), 0);
    }

    function test_getNextVenueId_afterCreate() public {
        _createDefaultVenue();
        assertEq(VenueFacet(address(diamond)).getNextVenueId(), 1);
    }

    // =========================================================================
    // canTrade / canCreateMarket
    // =========================================================================

    function test_canTrade_publicVenue_returnsTrue() public {
        uint256 venueId = _createDefaultVenue();
        assertTrue(VenueFacet(address(diamond)).canTrade(ALICE, venueId));
    }

    function test_canCreateMarket_publicVenue_returnsTrue() public {
        uint256 venueId = _createDefaultVenue();
        assertTrue(VenueFacet(address(diamond)).canCreateMarket(ALICE, venueId));
    }

    function test_canTrade_nonexistentVenue_returnsFalse() public view {
        assertFalse(VenueFacet(address(diamond)).canTrade(ALICE, 999));
    }

    function test_canCreateMarket_nonexistentVenue_returnsFalse() public view {
        assertFalse(VenueFacet(address(diamond)).canCreateMarket(ALICE, 999));
    }

    function test_canTrade_pausedVenue_returnsFalse() public {
        uint256 venueId = _createDefaultVenue();

        vm.prank(OPERATOR);
        VenueFacet(address(diamond)).pauseVenue(venueId);

        assertFalse(VenueFacet(address(diamond)).canTrade(ALICE, venueId));
    }

    function test_canTrade_operator_alwaysTrue() public {
        uint256 venueId = _createDefaultVenue();
        assertTrue(VenueFacet(address(diamond)).canTrade(OPERATOR, venueId));
    }

    // =========================================================================
    // getVenue revert on nonexistent
    // =========================================================================

    function test_getVenue_revertsForNonexistent() public {
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        VenueFacet(address(diamond)).getVenue(999);
    }

    function test_getVenueFees_revertsForNonexistent() public {
        vm.expectRevert(LibVenueValidator.VenueNotFound.selector);
        VenueFacet(address(diamond)).getVenueFees(999);
    }
}
