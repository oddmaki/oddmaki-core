// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibResolutionAggregate} from "../aggregates/LibResolutionAggregate.sol";
import {LibResolutionStorage} from "../storage/LibResolutionStorage.sol";
import {LibMarketOracleAggregate} from "../aggregates/LibMarketOracleAggregate.sol";
import {LibMarketRegistryAggregate} from "../aggregates/LibMarketRegistryAggregate.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibMarketGroupAggregate} from "../aggregates/LibMarketGroupAggregate.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketGroupStorage} from "../storage/LibMarketGroupStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {AssertionData, MarketRegistryData, MarketOracleData, MarketGroupData, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title LibResolutionService
 * @notice Business logic for resolution: payout computation, claim building,
 *         and cross-domain orchestration (assertion lifecycle, market resolution, group cascade).
 */
library LibResolutionService {
    // ---- Events emitted from the service layer so every resolution path is covered ----
    event MarketResolved(uint256 indexed marketId, bytes32 indexed questionId, string outcome);
    event MarketGroupResolved(uint256 indexed groupId, uint256 indexed winningMarketId);
    event RewardPaid(bytes32 indexed assertionId, address indexed asserter, uint256 reward);

    // ---- Pure / View helpers ----

    /// @notice Build the UMA assertion claim string.
    /// @param outcome The asserted outcome string.
    /// @param ancillaryData The question's ancillary data.
    /// @return claim The encoded claim for UMA assertTruth.
    function buildClaim(string calldata outcome, bytes memory ancillaryData)
        internal
        pure
        returns (bytes memory claim)
    {
        claim = abi.encodePacked("Outcome: ", outcome, " for question: ", ancillaryData);
    }

    /// @notice Compute payout vector from outcome string and market outcomes.
    /// @dev If outcome matches a known outcome: winner-takes-all [1, 0] or [0, 1].
    ///      If outcome not recognized (e.g. "Invalid"): split payouts [1, 1].
    /// @param outcome The resolved outcome string.
    /// @param outcomes The market's defined outcomes array.
    /// @return payouts The CTF payout vector.
    function computePayouts(string memory outcome, string[] storage outcomes)
        internal
        view
        returns (uint256[] memory payouts)
    {
        uint256 numOutcomes = outcomes.length;
        bytes32 outcomeHash = keccak256(bytes(outcome));
        uint256 winningIndex = type(uint256).max;

        for (uint256 i = 0; i < numOutcomes; i++) {
            if (outcomeHash == keccak256(bytes(outcomes[i]))) {
                winningIndex = i;
                break;
            }
        }

        payouts = new uint256[](numOutcomes);

        if (winningIndex == type(uint256).max) {
            // Invalid / unrecognized outcome -> split payouts equally
            for (uint256 i = 0; i < numOutcomes; i++) {
                payouts[i] = 1;
            }
        } else {
            // Winner takes all
            payouts[winningIndex] = 1;
        }
    }

    // ---- Cross-domain orchestration ----

    /// @notice Store a new assertion and lock the oracle question.
    function createAssertionAndLock(
        bytes32 assertionId,
        bytes32 questionId,
        string calldata outcome,
        address asserter
    ) internal {
        LibResolutionAggregate.storeAssertion(assertionId, questionId, outcome, asserter);
        LibMarketOracleAggregate.setActiveAssertionId(questionId, assertionId);
    }

    /// @notice Handle UMA resolved callback: mark settled, pay standalone reward or reset oracle.
    function handleAssertionResolved(bytes32 assertionId, bool assertedTruthfully) internal {
        AssertionData storage assertion = LibResolutionStorage.getAssertionData(assertionId);
        LibResolutionAggregate.markSettled(assertionId);

        if (assertedTruthfully) {
            payStandaloneReward(assertion);
        } else {
            LibMarketOracleAggregate.setActiveAssertionId(assertion.questionId, bytes32(0));
        }
    }

    /// @notice Pay reward to asserter for standalone markets (grouped market reward = 0 here; paid in cascadeGroupResolution).
    function payStandaloneReward(AssertionData storage assertion) internal {
        if (assertion.asserter == address(0)) return;

        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(assertion.questionId);
        uint256 rewardAmount = oracle.reward;

        if (rewardAmount > 0) {
            TransferHelper._transferErc20(address(oracle.currency), assertion.asserter, rewardAmount);
            emit RewardPaid(assertion.assertionId, assertion.asserter, rewardAmount);
        }
    }

    /// @notice Resolve a market: report payouts to CTF, update status, disable trading, emit event.
    function resolveMarket(uint256 marketId, uint256[] memory payouts, string memory outcome) internal {
        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        bytes32 questionId = reg.questionId;

        address ctf = LibVaultStorage.getCtf();
        IConditionalTokens(ctf).reportPayouts(questionId, payouts);

        LibMarketRegistryAggregate.setStatus(marketId, MarketStatus.Resolved);
        LibMarketTradingAggregate.setActive(marketId, false);

        emit MarketResolved(marketId, questionId, outcome);
    }

    /// @notice Cascade resolution for a market group: pay group reward, resolve all Active sibling markets as NO.
    function cascadeGroupResolution(uint256 winningMarketId, uint256 groupId) internal {
        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        address ctf = LibVaultStorage.getCtf();

        // Pay group reward to the winning market's asserter
        payGroupReward(winningMarketId, group);

        LibMarketGroupAggregate.setResolvedMarketId(groupId, winningMarketId);
        LibMarketGroupAggregate.setGroupStatus(groupId, MarketStatus.Resolved);

        for (uint256 i = 0; i < group.marketIds.length; i++) {
            uint256 siblingId = group.marketIds[i];
            if (siblingId == winningMarketId) continue;

            MarketRegistryData storage siblingReg = LibMarketRegistryStorage.getMarketRegistryData(siblingId);

            // Skip markets that aren't Active (e.g. Draft placeholders or already Resolved)
            if (siblingReg.status != MarketStatus.Active) continue;

            bytes32 siblingQuestionId = siblingReg.questionId;
            uint256[] memory noPayouts = new uint256[](2);
            noPayouts[1] = 1; // second outcome wins: [0, 1]

            IConditionalTokens(ctf).reportPayouts(siblingQuestionId, noPayouts);

            LibMarketRegistryAggregate.setStatus(siblingId, MarketStatus.Resolved);
            LibMarketTradingAggregate.setActive(siblingId, false);

            string memory losingOutcome = LibMarketOracleStorage.getMarketOracleData(siblingQuestionId).outcomes[1];
            emit MarketResolved(siblingId, siblingQuestionId, losingOutcome);
        }

        emit MarketGroupResolved(groupId, winningMarketId);
    }

    /// @notice Pay the group-level reward to the winning market's asserter.
    function payGroupReward(uint256 winningMarketId, MarketGroupData storage group) internal {
        if (group.reward == 0) return;

        bytes32 winningQuestionId = LibMarketRegistryStorage.getMarketRegistryData(winningMarketId).questionId;
        bytes32 activeAssertionId = LibMarketOracleStorage.getMarketOracleData(winningQuestionId).activeAssertionId;
        AssertionData storage winningAssertion = LibResolutionStorage.getAssertionData(activeAssertionId);

        if (winningAssertion.asserter != address(0)) {
            TransferHelper._transferErc20(address(group.collateralToken), winningAssertion.asserter, group.reward);
            emit RewardPaid(activeAssertionId, winningAssertion.asserter, group.reward);
        }
    }
}
