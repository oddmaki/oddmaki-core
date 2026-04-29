// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity ^0.8.0;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IERC173 } from "../interfaces/IERC173.sol";

/**
 * @title OwnershipFacet
 * @author OddMaki Protocol
 * @notice EIP-173 ownership management for the Diamond proxy.
 */
contract OwnershipFacet is IERC173 {
    /// @notice Transfer ownership of the Diamond to a new address. Owner-only.
    /// @param _newOwner the new owner address.
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /// @notice Get the current owner of the Diamond.
    /// @return owner_ the owner address.
    function owner() external override view returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
