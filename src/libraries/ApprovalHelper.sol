// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC1155} from "forge-std/interfaces/IERC1155.sol";

/**
 * @title ApprovalHelper
 * @notice ERC20/ERC1155 approval helpers. Approvals are from address(this) (caller context).
 */
library ApprovalHelper {
    error ApproveFailed();
    error SetApprovalForAllFailed();

    /// @notice Approve spender for max uint256 if current allowance is below the required amount.
    /// @param token the ERC-20 token address.
    /// @param spender the address to approve.
    /// @param amount the minimum required allowance.
    function approveErc20IfNeeded(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.allowance.selector, address(this), spender));
        uint256 current = success && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
        if (current < amount) {
            (bool ok,) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, type(uint256).max));
            if (!ok) revert ApproveFailed();
        }
    }

    /// @notice Set or revoke ERC-1155 operator approval.
    /// @param token the ERC-1155 token address.
    /// @param operator the operator address to approve or revoke.
    /// @param approved whether to grant or revoke approval.
    function setApprovalForAll1155(address token, address operator, bool approved) internal {
        (bool ok,) = token.call(
            abi.encodeWithSelector(IERC1155.setApprovalForAll.selector, operator, approved)
        );
        if (!ok) revert SetApprovalForAllFailed();
    }
}
