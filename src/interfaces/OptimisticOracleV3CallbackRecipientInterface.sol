// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title OptimisticOracleV3CallbackRecipientInterface
 * @notice Interface for contracts that receive callbacks from UMA V3 Optimistic Oracle.
 */
interface OptimisticOracleV3CallbackRecipientInterface {
    /// @notice Called when an assertion is resolved (accepted or rejected).
    /// @param assertionId the unique assertion identifier.
    /// @param assertedTruthfully true if the assertion was accepted as true.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    /// @notice Called when an assertion is disputed.
    /// @param assertionId the unique assertion identifier.
    function assertionDisputedCallback(bytes32 assertionId) external;
}
