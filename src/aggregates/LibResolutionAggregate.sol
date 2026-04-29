// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibResolutionStorage} from "../storage/LibResolutionStorage.sol";
import {AssertionData} from "../interfaces/Types.sol";

/**
 * @title LibResolutionAggregate
 * @notice Own-storage-only mutations for the Resolution domain (LibResolutionStorage).
 *         Cross-domain orchestration (locking oracle, resolving markets, cascading groups)
 *         lives in LibResolutionService.
 */
library LibResolutionAggregate {
    /// @notice Store a new assertion in resolution storage.
    function storeAssertion(
        bytes32 assertionId,
        bytes32 questionId,
        string calldata outcome,
        address asserter
    ) internal {
        LibResolutionStorage.getStorage().byAssertionId[assertionId] = AssertionData({
            assertionId: assertionId,
            questionId: questionId,
            outcome: outcome,
            settled: false,
            asserter: asserter
        });
    }

    /// @notice Mark an assertion as settled.
    function markSettled(bytes32 assertionId) internal {
        LibResolutionStorage.getAssertionData(assertionId).settled = true;
    }
}
