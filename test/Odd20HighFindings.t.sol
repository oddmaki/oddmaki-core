// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {LimitOrdersFacet} from "../src/facets/LimitOrdersFacet.sol";
import {MatchingFacet} from "../src/facets/MatchingFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {PythResolutionFacet} from "../src/facets/PythResolutionFacet.sol";
import {LibResolutionValidator} from "../src/validators/LibResolutionValidator.sol";
import {LibErc1155ReceiverValidator} from "../src/validators/LibErc1155ReceiverValidator.sol";
import {MarketRegistryData, Side} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {IERC1155Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

/// @dev Contract that does not support ERC-1155 reception (no ERC-165 hook).
contract NonReceiver {}

/// @dev Contract with ERC-165 support but does not advertise IERC1155Receiver.
contract Erc165NoReceiver is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/// @dev Contract that advertises IERC1155Receiver via ERC-165.
contract ValidReceiver is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

/**
 * @title ODD-20 High Findings Regression Tests
 * @notice Per-finding regression tests for H-01, H-03, H-05, H-06.
 *         Each test captures the invariant introduced by its fix and would fail
 *         on the pre-fix code path.
 */
contract Odd20HighFindingsTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockUmaOracle public umaOracle;

    uint256 public venueId;
    uint256 public marketId;
    uint256[2] public positionIds;

    uint256 constant TICK_SIZE = 1e16;
    bytes32 constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    address constant OWNER = address(0x0DD1);
    address constant CREATOR = address(0xC8EA);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant OPERATOR = address(0x0FE8A70E);

    // H-01: fee recipients we will rotate mid-lifecycle.
    address constant VENUE_RECIPIENT_V1 = address(0xFEE1);
    address constant VENUE_RECIPIENT_V2 = address(0xFEE2);
    address constant TREASURY_V1 = address(0x7EA51);
    address constant TREASURY_V2 = address(0x7EA52);

    uint256 constant VENUE_FEE_BPS = 100;
    uint256 constant CREATOR_FEE_BPS = 30;
    uint256 constant PROTOCOL_FEE_BPS = 50;

    function setUp() public {
        diamond = deployDiamond(OWNER);
        ctf = new MockCTF();
        collateral = new MockERC20("Test USDC", "TUSDC", 6);
        umaOracle = new MockUmaOracle();

        vm.startPrank(OWNER);
        VaultFacet(address(diamond)).setCtf(address(ctf));
        ProtocolFacet(address(diamond)).setCollateralWhitelisted(address(collateral), true);
        ProtocolFacet(address(diamond)).setUmaOracle(address(umaOracle));
        ProtocolFacet(address(diamond)).setUmaIdentifier(UMA_IDENTIFIER);
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY_V1);
        ProtocolFacet(address(diamond)).setProtocolFeeBps(PROTOCOL_FEE_BPS);
        vm.stopPrank();
    }

    // =========================================================================
    // H-01: fee recipients snapshotted at market creation
    // =========================================================================

    /// @notice Resting SELL order placed under venueRecipientV1. After the venue's
    ///         feeRecipient is rotated and the protocol treasury is rotated, a fill
    ///         must still pay the originally-snapshotted recipients. Pre-fix, fees
    ///         followed the live pointers and would leak to V2.
    function test_h01_rotatingRecipientsDoesNotRedirectSnapshottedFees() public {
        vm.prank(CREATOR);
        uint256 vid = VenueFacet(address(diamond)).createVenue(
            "Fee Snap Venue",
            "",
            address(0),
            address(0),
            VENUE_RECIPIENT_V1,
            VENUE_FEE_BPS,
            CREATOR_FEE_BPS,
            TICK_SIZE,
            5e6,
            0,
            1e6
        );

        // Pay creation fee
        collateral.mint(CREATOR, 5e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), 5e6);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        uint256 mid = MarketsFacet(address(diamond)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        // Place resting SELL (BOB) priced against the snapshotted fee structure.
        uint256 tick = 60;
        uint256 qty = 100e18;
        uint256 col = (tick * qty * TICK_SIZE) / 1e18;

        collateral.mint(BOB, qty);
        vm.startPrank(BOB);
        collateral.approve(address(diamond), qty);
        VaultFacet(address(diamond)).splitPosition(mid, qty);
        ctf.setApprovalForAll(address(diamond), true);
        LimitOrdersFacet(address(diamond)).placeOrder(mid, 0, Side.SELL, tick, qty, 0);
        vm.stopPrank();

        // Now the venue operator rotates the fee recipient and the owner rotates the treasury.
        vm.prank(CREATOR);
        VenueFacet(address(diamond)).updateVenue(vid, "Fee Snap Venue", "", address(0), address(0), VENUE_RECIPIENT_V2);
        vm.prank(OWNER);
        ProtocolFacet(address(diamond)).setProtocolTreasury(TREASURY_V2);

        // Crossing BUY fills against the resting sell.
        collateral.mint(ALICE, col);
        vm.prank(ALICE);
        collateral.approve(address(diamond), col);
        vm.prank(ALICE);
        LimitOrdersFacet(address(diamond)).placeOrder(mid, 0, Side.BUY, tick, qty, 0);

        uint256 treasuryV1Before = collateral.balanceOf(TREASURY_V1);
        uint256 venueV1Before = collateral.balanceOf(VENUE_RECIPIENT_V1);
        uint256 treasuryV2Before = collateral.balanceOf(TREASURY_V2);
        uint256 venueV2Before = collateral.balanceOf(VENUE_RECIPIENT_V2);

        vm.prank(OPERATOR);
        MatchingFacet(address(diamond)).matchOrders(mid, 10);

        // Fees must be paid to the snapshotted recipients (V1), not the live ones (V2).
        assertGt(collateral.balanceOf(TREASURY_V1), treasuryV1Before, "protocol fee must go to snapshotted treasury");
        assertGt(
            collateral.balanceOf(VENUE_RECIPIENT_V1),
            venueV1Before,
            "venue fee must go to snapshotted recipient"
        );
        assertEq(
            collateral.balanceOf(TREASURY_V2),
            treasuryV2Before,
            "rotated treasury must not receive fees from pre-rotation market"
        );
        assertEq(
            collateral.balanceOf(VENUE_RECIPIENT_V2),
            venueV2Before,
            "rotated venue recipient must not receive fees from pre-rotation market"
        );
    }

    // =========================================================================
    // H-03: UMA resolution blocked once market already Resolved
    // =========================================================================

    /// @notice A market resolved via one path (simulated by forcibly moving it to
    ///         Resolved via UMA settlement) must reject subsequent UMA entry points.
    function test_h03_umaAssertionBlockedOnResolvedMarket() public {
        bytes32 questionId = _createUmaMarketAndResolve();

        // After the market is resolved, a fresh UMA assertion must revert.
        collateral.mint(ALICE, 1e18);
        vm.prank(ALICE);
        collateral.approve(address(diamond), 1e18);

        vm.expectRevert(LibResolutionValidator.MarketNotActive.selector);
        vm.prank(ALICE);
        ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "No");
    }

    /// @notice settleAssertion on a pre-existing assertion must revert once the linked
    ///         market has been moved to Resolved via another path.
    function test_h03_settleAssertionBlockedOnResolvedMarket() public {
        // Create a fresh market and open an UMA assertion (unsettled).
        _createDefaultVenue();
        bytes32 qid = _createMarket();

        collateral.mint(ALICE, 1e18);
        vm.prank(ALICE);
        collateral.approve(address(diamond), 1e18);
        vm.prank(ALICE);
        bytes32 assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(qid, "Yes");

        // Force the market to Resolved by going through the full lifecycle
        // with a different assertion path (simulated: settle+report).
        // Instead, manipulate directly: settle current, then report to move to Resolved.
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        // Any later settleAssertion attempt referencing this assertion must revert.
        vm.expectRevert(LibResolutionValidator.MarketNotActive.selector);
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
    }

    // =========================================================================
    // H-05: ERC-1155 receiver gating on SELL placement
    // =========================================================================

    /// @notice EOA sellers are accepted as makers without ERC-165 probing.
    function test_h05_eoaSellerAccepted() public {
        _createDefaultVenue();
        _createMarket();
        uint256 qty = 10e18;

        collateral.mint(BOB, qty);
        vm.startPrank(BOB);
        collateral.approve(address(diamond), qty);
        VaultFacet(address(diamond)).splitPosition(marketId, qty);
        ctf.setApprovalForAll(address(diamond), true);
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 50, qty, 0);
        vm.stopPrank();

        assertGt(orderId, 0, "EOA SELL should succeed");
    }

    /// @notice A contract without any ERC-165 hook reverts with MakerErc165CallFailed
    ///         (the static call fails and is caught by the validator).
    function test_h05_nonReceiverContractReverts() public {
        _createDefaultVenue();
        _createMarket();

        NonReceiver nr = new NonReceiver();
        uint256 qty = 10e18;

        // Fund the contract and deposit outcome tokens for it via direct mint.
        ctf.mintPositionTokens(address(nr), positionIds[0], qty);

        vm.prank(address(nr));
        ctf.setApprovalForAll(address(diamond), true);

        vm.expectRevert(LibErc1155ReceiverValidator.MakerErc165CallFailed.selector);
        vm.prank(address(nr));
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 50, qty, 0);
    }

    /// @notice A contract that implements ERC-165 but does not advertise IERC1155Receiver
    ///         reverts with MakerNotErc1155Receiver.
    function test_h05_erc165WithoutReceiverReverts() public {
        _createDefaultVenue();
        _createMarket();

        Erc165NoReceiver nr = new Erc165NoReceiver();
        uint256 qty = 10e18;

        ctf.mintPositionTokens(address(nr), positionIds[0], qty);
        vm.prank(address(nr));
        ctf.setApprovalForAll(address(diamond), true);

        vm.expectRevert(LibErc1155ReceiverValidator.MakerNotErc1155Receiver.selector);
        vm.prank(address(nr));
        LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 50, qty, 0);
    }

    /// @notice A contract that advertises IERC1155Receiver via ERC-165 is accepted.
    function test_h05_validReceiverContractAccepted() public {
        _createDefaultVenue();
        _createMarket();

        ValidReceiver vr = new ValidReceiver();
        uint256 qty = 10e18;

        ctf.mintPositionTokens(address(vr), positionIds[0], qty);
        vm.prank(address(vr));
        ctf.setApprovalForAll(address(diamond), true);

        vm.prank(address(vr));
        uint256 orderId = LimitOrdersFacet(address(diamond)).placeOrder(marketId, 0, Side.SELL, 50, qty, 0);
        assertGt(orderId, 0, "ERC-1155 receiver contract SELL should succeed");
    }

    // =========================================================================
    // H-06: setCtf is immutable after first successful call
    // =========================================================================

    function test_h06_setCtfSucceedsOnce() public {
        OddMaki fresh = deployDiamond(OWNER);
        address firstCtf = address(new MockCTF());

        vm.prank(OWNER);
        VaultFacet(address(fresh)).setCtf(firstCtf);

        assertEq(VaultFacet(address(fresh)).getCtfAddress(), firstCtf);
    }

    function test_h06_setCtfRevertsOnSecondCall() public {
        OddMaki fresh = deployDiamond(OWNER);
        address firstCtf = address(new MockCTF());
        address secondCtf = address(new MockCTF());

        vm.prank(OWNER);
        VaultFacet(address(fresh)).setCtf(firstCtf);

        vm.expectRevert(bytes("ctf already set"));
        vm.prank(OWNER);
        VaultFacet(address(fresh)).setCtf(secondCtf);

        assertEq(VaultFacet(address(fresh)).getCtfAddress(), firstCtf, "first CTF must remain");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createDefaultVenue() internal {
        vm.prank(CREATOR);
        venueId = VenueFacet(address(diamond)).createVenue(
            "Venue",
            "",
            address(0),
            address(0),
            VENUE_RECIPIENT_V1,
            VENUE_FEE_BPS,
            CREATOR_FEE_BPS,
            TICK_SIZE,
            5e6,
            0,
            1e6
        );
    }

    function _createMarket() internal returns (bytes32 questionId) {
        // Pay creation fee from CREATOR
        collateral.mint(CREATOR, 5e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), 5e6);

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        questionId = reg.questionId;

        positionIds[0] = MarketsFacet(address(diamond)).getMarketTradingData(marketId).positionIds[0];
        positionIds[1] = MarketsFacet(address(diamond)).getMarketTradingData(marketId).positionIds[1];
    }

    function _createUmaMarketAndResolve() internal returns (bytes32 questionId) {
        _createDefaultVenue();
        questionId = _createMarket();

        collateral.mint(ALICE, 1e18);
        vm.prank(ALICE);
        collateral.approve(address(diamond), 1e18);

        vm.prank(ALICE);
        bytes32 assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "Yes");
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");
    }
}
