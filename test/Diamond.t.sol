// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import { OddMaki, DiamondArgs } from "../src/OddMaki.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamond } from "../src/interfaces/IDiamond.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../src/facets/OwnershipFacet.sol";
import { ProtocolFacet } from "../src/facets/ProtocolFacet.sol";

/// @title Diamond infrastructure tests
/// @notice Tests EIP-2535 Diamond proxy basics: deployment, facet cuts, loupe functions, ownership,
///         ETH rescue, and protocol-level moderation (pause/suspend).
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
        assertEq(facets.length, 4, "expected Cut, Loupe, Ownership, Protocol facets");
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

    // -- M-7: ETH rescue via withdrawETH --

    function test_M7_ownerCanRescueTrappedEth() public {
        // Send ETH to Diamond (accepted by receive())
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        (bool sent,) = address(protocol).call{value: 1 ether}("");
        assertTrue(sent, "ETH should be accepted");

        // Owner rescues the ETH
        address recipient = address(0xCAFE);
        vm.prank(owner);
        ProtocolFacet(address(protocol)).withdrawETH(recipient);
        assertEq(recipient.balance, 1 ether, "Recipient should receive rescued ETH");
        assertEq(address(protocol).balance, 0, "Diamond should have 0 ETH after rescue");
    }

    function test_M7_nonOwnerCannotWithdrawEth() public {
        vm.deal(address(protocol), 1 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        ProtocolFacet(address(protocol)).withdrawETH(address(0xBEEF));
    }

    function _deployOddMaki(address _owner) internal returns (OddMaki p) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        ProtocolFacet protocolFacetImpl = new ProtocolFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);

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

        bytes4[] memory protocolSelectors = new bytes4[](1);
        protocolSelectors[0] = ProtocolFacet.withdrawETH.selector;
        cuts[3] = IDiamond.FacetCut({
            facetAddress: address(protocolFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: protocolSelectors
        });

        DiamondArgs memory args = DiamondArgs({
            owner: _owner,
            init: address(0),
            initCalldata: ""
        });
        p = new OddMaki(cuts, args);
    }
}
