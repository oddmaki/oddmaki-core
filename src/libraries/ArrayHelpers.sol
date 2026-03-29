// SPDX-License-Identifier: MIT
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
