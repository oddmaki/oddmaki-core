// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
//
// Based on the EIP-2535 Diamonds reference implementation by Nick Mudge
// <nick@perfectabstractions.com>, originally licensed under MIT.
// Reference: https://eips.ethereum.org/EIPS/eip-2535
pragma solidity ^0.8.0;

import { LibDiamond } from "./libraries/LibDiamond.sol";
import { IDiamondCut } from "./interfaces/IDiamondCut.sol";

/// @notice Reverts when no facet is registered for the called function selector.
error FunctionNotFound(bytes4 _functionSelector);

/// @notice Constructor arguments for the Diamond proxy. Uses a struct to avoid stack-too-deep.
struct DiamondArgs {
    address owner;
    address init;
    bytes initCalldata;
}

/**
 * @title OddMaki
 * @notice EIP-2535 Diamond proxy for the OddMaki Protocol. All protocol functionality
 *         is implemented in facets; this contract delegates every call to the facet
 *         registered for the incoming selector.
 */
contract OddMaki {

    constructor(IDiamondCut.FacetCut[] memory _diamondCut, DiamondArgs memory _args) payable {
        LibDiamond.setContractOwner(_args.owner);
        LibDiamond.diamondCut(_diamondCut, _args.init, _args.initCalldata);
    }

    /// @notice Delegates calls to the facet registered for msg.sig. Reverts if no facet is found.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;
        if(facet == address(0)) {
            revert FunctionNotFound(msg.sig);
        }
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
             // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
                case 0 {
                    revert(0, returndatasize())
                }
                default {
                    return(0, returndatasize())
                }
        }
    }

    receive() external payable {}
}
