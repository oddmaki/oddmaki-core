// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC1155} from "forge-std/interfaces/IERC1155.sol";

/**
 * @title TransferHelper
 * @notice Low-level ERC-20 and ERC-1155 transfer wrappers with explicit revert on failure.
 *         Uses raw `call` for ERC-20 to handle non-standard tokens that return no data.
 */
library TransferHelper {
    error TransferFailed();
    error TransferFromFailed();

    /// @notice Transfer ERC-20 tokens from this contract to a recipient.
    /// @param token the ERC-20 token address.
    /// @param to the recipient address.
    /// @param value the amount to transfer.
    function _transferErc20(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @notice Transfer ERC-20 tokens from one address to another (requires prior approval).
    /// @param token the ERC-20 token address.
    /// @param from the sender address.
    /// @param to the recipient address.
    /// @param value the amount to transfer.
    function _transferFromErc20(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFromFailed();
    }

    /// @notice Transfer ERC-1155 tokens via safeTransferFrom.
    /// @param token the ERC-1155 token address.
    /// @param from the sender address.
    /// @param to the recipient address.
    /// @param id the token ID.
    /// @param value the amount to transfer.
    function _transferFromErc1155(address token, address from, address to, uint256 id, uint256 value) internal {
        IERC1155(token).safeTransferFrom(from, to, id, value, "");
    }
}
