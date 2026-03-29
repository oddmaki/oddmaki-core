// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title OptimisticOracleV3Interface
 * @notice Interface for UMA V3 Optimistic Oracle.
 */
interface OptimisticOracleV3Interface {
    struct EscalationManagerSettings {
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
        address assertingCaller;
        address escalationManager;
    }

    struct Assertion {
        EscalationManagerSettings escalationManagerSettings;
        address asserter;
        uint64 assertionTime;
        bool settled;
        IERC20 currency;
        uint64 expirationTime;
        bool settlementResolution;
        bytes32 domainId;
        bytes32 identifier;
        uint256 bond;
        address callbackRecipient;
        address disputer;
    }

    /// @notice Get the default price identifier used for assertions.
    function defaultIdentifier() external view returns (bytes32);

    /// @notice Retrieve full assertion data by ID.
    /// @param assertionId the assertion to query.
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);

    /// @notice Submit a new truth assertion to the oracle.
    /// @param claim the encoded claim being asserted.
    /// @param asserter the address making the assertion.
    /// @param callbackRecipient the address to receive resolution/dispute callbacks.
    /// @param escalationManager the escalation manager address (address(0) for default).
    /// @param liveness the dispute window duration in seconds.
    /// @param currency the ERC-20 token used for bonding.
    /// @param bond the bond amount required.
    /// @param identifier the price identifier for this assertion.
    /// @param domainId the domain identifier (bytes32(0) for default).
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32);

    /// @notice Settle a resolved assertion after the liveness period.
    /// @param assertionId the assertion to settle.
    function settleAssertion(bytes32 assertionId) external;

    /// @notice Get the boolean result of a settled assertion.
    /// @param assertionId the assertion to query.
    function getAssertionResult(bytes32 assertionId) external view returns (bool);

    /// @notice Get the minimum bond amount for a currency.
    /// @param currency the ERC-20 token address.
    function getMinimumBond(address currency) external view returns (uint256);

    /// @notice Check whether an assertion has been settled.
    /// @param assertionId the assertion to check.
    function isSettled(bytes32 assertionId) external view returns (bool settled);
}
