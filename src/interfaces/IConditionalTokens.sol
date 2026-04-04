// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal CTF interface for oracle registration, vault custody (split/merge), and position IDs
interface IConditionalTokens {
    // -------------------------------------------------------------------------
    // Oracle registration
    // -------------------------------------------------------------------------

    /// @notice Returns conditionId = keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount)).
    ///         Pure computation, no state change.
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32 conditionId);

    /// @notice Registers `oracle` as the entity authorised to report payouts for this question.
    ///         Must be called before the market can be used for split/merge.
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    /// @notice Returns the number of outcome slots for a condition (0 if not yet prepared).
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256 outcomeSlotCount);

    // -------------------------------------------------------------------------
    // Position IDs
    // -------------------------------------------------------------------------

    /// @notice Compute the collection ID for a condition and index set.
    /// @param parentCollectionId the parent collection (bytes32(0) for root).
    /// @param conditionId the condition identifier.
    /// @param indexSet bitmask of outcome slots included in this collection.
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32 collectionId);

    // -------------------------------------------------------------------------
    // Split / merge
    // -------------------------------------------------------------------------

    /// @notice Split collateral into conditional outcome tokens.
    /// @param collateralToken the ERC-20 collateral token.
    /// @param parentCollectionId the parent collection (bytes32(0) for root).
    /// @param conditionId the condition to split against.
    /// @param partition array of index sets defining the split.
    /// @param amount the amount of collateral to split.
    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    /// @notice Merge conditional outcome tokens back into collateral.
    /// @param collateralToken the ERC-20 collateral token.
    /// @param parentCollectionId the parent collection (bytes32(0) for root).
    /// @param conditionId the condition to merge against.
    /// @param partition array of index sets defining the merge.
    /// @param amount the amount of each outcome token to merge.
    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    // -------------------------------------------------------------------------
    // Resolution
    // -------------------------------------------------------------------------

    /// @notice Report payout vector for a resolved condition. Only callable by the oracle
    ///         registered via prepareCondition.
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;

    // -------------------------------------------------------------------------
    // Resolution queries (used by SDK, not by Diamond on-chain)
    // -------------------------------------------------------------------------

    /// @notice Sum of payout numerators for a condition (non-zero once resolved).
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);

    /// @notice Payout numerator for a specific outcome slot of a resolved condition.
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    /// @notice Redeem resolved outcome tokens for collateral.
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;

    // -------------------------------------------------------------------------
    // Position queries (used by SDK, not by Diamond on-chain)
    // -------------------------------------------------------------------------

    /// @notice Compute positionId = keccak256(abi.encodePacked(collateralToken, collectionId)).
    function getPositionId(IERC20 collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256 positionId);

    /// @notice ERC-1155 balance query for outcome token positions.
    function balanceOf(address account, uint256 id) external view returns (uint256);
}
