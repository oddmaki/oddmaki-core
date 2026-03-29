// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAccessControl
 * @notice Universal access control interface for the OddMaki Protocol.
 *         Venue operators deploy contracts implementing this interface
 *         to restrict who can trade or create markets.
 *         address(0) for an AC field means public (no restriction).
 */
interface IAccessControl {
    /// @notice Check if a user is allowed access.
    function isAllowed(address user) external view returns (bool);
}
