// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {MarketGroupFacet} from "../src/facets/MarketGroupFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {LibProtocolValidator} from "../src/validators/LibProtocolValidator.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @title Protocol facet integration tests
/// @notice Tests ProtocolFacet: treasury management, collateral whitelist, protocol-level configuration.
contract ProtocolFacetTest is Test, DiamondSetup {
    OddMaki public diamond;

    address constant TREASURY = address(0x1234);
    address constant NON_OWNER = address(0xBEEF);

    event ProtocolTreasuryUpdated(address indexed treasury);
    event CollateralWhitelistUpdated(address indexed token, bool whitelisted);

    function setUp() public {
        diamond = deployDiamond(address(this)); // address(this) is owner
    }

    // -------------------------------------------------------------------------
    // setProtocolTreasury
    // -------------------------------------------------------------------------

    function test_setProtocolTreasury_ownerCanSet() public {
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);
        assertEq(ProtocolFacet(address(diamond)).getProtocolTreasury(), TREASURY);
    }

    function test_setProtocolTreasury_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ProtocolTreasuryUpdated(TREASURY);
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);
    }

    function test_setProtocolTreasury_nonOwnerReverts() public {
        vm.prank(NON_OWNER);
        vm.expectRevert();
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY);
    }

    function test_setProtocolTreasury_zeroAddressReverts() public {
        vm.expectRevert("Invalid treasury");
        ProtocolFacet(address(diamond)).setProtocolTreasury(address(0));
    }

    // -------------------------------------------------------------------------
    // getProtocolTreasury
    // -------------------------------------------------------------------------

    function test_getProtocolTreasury_defaultIsZero() public {
        assertEq(ProtocolFacet(address(diamond)).getProtocolTreasury(), address(0));
    }

    // -------------------------------------------------------------------------
    // setCollateralWhitelisted / isCollateralWhitelisted
    // -------------------------------------------------------------------------

    function test_setCollateralWhitelisted_ownerCanWhitelist() public {
        address token = address(0xAAAA);
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(token, true);
        assertTrue(ProtocolFacet(address(diamond)).isCollateralWhitelisted(token));
    }

    function test_setCollateralWhitelisted_ownerCanRemove() public {
        address token = address(0xAAAA);
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(token, true);
        assertTrue(ProtocolFacet(address(diamond)).isCollateralWhitelisted(token));

        ProtocolFacet(address(diamond)).setCollateralWhitelisted(token, false);
        assertFalse(ProtocolFacet(address(diamond)).isCollateralWhitelisted(token));
    }

    function test_setCollateralWhitelisted_nonOwnerReverts() public {
        vm.prank(NON_OWNER);
        vm.expectRevert();
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(0xAAAA), true);
    }

    function test_setCollateralWhitelisted_zeroAddressReverts() public {
        vm.expectRevert("Invalid token");
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(0), true);
    }

    function test_isCollateralWhitelisted_defaultIsFalse() public {
        assertFalse(ProtocolFacet(address(diamond)).isCollateralWhitelisted(address(0xAAAA)));
    }

    function test_setCollateralWhitelisted_emitsEvent() public {
        address token = address(0xAAAA);
        vm.expectEmit(true, false, false, true);
        emit CollateralWhitelistUpdated(token, true);
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(token, true);
    }

    // -------------------------------------------------------------------------
    // Integration: collateral whitelist gates market creation
    // -------------------------------------------------------------------------

    function test_createMarket_revertsIfCollateralNotWhitelisted() public {
        MockCTF ctf = new MockCTF();
        MockERC20 collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        // Do NOT whitelist collateral
        uint256 venueId = createDefaultVenue(address(diamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        collateral.mint(address(this), 100e6);
        collateral.approve(address(diamond), type(uint256).max);

        vm.expectRevert(LibProtocolValidator.CollateralNotWhitelisted.selector);
        MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, 1e16, address(collateral), 0, 0, new bytes32[](0));
    }

    function test_createMarketGroup_revertsIfCollateralNotWhitelisted() public {
        MockCTF ctf = new MockCTF();
        MockERC20 collateral = new MockERC20("Test USDC", "TUSDC", 6);

        VaultFacet(address(diamond)).setCtf(address(ctf));
        // Do NOT whitelist collateral
        uint256 venueId = createDefaultVenue(address(diamond));

        collateral.mint(address(this), 100e6);
        collateral.approve(address(diamond), type(uint256).max);

        vm.expectRevert(LibProtocolValidator.CollateralNotWhitelisted.selector);
        MarketGroupFacet(address(diamond)).createMarketGroup(
            venueId, "Who wins?", "Criteria", address(collateral), 1e16, 0, 0, new bytes32[](0)
        );
    }
}
