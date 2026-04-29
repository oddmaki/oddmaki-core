// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

/**
 * @title ArrayHelpers
 * @notice Pure helpers for array construction and utilities.
 */
library ArrayHelpers {
    /// @return arr Array of length `length` with every element equal to `value`
    function filled(uint256 length, uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](length);
        for (uint256 i = 0; i < length; i++) arr[i] = value;
    }
}
