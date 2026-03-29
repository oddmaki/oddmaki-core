// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LibTickSizeValidator
 * @notice Validates that tickSize belongs to the protocol-approved whitelist.
 *         Allowed values: 1e15 (0.1%, 1000 price levels) and 1e16 (1%, 100 price levels).
 */
library LibTickSizeValidator {
    uint256 internal constant TICK_SIZE_FINE = 1e15;
    uint256 internal constant TICK_SIZE_STANDARD = 1e16;

    error InvalidTickSize();

    /// @notice Revert if tickSize is not in the allowed whitelist.
    function requireValidTickSize(uint256 tickSize) internal pure {
        if (tickSize != TICK_SIZE_FINE && tickSize != TICK_SIZE_STANDARD) {
            revert InvalidTickSize();
        }
    }
}
