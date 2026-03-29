// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibMarketOracleAggregate} from "../aggregates/LibMarketOracleAggregate.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title LibOracleInitializationService
 * @notice Initializes oracle data for a new market: computes conditionId via CTF, writes MarketOracleData,
 *         and calls CTF.prepareCondition to register the Diamond as the oracle.
 *
 *         The Diamond itself is the CTF oracle: in delegatecall context, address(this) is the Diamond
 *         proxy, so prepareCondition registers the Diamond as the entity authorised to report payouts
 *         for this question.
 */
library LibOracleInitializationService {
    uint64 constant MIN_LIVENESS = 2 hours;

    error OracleCtfNotSet();

    /**
     * @notice Initialize oracle data for a new market.
     * @param questionId      Stable question ID (generated before this call).
     * @param ancillaryData   Fully enriched ancillary data (controller + UMA metadata already appended).
     * @param outcomes        Outcome strings (e.g. ["Yes", "No"]).
     * @param collateralToken ERC20 collateral for UMA bond/reward and CTF.
     * @param reward          UMA reward amount.
     * @param requiredBond    Minimum bond (from venue config).
     * @param liveness        UMA liveness in seconds (floored to MIN_LIVENESS = 2h).
     * @return conditionId    CTF condition ID = keccak256(abi.encodePacked(Diamond, questionId, outcomeSlotCount)).
     */
    function initialize(
        bytes32 questionId,
        bytes memory ancillaryData,
        string[] memory outcomes,
        address collateralToken,
        uint256 reward,
        uint256 requiredBond,
        uint64 liveness
    ) internal returns (bytes32 conditionId) {
        address ctf = LibVaultStorage.getCtf();
        if (ctf == address(0)) revert OracleCtfNotSet();

        uint64 actualLiveness = liveness > MIN_LIVENESS ? liveness : MIN_LIVENESS;
        uint256 outcomeSlotCount = outcomes.length;

        // conditionId is a deterministic hash: keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount))
        // oracle = address(this) = Diamond proxy in delegatecall context.
        conditionId = IConditionalTokens(ctf).getConditionId(address(this), questionId, outcomeSlotCount);

        // Write oracle storage row before the external call (CEI).
        LibMarketOracleAggregate.createOracle(
            questionId,
            conditionId,
            outcomeSlotCount,
            IERC20(collateralToken),
            reward,
            requiredBond,
            actualLiveness,
            ancillaryData,
            outcomes
        );

        // Register the Diamond as the CTF oracle for this question.
        // This is the only external call in the market creation path.
        IConditionalTokens(ctf).prepareCondition(address(this), questionId, outcomeSlotCount);
    }
}
