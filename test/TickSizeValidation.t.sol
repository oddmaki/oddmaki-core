// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {LibTickSizeValidator} from "../src/validators/LibTickSizeValidator.sol";

contract TickSizeValidationTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    uint256 public venueId;

    address constant CREATOR = address(0xC8EA);

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        venueId = createDefaultVenue(address(diamond));
    }

    // ---- Market creation: valid tickSizes ----

    function test_createMarket_standardTickSize() public {
        vm.prank(CREATOR);
        uint256 marketId = MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                1e16,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
        assertGt(marketId, 0);
    }

    function test_createMarket_fineTickSize() public {
        vm.prank(CREATOR);
        uint256 marketId = MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                1e15,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
        assertGt(marketId, 0);
    }

    // ---- Market creation: invalid tickSizes ----

    function test_createMarket_revert_tickSizeZero() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                0,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
    }

    function test_createMarket_revert_tickSizeTooLarge() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                1e17,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
    }

    function test_createMarket_revert_tickSizeNotWhitelisted() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                5e15,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
    }

    function test_createMarket_revert_tickSizeOne() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                1,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
    }

    function test_createMarket_revert_tickSize1e18() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketsFacet(address(diamond))
            .createMarket(
                venueId,
                abi.encode("Will it rain?", "Resolution: yes or no"),
                _outcomes(),
                1e18,
                address(collateral),
                0,
                0,
                new bytes32[](0)
            );
    }

    // ---- Market group creation: invalid tickSize ----

    function test_createMarketGroup_revert_invalidTickSize() public {
        vm.prank(CREATOR);
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        MarketGroupFacet(address(diamond))
            .createMarketGroup(
                venueId, "Who will win?", "Resolution criteria", address(collateral), 1e17, 0, 0, new bytes32[](0)
            );
    }

    function test_createMarketGroup_validTickSize() public {
        vm.prank(CREATOR);
        uint256 groupId = MarketGroupFacet(address(diamond))
            .createMarketGroup(
                venueId, "Who will win?", "Resolution criteria", address(collateral), 1e16, 0, 0, new bytes32[](0)
            );
        assertGt(groupId, 0);
    }

    // ---- Venue creation: invalid defaultTickSize ----

    function test_createVenue_revert_invalidDefaultTickSize() public {
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        VenueFacet(address(diamond))
            .createVenue("Bad Venue", "", address(0), address(0), address(this), 100, 0, 1e17, 5e6, 0, 1e6);
    }

    function test_createVenue_revert_zeroDefaultTickSize() public {
        vm.expectRevert(LibTickSizeValidator.InvalidTickSize.selector);
        VenueFacet(address(diamond))
            .createVenue("Bad Venue", "", address(0), address(0), address(this), 100, 0, 0, 5e6, 0, 1e6);
    }

    // ---- Helpers ----

    function _outcomes() internal pure returns (string[] memory) {
        string[] memory o = new string[](2);
        o[0] = "Yes";
        o[1] = "No";
        return o;
    }
}
