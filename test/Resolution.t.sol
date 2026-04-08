// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {VenueFacet} from "../src/facets/VenueFacet.sol";
import {MarketsFacet} from "../src/facets/MarketsFacet.sol";
import {ProtocolFacet} from "../src/facets/ProtocolFacet.sol";
import {ResolutionFacet} from "../src/facets/ResolutionFacet.sol";
import {LibResolutionValidator} from "../src/validators/LibResolutionValidator.sol";
import {MarketRegistryData, MarketTradingData, MarketOracleData, AssertionData, MarketStatus} from "../src/interfaces/Types.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";
import {MockCTF} from "./helpers/MockCTF.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {MockUmaOracle} from "./helpers/MockUmaOracle.sol";

/// @title Resolution integration tests
/// @notice Tests the full UMA resolution lifecycle: assert outcome, settle assertion,
///         report resolution, and payout redemption.
contract ResolutionTest is Test, DiamondSetup {
    OddMaki public diamond;
    MockCTF public ctf;
    MockERC20 public collateral;
    MockUmaOracle public umaOracle;
    uint256 public venueId;
    uint256 public marketId;
    bytes32 public questionId;

    address constant CREATOR = address(0xC8EA);
    address constant ASSERTER = address(0xA553E7);
    address constant ALICE = address(0xA11CE);
    uint256 constant TICK_SIZE = 1e16;
    bytes32 constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    // Events
    event AssertionCreated(bytes32 indexed assertionId, bytes32 indexed questionId, string outcome, address asserter);
    event AssertionSettled(bytes32 indexed assertionId, bool result);
    event MarketResolved(uint256 indexed marketId, bytes32 indexed questionId, string outcome);
    event AssertionDisputed(bytes32 indexed assertionId);

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

        // Create a market
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        marketId = MarketsFacet(address(diamond)).createMarket(
            venueId, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        questionId = reg.questionId;
    }

    // ---- Helpers ----

    function _fundAndApproveAsserter(uint256 amount) internal {
        collateral.mint(ASSERTER, amount);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), amount);
    }

    function _assertOutcome(string memory outcome) internal returns (bytes32) {
        _fundAndApproveAsserter(1e18);
        vm.prank(ASSERTER);
        return ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, outcome);
    }

    function _assertAndSettle(string memory outcome) internal returns (bytes32 assertionId) {
        assertionId = _assertOutcome(outcome);
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);
    }

    // =========================================================================
    // assertMarketOutcome
    // =========================================================================

    function test_assertMarketOutcome_returnsAssertionId() public {
        bytes32 assertionId = _assertOutcome("Yes");
        assertTrue(assertionId != bytes32(0));
    }

    function test_assertMarketOutcome_storesAssertionData() public {
        bytes32 assertionId = _assertOutcome("Yes");

        AssertionData memory data = ResolutionFacet(address(diamond)).getAssertionData(assertionId);
        assertEq(data.assertionId, assertionId);
        assertEq(data.questionId, questionId);
        assertEq(keccak256(bytes(data.outcome)), keccak256(bytes("Yes")));
        assertFalse(data.settled);
    }

    function test_assertMarketOutcome_locksQuestion() public {
        _assertOutcome("Yes");

        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertTrue(oracle.activeAssertionId != bytes32(0));
    }

    function test_assertMarketOutcome_pullsBondFromAsserter() public {
        uint256 bondAmount = 100e6;
        collateral.mint(ASSERTER, bondAmount);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), bondAmount);

        uint256 balBefore = collateral.balanceOf(ASSERTER);
        vm.prank(ASSERTER);
        ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "Yes");

        // Bond was pulled (requiredBond = 1e6 from default venue, effective bond = max(1e6, minimumBond=0) = 1e6)
        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(collateral.balanceOf(ASSERTER), balBefore - oracle.requiredBond);
    }

    function test_assertMarketOutcome_emitsEvent() public {
        _fundAndApproveAsserter(1e18);
        vm.prank(ASSERTER);
        vm.expectEmit(false, true, false, true);
        emit AssertionCreated(bytes32(0), questionId, "Yes", ASSERTER);
        ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "Yes");
    }

    function test_assertMarketOutcome_revertsIfOracleNotInitialized() public {
        bytes32 fakeQuestionId = bytes32(uint256(999));
        vm.expectRevert(LibResolutionValidator.OracleNotInitialized.selector);
        vm.prank(ASSERTER);
        ResolutionFacet(address(diamond)).assertMarketOutcome(fakeQuestionId, "Yes");
    }

    function test_assertMarketOutcome_revertsIfAssertionAlreadyActive() public {
        _assertOutcome("Yes");

        _fundAndApproveAsserter(1e18);
        vm.expectRevert(LibResolutionValidator.AssertionActiveOrResolved.selector);
        vm.prank(ASSERTER);
        ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "No");
    }

    function test_assertMarketOutcome_revertsIfUmaNotConfigured() public {
        // Deploy a fresh diamond without UMA config
        OddMaki freshDiamond = deployDiamond(address(this));
        MockCTF freshCtf = new MockCTF();
        VaultFacet(address(freshDiamond)).setCtf(address(freshCtf));
        ProtocolFacet(address(freshDiamond)).setCollateralWhitelisted(address(collateral), true);
        uint256 vid = createDefaultVenue(address(freshDiamond));

        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        uint256 mid = MarketsFacet(address(freshDiamond)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketRegistryData memory reg = MarketsFacet(address(freshDiamond)).getMarketRegistryData(mid);

        vm.expectRevert(LibResolutionValidator.UmaOracleNotSet.selector);
        vm.prank(ASSERTER);
        ResolutionFacet(address(freshDiamond)).assertMarketOutcome(reg.questionId, "Yes");
    }

    // =========================================================================
    // settleAssertion
    // =========================================================================

    function test_settleAssertion_settlesViaUma() public {
        bytes32 assertionId = _assertOutcome("Yes");

        ResolutionFacet(address(diamond)).settleAssertion(assertionId);

        AssertionData memory data = ResolutionFacet(address(diamond)).getAssertionData(assertionId);
        assertTrue(data.settled);
    }

    function test_settleAssertion_revertsIfNotFound() public {
        bytes32 fakeId = bytes32(uint256(999));
        vm.expectRevert(LibResolutionValidator.AssertionNotFound.selector);
        ResolutionFacet(address(diamond)).settleAssertion(fakeId);
    }

    // =========================================================================
    // reportResolution — Yes wins
    // =========================================================================

    function test_reportResolution_yesWins_reportsToCTF() public {
        bytes32 assertionId = _assertAndSettle("Yes");

        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        assertTrue(ctf.payoutsReported(questionId));
        uint256[] memory payouts = ctf.getReportedPayouts(questionId);
        assertEq(payouts.length, 2);
        assertEq(payouts[0], 1); // Yes wins
        assertEq(payouts[1], 0);
    }

    function test_reportResolution_yesWins_setsMarketResolved() public {
        _assertAndSettle("Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertTrue(reg.status == MarketStatus.Resolved);
    }

    function test_reportResolution_yesWins_disablesTrading() public {
        _assertAndSettle("Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertFalse(td.active);
    }

    function test_reportResolution_yesWins_emitsEvent() public {
        _assertAndSettle("Yes");

        vm.expectEmit(true, true, false, true);
        emit MarketResolved(marketId, questionId, "Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");
    }

    // =========================================================================
    // reportResolution — No wins
    // =========================================================================

    function test_reportResolution_noWins_reportsToCTF() public {
        _assertAndSettle("No");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "No");

        uint256[] memory payouts = ctf.getReportedPayouts(questionId);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1); // No wins
    }

    // =========================================================================
    // reportResolution — Invalid outcome (split payouts)
    // =========================================================================

    function test_reportResolution_invalidOutcome_splitPayouts() public {
        _assertAndSettle("Invalid");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Invalid");

        uint256[] memory payouts = ctf.getReportedPayouts(questionId);
        assertEq(payouts[0], 1); // Split
        assertEq(payouts[1], 1); // Split
    }

    function test_reportResolution_invalidOutcome_stillResolvesMarket() public {
        _assertAndSettle("Invalid");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Invalid");

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertTrue(reg.status == MarketStatus.Resolved);
    }

    // =========================================================================
    // reportResolution — revert cases
    // =========================================================================

    function test_reportResolution_revertsIfMarketNotActive() public {
        _assertAndSettle("Yes");
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        // Try to resolve again
        vm.expectRevert(LibResolutionValidator.MarketNotActive.selector);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");
    }

    function test_reportResolution_revertsIfAssertionNotSettled() public {
        _assertOutcome("Yes");

        // Try to report without settling
        vm.expectRevert(LibResolutionValidator.AssertionNotSettled.selector);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");
    }

    function test_reportResolution_revertsIfOutcomeMismatch() public {
        _assertAndSettle("Yes");

        vm.expectRevert(LibResolutionValidator.OutcomeMismatch.selector);
        ResolutionFacet(address(diamond)).reportResolution(marketId, "No");
    }

    function test_reportResolution_revertsIfMarketNotFound() public {
        vm.expectRevert(LibResolutionValidator.MarketNotFound.selector);
        ResolutionFacet(address(diamond)).reportResolution(999, "Yes");
    }

    // =========================================================================
    // UMA Callbacks
    // =========================================================================

    function test_assertionResolvedCallback_truthful_keepsLocked() public {
        bytes32 assertionId = _assertOutcome("Yes");

        // UMA resolves truthfully
        vm.prank(address(umaOracle));
        ResolutionFacet(address(diamond)).assertionResolvedCallback(assertionId, true);

        // Assertion is settled
        AssertionData memory data = ResolutionFacet(address(diamond)).getAssertionData(assertionId);
        assertTrue(data.settled);

        // Question still locked
        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(oracle.activeAssertionId, assertionId);
    }

    function test_assertionResolvedCallback_notTruthful_resetsAssertion() public {
        bytes32 assertionId = _assertOutcome("Yes");

        // UMA resolves NOT truthfully
        vm.prank(address(umaOracle));
        ResolutionFacet(address(diamond)).assertionResolvedCallback(assertionId, false);

        // Question unlocked — can assert again
        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(oracle.activeAssertionId, bytes32(0));
    }

    function test_assertionResolvedCallback_afterReset_canAssertAgain() public {
        bytes32 firstId = _assertOutcome("Yes");

        // First assertion fails
        vm.prank(address(umaOracle));
        ResolutionFacet(address(diamond)).assertionResolvedCallback(firstId, false);

        // Can assert again
        bytes32 secondId = _assertOutcome("No");
        assertTrue(secondId != firstId);
    }

    function test_assertionResolvedCallback_revertsIfNotUmaOracle() public {
        bytes32 assertionId = _assertOutcome("Yes");

        vm.expectRevert(LibResolutionValidator.OnlyUmaOracle.selector);
        vm.prank(ALICE);
        ResolutionFacet(address(diamond)).assertionResolvedCallback(assertionId, true);
    }

    function test_assertionDisputedCallback_emitsEvent() public {
        bytes32 assertionId = _assertOutcome("Yes");

        vm.expectEmit(true, false, false, false);
        emit AssertionDisputed(assertionId);
        vm.prank(address(umaOracle));
        ResolutionFacet(address(diamond)).assertionDisputedCallback(assertionId);
    }

    function test_assertionDisputedCallback_revertsIfNotUmaOracle() public {
        bytes32 assertionId = _assertOutcome("Yes");

        vm.expectRevert(LibResolutionValidator.OnlyUmaOracle.selector);
        vm.prank(ALICE);
        ResolutionFacet(address(diamond)).assertionDisputedCallback(assertionId);
    }

    // =========================================================================
    // Full lifecycle
    // =========================================================================

    function test_fullLifecycle_assertSettleReport() public {
        // 1. Assert
        bytes32 assertionId = _assertOutcome("Yes");
        assertTrue(assertionId != bytes32(0));

        // Market still Active
        MarketRegistryData memory reg1 = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertTrue(reg1.status == MarketStatus.Active);

        // 2. Settle (UMA callback fires)
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);

        AssertionData memory settled = ResolutionFacet(address(diamond)).getAssertionData(assertionId);
        assertTrue(settled.settled);

        // 3. Report resolution
        ResolutionFacet(address(diamond)).reportResolution(marketId, "Yes");

        // Market is Resolved
        MarketRegistryData memory reg2 = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertTrue(reg2.status == MarketStatus.Resolved);

        // Trading disabled
        MarketTradingData memory td = MarketsFacet(address(diamond)).getMarketTradingData(marketId);
        assertFalse(td.active);

        // CTF payouts reported
        assertTrue(ctf.payoutsReported(questionId));
        uint256[] memory payouts = ctf.getReportedPayouts(questionId);
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 0);
    }

    function test_fullLifecycle_disputeThenReassert() public {
        // 1. Assert "Yes"
        bytes32 firstId = _assertOutcome("Yes");

        // 2. Simulate dispute
        umaOracle.simulateDispute(firstId);

        // 3. UMA resolves as NOT truthful
        umaOracle.setAssertionResult(firstId, false);
        umaOracle.simulateResolvedCallback(firstId, false);

        // 4. Question unlocked
        MarketOracleData memory oracle = MarketsFacet(address(diamond)).getMarketOracleData(marketId);
        assertEq(oracle.activeAssertionId, bytes32(0));

        // 5. Re-assert with "No"
        bytes32 secondId = _assertOutcome("No");

        // 6. Settle second assertion
        ResolutionFacet(address(diamond)).settleAssertion(secondId);

        // 7. Report resolution
        ResolutionFacet(address(diamond)).reportResolution(marketId, "No");

        // Market is Resolved
        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(marketId);
        assertTrue(reg.status == MarketStatus.Resolved);

        uint256[] memory payouts = ctf.getReportedPayouts(questionId);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1); // No wins
    }

    // =========================================================================
    // Minimum bond enforcement
    // =========================================================================

    function test_assertMarketOutcome_usesMinimumBondWhenHigher() public {
        // Set UMA minimum bond higher than venue's requiredBond (1e6)
        uint256 umaMinBond = 10e6;
        umaOracle.setMinimumBond(umaMinBond);

        collateral.mint(ASSERTER, 100e6);
        vm.prank(ASSERTER);
        collateral.approve(address(diamond), 100e6);

        uint256 balBefore = collateral.balanceOf(ASSERTER);
        vm.prank(ASSERTER);
        ResolutionFacet(address(diamond)).assertMarketOutcome(questionId, "Yes");

        // effectiveBond = max(1e6, 10e6) = 10e6
        assertEq(collateral.balanceOf(ASSERTER), balBefore - umaMinBond);
    }

    // =========================================================================
    // Asserter tracking
    // =========================================================================

    function test_assertMarketOutcome_storesAsserterAddress() public {
        bytes32 assertionId = _assertOutcome("Yes");

        AssertionData memory data = ResolutionFacet(address(diamond)).getAssertionData(assertionId);
        assertEq(data.asserter, ASSERTER);
    }

    // =========================================================================
    // Reward payout
    // =========================================================================

    function _createMarketWithReward(uint256 rewardAmount) internal returns (uint256 mId, bytes32 qId) {
        // Create venue with non-zero reward
        vm.prank(CREATOR);
        uint256 vid = VenueFacet(address(diamond)).createVenue(
            "Reward Venue", "", address(0), address(0), CREATOR, 100, 0, TICK_SIZE, 5e6, rewardAmount, 1e6
        );

        // Fund creator for creation fee + reward
        collateral.mint(CREATOR, 100e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), 100e6);

        // Create market (reward collected from creator here)
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        mId = MarketsFacet(address(diamond)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        MarketRegistryData memory reg = MarketsFacet(address(diamond)).getMarketRegistryData(mId);
        qId = reg.questionId;
    }

    function test_rewardPayout_truthfulResolution() public {
        uint256 rewardAmount = 5e6;
        (uint256 mId, bytes32 qId) = _createMarketWithReward(rewardAmount);

        // Assert
        _fundAndApproveAsserter(100e6);
        vm.prank(ASSERTER);
        bytes32 assertionId = ResolutionFacet(address(diamond)).assertMarketOutcome(qId, "Yes");

        uint256 asserterBalBefore = collateral.balanceOf(ASSERTER);

        // Settle truthfully (UMA callback fires)
        ResolutionFacet(address(diamond)).settleAssertion(assertionId);

        // Asserter received the reward
        assertEq(collateral.balanceOf(ASSERTER), asserterBalBefore + rewardAmount);
    }

    function test_rewardPayout_rejectedAssertion_keepsRewardForNextAsserter() public {
        uint256 rewardAmount = 5e6;
        (uint256 mId, bytes32 qId) = _createMarketWithReward(rewardAmount);

        // Assert (will be rejected)
        _fundAndApproveAsserter(100e6);
        vm.prank(ASSERTER);
        bytes32 firstId = ResolutionFacet(address(diamond)).assertMarketOutcome(qId, "Yes");

        uint256 diamondBal = collateral.balanceOf(address(diamond));

        // UMA resolves NOT truthfully
        umaOracle.setAssertionResult(firstId, false);
        umaOracle.simulateResolvedCallback(firstId, false);

        // Diamond still holds the reward (no payout on rejected assertion)
        assertEq(collateral.balanceOf(address(diamond)), diamondBal);
    }

    function test_rewardPreFunding_collectedFromCreator() public {
        uint256 rewardAmount = 5e6;

        // Fund creator first, then snapshot balance
        collateral.mint(CREATOR, 200e6);
        vm.prank(CREATOR);
        collateral.approve(address(diamond), 200e6);
        uint256 creatorBalBefore = collateral.balanceOf(CREATOR);

        // Create venue with reward
        vm.prank(CREATOR);
        uint256 vid = VenueFacet(address(diamond)).createVenue(
            "Reward Venue", "", address(0), address(0), CREATOR, 100, 0, TICK_SIZE, 5e6, rewardAmount, 1e6
        );

        // Create market (reward + creation fee collected from creator)
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        vm.prank(CREATOR);
        MarketsFacet(address(diamond)).createMarket(
            vid, "", outcomes, TICK_SIZE, address(collateral), 0, 0, new bytes32[](0)
        );

        // Creator's balance decreased by reward (creation fee is no-op without protocol treasury)
        assertEq(creatorBalBefore - collateral.balanceOf(CREATOR), rewardAmount);
    }
}
