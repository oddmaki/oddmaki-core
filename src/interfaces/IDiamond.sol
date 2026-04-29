// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
//
// Based on the EIP-2535 Diamonds reference implementation by Nick Mudge
// <nick@perfectabstractions.com>, originally licensed under MIT.
// Reference: https://eips.ethereum.org/EIPS/eip-2535
pragma solidity ^0.8.0;

interface IDiamond {
    enum FacetCutAction {Add, Replace, Remove}
    // Add=0, Replace=1, Remove=2

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
