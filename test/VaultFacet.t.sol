// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {OddMaki} from "../src/OddMaki.sol";
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {NotContractOwner} from "../src/libraries/LibDiamond.sol";
import {DiamondSetup} from "./helpers/DiamondSetup.sol";

/**
 * @title VaultFacet integration tests
 * @notice Tests the Vault public API (getVault, getCtfAddress, setCtf) via the Diamond.
 */
contract VaultFacetTest is Test, DiamondSetup {
    OddMaki public diamond;
    address public owner;
    address public ctf;

    event CtfUpdated(address indexed ctf);

    function setUp() public {
        owner = address(0x1);
        ctf = address(0x2);
        diamond = deployDiamond(owner);
    }

    function test_getVault_returnsDiamond() public view {
        assertEq(VaultFacet(address(diamond)).getVault(), address(diamond));
    }

    function test_getCtfAddress_initiallyZero() public view {
        assertEq(VaultFacet(address(diamond)).getCtfAddress(), address(0));
    }

    function test_setCtf_andGetCtfAddress() public {
        vm.prank(owner);
        VaultFacet(address(diamond)).setCtf(ctf);
        assertEq(VaultFacet(address(diamond)).getCtfAddress(), ctf);
    }

    function test_setCtf_revertsWhenZero() public {
        vm.prank(owner);
        vm.expectRevert();
        VaultFacet(address(diamond)).setCtf(address(0));
    }

    // --- C-1 Audit Fix: Access control tests ---

    function test_setCtf_revertsWhenCalledByNonOwner() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, attacker, owner));
        VaultFacet(address(diamond)).setCtf(ctf);
    }

    function test_setCtf_emitsCtfUpdatedEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(diamond));
        emit CtfUpdated(ctf);
        VaultFacet(address(diamond)).setCtf(ctf);
    }
}
