// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

/**
 * @title LibNegRiskStorage
 * @notice NegRisk domain: mapping underlying collateral → wrapped token. Read-only accessors.
 *        Used only by Vault when needsWrapping(conditionId); Diamond holds tokens.
 */
library LibNegRiskStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.negrisk");

    struct Storage {
        /// @dev underlying => wrapped token contract
        mapping(address => address) wrappedCollaterals;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getWrappedCollateral(address underlying) internal view returns (address) {
        return getStorage().wrappedCollaterals[underlying];
    }

    function hasWrappedCollateral(address underlying) internal view returns (bool) {
        return getStorage().wrappedCollaterals[underlying] != address(0);
    }
}
