// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MarketOrdersFacet} from "../src/facets/MarketOrdersFacet.sol";
import {AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {WhitelistAccessControl} from "../src/access-control/WhitelistAccessControl.sol";
import {NFTGatedAccessControl} from "../src/access-control/NFTGatedAccessControl.sol";
import {TokenGatedAccessControl} from "../src/access-control/TokenGatedAccessControl.sol";
import {LibAccessControlValidator} from "../src/validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../src/validators/LibVenueValidator.sol";
import {Side} from "../src/interfaces/Types.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";

/// @title Access control integration tests
/// @notice Tests venue-level and market-level trading access control with whitelist, NFT-gated,
///         and token-gated access control contracts.
contract AccessControlTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockERC20 public gateToken;

    address constant OPERATOR = address(0xA);
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);
    address constant CHARLIE = address(0x3);

    uint256 constant TICK_SIZE = 1e16;

    function setUp() public {
        diamond = deployDiamond(address(this));
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        gateToken = new MockERC20("Gate Token", "GATE", 18);
        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
    }

    // ============================
    // Factory tests
    // ============================

    function test_deployWhitelistAC() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployWhitelistAC();
        assertTrue(ac != address(0));
        WhitelistAccessControl wac = WhitelistAccessControl(ac);
        assertEq(wac.owner(), OPERATOR);
        assertFalse(wac.isAllowed(ALICE));
    }

    function test_deployNFTGatedAC() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployNFTGatedAC(address(gateToken), false, 0);
        assertTrue(ac != address(0));
        NFTGatedAccessControl nac = NFTGatedAccessControl(ac);
        assertEq(nac.nftContract(), address(gateToken));
        assertFalse(nac.isERC1155());
    }

    function test_deployTokenGatedAC() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployTokenGatedAC(address(gateToken), 100e18);
        assertTrue(ac != address(0));
        TokenGatedAccessControl tac = TokenGatedAccessControl(ac);
        assertEq(tac.token(), address(gateToken));
        assertEq(tac.minBalance(), 100e18);
    }

    // ============================
    // WhitelistAccessControl tests
    // ============================

    function test_whitelist_addAndRemove() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployWhitelistAC();
        WhitelistAccessControl wac = WhitelistAccessControl(ac);

        address[] memory users = new address[](2);
        users[0] = ALICE;
        users[1] = BOB;

        vm.prank(OPERATOR);
        wac.addToWhitelist(users);
        assertTrue(wac.isAllowed(ALICE));
        assertTrue(wac.isAllowed(BOB));
        assertFalse(wac.isAllowed(CHARLIE));

        address[] memory removeUsers = new address[](1);
        removeUsers[0] = ALICE;
        vm.prank(OPERATOR);
        wac.removeFromWhitelist(removeUsers);
        assertFalse(wac.isAllowed(ALICE));
        assertTrue(wac.isAllowed(BOB));
    }

    function test_whitelist_onlyOwnerCanManage() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployWhitelistAC();
        WhitelistAccessControl wac = WhitelistAccessControl(ac);

        address[] memory users = new address[](1);
        users[0] = ALICE;

        vm.prank(ALICE);
        vm.expectRevert(WhitelistAccessControl.OnlyOwner.selector);
        wac.addToWhitelist(users);
    }

    // ============================
    // TokenGatedAccessControl tests
    // ============================

    function test_tokenGated_allowsWithSufficientBalance() public {
        vm.prank(OPERATOR);
        address ac = AccessControlFacet(address(diamond)).deployTokenGatedAC(address(gateToken), 100e18);
        TokenGatedAccessControl tac = TokenGatedAccessControl(ac);

        assertFalse(tac.isAllowed(ALICE));

        gateToken.mint(ALICE, 100e18);
        assertTrue(tac.isAllowed(ALICE));

        gateToken.mint(BOB, 50e18);
        assertFalse(tac.isAllowed(BOB));
    }

    // ============================
    // Trading enforcement (limit orders)
    // ============================

    function test_limitOrder_publicVenue_anyoneCanTrade() public {
        (uint256 venueId, uint256 marketId) = _createPublicVenueAndMarket();
        _fundForOrder(ALICE);

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
        assertEq(orderId, 1);
    }

    function test_limitOrder_venueTradingAC_deniesUnlisted() public {
        // Create venue with whitelist trading AC
        address wac = _deployAndConfigureWhitelist(OPERATOR, new address[](0));
        uint256 venueId = _createVenueWithAC(OPERATOR, wac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        _fundForOrder(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(LibAccessControlValidator.TradingAccessDenied.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
    }

    function test_limitOrder_venueTradingAC_allowsWhitelisted() public {
        address[] memory allowed = new address[](1);
        allowed[0] = ALICE;
        address wac = _deployAndConfigureWhitelist(OPERATOR, allowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, wac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        _fundForOrder(ALICE);

        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
        assertEq(orderId, 1);
    }

    function test_limitOrder_operatorBypass() public {
        address wac = _deployAndConfigureWhitelist(OPERATOR, new address[](0));
        uint256 venueId = _createVenueWithAC(OPERATOR, wac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        _fundForOrder(OPERATOR);

        // Operator can trade even though not on whitelist
        vm.prank(OPERATOR);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
        assertEq(orderId, 1);
    }

    // ============================
    // Market-level AC override
    // ============================

    function test_marketLevelAC_overridesVenueLevel() public {
        // Venue-level: whitelist with ALICE
        address[] memory venueAllowed = new address[](1);
        venueAllowed[0] = ALICE;
        address venueWac = _deployAndConfigureWhitelist(OPERATOR, venueAllowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, venueWac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        // Market-level: whitelist with BOB only
        address[] memory marketAllowed = new address[](1);
        marketAllowed[0] = BOB;
        address marketWac = _deployAndConfigureWhitelist(OPERATOR, marketAllowed);

        vm.prank(OPERATOR);
        AccessControlFacet(address(diamond)).setMarketTradingAccessControl(marketId, marketWac);

        // ALICE is on venue whitelist but NOT on market whitelist → denied
        _fundForOrder(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(LibAccessControlValidator.TradingAccessDenied.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);

        // BOB is on market whitelist → allowed
        _fundForOrder(BOB);
        vm.prank(BOB);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
        assertEq(orderId, 1);
    }

    function test_removeMarketAC_fallsBackToVenue() public {
        // Venue-level: whitelist with ALICE
        address[] memory venueAllowed = new address[](1);
        venueAllowed[0] = ALICE;
        address venueWac = _deployAndConfigureWhitelist(OPERATOR, venueAllowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, venueWac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        // Set market-level AC (whitelist with nobody)
        address marketWac = _deployAndConfigureWhitelist(OPERATOR, new address[](0));
        vm.prank(OPERATOR);
        AccessControlFacet(address(diamond)).setMarketTradingAccessControl(marketId, marketWac);

        // ALICE denied (market-level blocks)
        _fundForOrder(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(LibAccessControlValidator.TradingAccessDenied.selector);
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);

        // Remove market-level AC
        vm.prank(OPERATOR);
        AccessControlFacet(address(diamond)).removeMarketTradingAccessControl(marketId);

        // Now falls back to venue-level → ALICE is allowed
        vm.prank(ALICE);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.BUY, 50, 100e18, 0);
        assertEq(orderId, 1);
    }

    // ============================
    // Market-level config validation
    // ============================

    function test_setMarketAC_onlyVenueOperator() public {
        (uint256 venueId, uint256 marketId) = _createPublicVenueWithOperator(OPERATOR);
        address wac = _deployAndConfigureWhitelist(OPERATOR, new address[](0));

        vm.prank(ALICE);
        vm.expectRevert(LibVenueValidator.OnlyVenueOperator.selector);
        AccessControlFacet(address(diamond)).setMarketTradingAccessControl(marketId, wac);
    }

    // ============================
    // Creation access enforcement
    // ============================

    function test_creationAC_deniesUnlisted() public {
        address wac = _deployAndConfigureWhitelist(OPERATOR, new address[](0));
        uint256 venueId = _createVenueWithAC(OPERATOR, address(0), wac);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        collateral.mint(ALICE, 100e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);

        vm.prank(ALICE);
        vm.expectRevert(LibAccessControlValidator.CreationAccessDenied.selector);
        MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));
    }

    function test_creationAC_allowsWhitelisted() public {
        address[] memory allowed = new address[](1);
        allowed[0] = ALICE;
        address wac = _deployAndConfigureWhitelist(OPERATOR, allowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, address(0), wac);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        collateral.mint(ALICE, 100e6);
        vm.prank(ALICE);
        collateral.approve(address(diamond), type(uint256).max);

        vm.prank(ALICE);
        uint256 marketId = MarketsFacet(address(diamond)).createMarket(venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0));
        assertEq(marketId, 1);
    }

    // ============================
    // canTradeOnMarket view
    // ============================

    function test_canTradeOnMarket_returnsCorrectly() public {
        address[] memory allowed = new address[](1);
        allowed[0] = ALICE;
        address wac = _deployAndConfigureWhitelist(OPERATOR, allowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, wac, address(0));
        uint256 marketId = _createMarketInVenue(venueId);

        assertTrue(AccessControlFacet(address(diamond)).canTradeOnMarket(ALICE, marketId));
        assertFalse(AccessControlFacet(address(diamond)).canTradeOnMarket(BOB, marketId));
        // Operator always true
        assertTrue(AccessControlFacet(address(diamond)).canTradeOnMarket(OPERATOR, marketId));
    }

    // ============================
    // VenueFacet canTrade/canCreateMarket views
    // ============================

    function test_venueFacet_canTrade_withAC() public {
        address[] memory allowed = new address[](1);
        allowed[0] = ALICE;
        address wac = _deployAndConfigureWhitelist(OPERATOR, allowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, wac, address(0));

        assertTrue(VenueFacet(address(diamond)).canTrade(ALICE, venueId));
        assertFalse(VenueFacet(address(diamond)).canTrade(BOB, venueId));
        assertTrue(VenueFacet(address(diamond)).canTrade(OPERATOR, venueId));
    }

    function test_venueFacet_canCreateMarket_withAC() public {
        address[] memory allowed = new address[](1);
        allowed[0] = ALICE;
        address wac = _deployAndConfigureWhitelist(OPERATOR, allowed);
        uint256 venueId = _createVenueWithAC(OPERATOR, address(0), wac);

        assertTrue(VenueFacet(address(diamond)).canCreateMarket(ALICE, venueId));
        assertFalse(VenueFacet(address(diamond)).canCreateMarket(BOB, venueId));
        assertTrue(VenueFacet(address(diamond)).canCreateMarket(OPERATOR, venueId));
    }

    // ============================
    // Helpers
    // ============================

    function _createPublicVenueAndMarket() internal returns (uint256 venueId, uint256 marketId) {
        venueId = createDefaultVenue(address(diamond));
        marketId = _createMarketInVenue(venueId);
    }

    function _createPublicVenueWithOperator(address operator) internal returns (uint256 venueId, uint256 marketId) {
        vm.prank(operator);
        venueId = VenueFacet(address(diamond)).createVenue(
            "Test Venue", "", address(0), address(0), operator, 100, 0, TICK_SIZE, 5e6, 0, 0
        );
        marketId = _createMarketInVenue(venueId);
    }

    function _createVenueWithAC(address operator, address tradingAC, address creationAC) internal returns (uint256 venueId) {
        vm.prank(operator);
        venueId = VenueFacet(address(diamond)).createVenue(
            "AC Venue", "", tradingAC, creationAC, operator, 100, 0, TICK_SIZE, 5e6, 0, 0
        );
    }

    function _createMarketInVenue(uint256 venueId) internal returns (uint256 marketId) {
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        collateral.mint(address(this), 100e6);
        collateral.approve(address(diamond), type(uint256).max);

        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );
    }

    function _deployAndConfigureWhitelist(address owner, address[] memory users) internal returns (address wac) {
        vm.prank(owner);
        wac = AccessControlFacet(address(diamond)).deployWhitelistAC();
        if (users.length > 0) {
            vm.prank(owner);
            WhitelistAccessControl(wac).addToWhitelist(users);
        }
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(diamond), type(uint256).max);
    }

    function _fundForOrder(address user) internal {
        // tick=50, qty=100e18, tickSize=1e16 → collateral = (50 * 100e18 * 1e16) / 1e18 = 50e18
        uint256 collateralAmount = 50e18;
        collateral.mint(user, collateralAmount);
        vm.prank(user);
        collateral.approve(address(diamond), type(uint256).max);
    }
}
