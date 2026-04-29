// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IAccessControl} from "../interfaces/IAccessControl.sol";

/**
 * @title WhitelistAccessControl
 * @notice Access control based on an owner-managed address whitelist.
 *         Deploy one instance per scope (e.g. one for venue trading, another for creation).
 */
contract WhitelistAccessControl is IAccessControl {
    address public owner;
    mapping(address => bool) public whitelist;

    event AddedToWhitelist(address[] users);
    event RemovedFromWhitelist(address[] users);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    function isAllowed(address user) external view override returns (bool) {
        return whitelist[user];
    }

    function addToWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = true;
        }
        emit AddedToWhitelist(users);
    }

    function removeFromWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = false;
        }
        emit RemovedFromWhitelist(users);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
