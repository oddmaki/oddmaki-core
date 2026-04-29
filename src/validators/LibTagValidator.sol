// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
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
