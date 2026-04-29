// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title CTFHelpers
 * @notice Utility for computing Gnosis Conditional Token Framework (CTF) position IDs.
 */
library CTFHelpers {
    /// @notice Compute the ERC-1155 position ID for a (collateralToken, collectionId) pair.
    /// @param collateralToken the ERC-20 collateral token.
    /// @param collectionId the CTF collection ID (derived from conditionId + indexSet).
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }
}
