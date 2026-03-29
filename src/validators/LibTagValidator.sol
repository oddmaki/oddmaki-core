// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LibTagValidator
 * @notice Validates market/group tags. Tags are event-only (no storage).
 */
library LibTagValidator {
    uint256 internal constant MAX_TAGS = 5;

    error TooManyTags();

    function validateTags(bytes32[] calldata tags) internal pure {
        if (tags.length > MAX_TAGS) revert TooManyTags();
    }

    function validateTagsMemory(bytes32[] memory tags) internal pure {
        if (tags.length > MAX_TAGS) revert TooManyTags();
    }
}
