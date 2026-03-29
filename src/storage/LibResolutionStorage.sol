// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AssertionData} from "../interfaces/Types.sol";

/**
 * @title LibResolutionStorage
 * @notice Diamond storage for resolution: assertionId -> AssertionData.
 */
library LibResolutionStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.resolution");

    struct Storage {
        mapping(bytes32 => AssertionData) byAssertionId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getAssertionData(bytes32 assertionId) internal view returns (AssertionData storage) {
        return getStorage().byAssertionId[assertionId];
    }

    function assertionExists(bytes32 assertionId) internal view returns (bool) {
        return getAssertionData(assertionId).assertionId != bytes32(0);
    }
}
