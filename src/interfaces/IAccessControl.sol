// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
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
