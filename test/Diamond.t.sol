// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import { OddMaki, DiamondArgs } from "../src/OddMaki.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamond } from "../src/interfaces/IDiamond.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../src/facets/OwnershipFacet.sol";

/// @title Diamond infrastructure tests
/// @notice Tests EIP-2535 Diamond proxy basics: deployment, facet cuts, loupe functions, and ownership.
contract DiamondTest is Test {
    OddMaki public protocol;
    address public owner;

    function setUp() public {
        owner = address(0x1);
        protocol = _deployOddMaki(owner);
    }

    function test_OwnerIsSet() public view {
        assertEq(IERC173(address(protocol)).owner(), owner);
    }

    function test_FacetAddressesReturnsThreeFacets() public view {
        address[] memory facets = DiamondLoupeFacet(address(protocol)).facetAddresses();
        assertEq(facets.length, 3, "expected Cut, Loupe, Ownership facets");
    }

    function test_OnlyOwnerCanCallDiamondCut() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(cutFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: selectors
        });
        vm.prank(address(0x2)); // not owner
        vm.expectRevert();
        IDiamondCut(address(protocol)).diamondCut(cuts, address(0), "");
    }

    function _deployOddMaki(address _owner) internal returns (OddMaki p) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3);

        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(cutFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: cutSelectors
        });

        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = DiamondLoupeFacet.facets.selector;
        loupeSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSelectors[4] = DiamondLoupeFacet.supportsInterface.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownershipSelectors[1] = OwnershipFacet.owner.selector;
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        DiamondArgs memory args = DiamondArgs({
            owner: _owner,
            init: address(0),
            initCalldata: ""
        });
        p = new OddMaki(cuts, args);
    }
}
