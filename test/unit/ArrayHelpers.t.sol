// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArrayHelpers} from "../../src/libraries/ArrayHelpers.sol";

contract ExposeArrayHelpers {
    function filled(uint256 length, uint256 value) external pure returns (uint256[] memory) {
        return ArrayHelpers.filled(length, value);
    }
}

contract ArrayHelpersTest is Test {
    ExposeArrayHelpers public helper;

    function setUp() public {
        helper = new ExposeArrayHelpers();
    }

    function test_filled_lengthAndValues() public view {
        uint256[] memory arr = helper.filled(3, 5);
        assertEq(arr.length, 3);
        assertEq(arr[0], 5);
        assertEq(arr[1], 5);
        assertEq(arr[2], 5);
    }

    function test_filled_zeroLength() public view {
        uint256[] memory arr = helper.filled(0, 99);
        assertEq(arr.length, 0);
    }

    function test_filled_zeroValue() public view {
        uint256[] memory arr = helper.filled(2, 0);
        assertEq(arr.length, 2);
        assertEq(arr[0], 0);
        assertEq(arr[1], 0);
    }
}
