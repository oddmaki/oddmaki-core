// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {OptimisticOracleV3CallbackRecipientInterface} from "../interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";
import {OptimisticOracleV3Interface} from "../interfaces/OptimisticOracleV3Interface.sol";
import {LibResolutionValidator} from "../validators/LibResolutionValidator.sol";
import {LibResolutionService} from "../services/LibResolutionService.sol";
import {LibResolutionStorage} from "../storage/LibResolutionStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {ApprovalHelper} from "../libraries/ApprovalHelper.sol";
import {MarketOracleData, MarketRegistryData, AssertionData} from "../interfaces/Types.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/**
 * @title ResolutionFacet
 * @author OddMaki Protocol
 * @notice Market resolution via UMA Optimistic Oracle V3.
 *         Flow: assertMarketOutcome -> settleAssertion -> reportResolution.
 * @dev settleAssertion does NOT use nonReentrant because UMA's settleAssertion()
 *      synchronously calls back assertionResolvedCallback on the Diamond.
 *      Callbacks validate msg.sender == umaOracle instead.
 */
contract ResolutionFacet is ReentrancyGuard, OptimisticOracleV3CallbackRecipientInterface {
    // ---- Events ----
    event AssertionCreated(bytes32 indexed assertionId, bytes32 indexed questionId, string outcome, address asserter);
    event AssertionSettled(bytes32 indexed assertionId, bool result);
    event MarketResolved(uint256 indexed marketId, bytes32 indexed questionId, string outcome);
    event MarketGroupResolved(uint256 indexed groupId, uint256 indexed winningMarketId);
    event AssertionDisputed(bytes32 indexed assertionId);

    // ---- Mutations ----

    /// @notice Assert an outcome for a market question via UMA Optimistic Oracle.
    /// @param questionId the market question ID to assert against.
    /// @param outcome    the outcome string to assert (must match one of the market's defined outcomes).
    /// @return assertionId the UMA assertion ID.
    /// @dev Caller must approve the Diamond to spend the bond amount of the market's collateral token.
    function assertMarketOutcome(bytes32 questionId, string calldata outcome)
        external
        nonReentrant
        returns (bytes32 assertionId)
    {
        LibResolutionValidator.requireUmaOracleConfigured();
        LibResolutionValidator.requireOracleInitialized(questionId);
        LibResolutionValidator.requireNoActiveAssertion(questionId);

        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(questionId);
        address umaOracle = LibProtocolStorage.getUmaOracle();
        bytes32 identifier = LibProtocolStorage.getUmaIdentifier();

        // Pull bond from asserter to Diamond
        TransferHelper._transferFromErc20(address(oracle.currency), msg.sender, address(this), oracle.requiredBond);

        // Approve UMA oracle to spend the bond
        ApprovalHelper.approveErc20IfNeeded(address(oracle.currency), umaOracle, oracle.requiredBond);

        // Build UMA claim
        bytes memory claim = LibResolutionService.buildClaim(outcome, oracle.ancillaryData);

        // Call UMA assertTruth
        assertionId = OptimisticOracleV3Interface(umaOracle).assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            oracle.liveness,
            oracle.currency,
            oracle.requiredBond,
            identifier,
            bytes32(0)
        );

        // Store assertion and lock question
        LibResolutionService.createAssertionAndLock(assertionId, questionId, outcome);

        emit AssertionCreated(assertionId, questionId, outcome, msg.sender);
    }

    /// @notice Settle an assertion after the liveness period expires.
    /// @param assertionId the UMA assertion ID to settle.
    /// @dev No nonReentrant — UMA's settleAssertion triggers assertionResolvedCallback on Diamond.
    function settleAssertion(bytes32 assertionId) external {
        LibResolutionValidator.requireAssertionExists(assertionId);

        address umaOracle = LibProtocolStorage.getUmaOracle();
        OptimisticOracleV3Interface(umaOracle).settleAssertion(assertionId);
    }

    /// @notice Report final resolution to the CTF after UMA settlement.
    /// @param marketId the market to resolve.
    /// @param outcome  the asserted outcome (must match the settled assertion's outcome).
    /// @dev For grouped markets where the outcome is YES, cascades resolution to all sibling markets.
    function reportResolution(uint256 marketId, string calldata outcome) external nonReentrant {
        LibResolutionValidator.requireActiveMarket(marketId);

        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        bytes32 questionId = reg.questionId;
        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(questionId);

        // Validate assertion exists, is settled, and outcome matches
        bytes32 activeAssertionId = oracle.activeAssertionId;
        LibResolutionValidator.requireAssertionExists(activeAssertionId);
        LibResolutionValidator.requireAssertionSettled(activeAssertionId);

        AssertionData storage assertion = LibResolutionStorage.getAssertionData(activeAssertionId);
        LibResolutionValidator.requireOutcomeMatch(assertion.outcome, outcome);

        // Compute payouts and resolve (emits MarketResolved)
        uint256[] memory payouts = LibResolutionService.computePayouts(outcome, oracle.outcomes);
        LibResolutionService.resolveMarket(marketId, payouts, outcome);

        // If grouped market and YES wins (index 0 = 1, index 1 = 0), cascade resolution
        // (emits MarketResolved for each sibling + MarketGroupResolved)
        if (reg.groupId > 0 && payouts[0] == 1 && payouts[1] == 0) {
            LibResolutionService.cascadeGroupResolution(marketId, reg.groupId);
        }
    }

    // ---- UMA Callbacks ----

    /// @notice UMA callback invoked when an assertion is resolved (truthful or not).
    /// @param assertionId       the UMA assertion ID.
    /// @param assertedTruthfully true if the assertion was confirmed, false if disputed and rejected.
    /// @dev Callable only by the UMA oracle. No nonReentrant — called during settleAssertion.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        LibResolutionValidator.requireUmaOracle(msg.sender);

        if (LibResolutionStorage.assertionExists(assertionId)) {
            LibResolutionService.handleAssertionResolved(assertionId, assertedTruthfully);
        }

        emit AssertionSettled(assertionId, assertedTruthfully);
    }

    /// @notice UMA callback invoked when an assertion is disputed.
    /// @param assertionId the UMA assertion ID that was disputed.
    /// @dev Callable only by the UMA oracle.
    function assertionDisputedCallback(bytes32 assertionId) external override {
        LibResolutionValidator.requireUmaOracle(msg.sender);
        emit AssertionDisputed(assertionId);
    }

    // ---- Views ----

    /// @notice Get assertion tracking data.
    /// @param assertionId the UMA assertion ID to query.
    function getAssertionData(bytes32 assertionId) external view returns (AssertionData memory) {
        return LibResolutionStorage.getAssertionData(assertionId);
    }
}
