// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OptimisticOracleV3CallbackRecipientInterface} from "../../src/interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";

/**
 * @title MockUmaOracle
 * @notice Mock UMA Optimistic Oracle V3 for tests.
 *         Stores assertions, pulls bond from caller, and provides helpers for test control.
 */
contract MockUmaOracle {
    uint256 private _nextAssertionId = 1;

    struct MockAssertion {
        bytes32 assertionId;
        address callbackRecipient;
        address asserter;
        IERC20 currency;
        uint256 bond;
        bool settled;
        bool result;
    }

    mapping(bytes32 => MockAssertion) public mockAssertions;

    function assertTruth(
        bytes memory,
        address asserter,
        address callbackRecipient,
        address,
        uint64,
        IERC20 currency,
        uint256 bond,
        bytes32,
        bytes32
    ) external returns (bytes32 assertionId) {
        assertionId = bytes32(_nextAssertionId++);
        currency.transferFrom(msg.sender, address(this), bond);

        mockAssertions[assertionId] = MockAssertion({
            assertionId: assertionId,
            callbackRecipient: callbackRecipient,
            asserter: asserter,
            currency: currency,
            bond: bond,
            settled: false,
            result: true
        });
    }

    function settleAssertion(bytes32 assertionId) external {
        MockAssertion storage a = mockAssertions[assertionId];
        a.settled = true;

        OptimisticOracleV3CallbackRecipientInterface(a.callbackRecipient)
            .assertionResolvedCallback(assertionId, a.result);
    }

    function getAssertionResult(bytes32 assertionId) external view returns (bool) {
        return mockAssertions[assertionId].result;
    }

    function getMinimumBond(address) external pure returns (uint256) {
        return 0;
    }

    // ---- Test helpers ----

    /// @notice Set the result for an assertion before settling (for dispute testing).
    function setAssertionResult(bytes32 assertionId, bool result) external {
        mockAssertions[assertionId].result = result;
    }

    /// @notice Simulate dispute callback on the Diamond.
    function simulateDispute(bytes32 assertionId) external {
        MockAssertion storage a = mockAssertions[assertionId];
        OptimisticOracleV3CallbackRecipientInterface(a.callbackRecipient)
            .assertionDisputedCallback(assertionId);
    }

    /// @notice Simulate resolved callback directly (bypasses settleAssertion flow).
    function simulateResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        MockAssertion storage a = mockAssertions[assertionId];
        OptimisticOracleV3CallbackRecipientInterface(a.callbackRecipient)
            .assertionResolvedCallback(assertionId, assertedTruthfully);
    }
}
