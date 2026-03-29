// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "../interfaces/IAccessControl.sol";

/**
 * @title TokenGatedAccessControl
 * @notice Access control based on ERC-20 token balance.
 *         Users must hold at least `minBalance` of the specified token.
 *         Immutable after deployment.
 */
contract TokenGatedAccessControl is IAccessControl {
    address public immutable token;
    uint256 public immutable minBalance;

    error ZeroAddress();
    error ZeroMinBalance();

    constructor(address _token, uint256 _minBalance) {
        if (_token == address(0)) revert ZeroAddress();
        if (_minBalance == 0) revert ZeroMinBalance();
        token = _token;
        minBalance = _minBalance;
    }

    function isAllowed(address user) external view override returns (bool) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSignature("balanceOf(address)", user));
        if (!success || data.length < 32) return false;
        return abi.decode(data, (uint256)) >= minBalance;
    }
}
