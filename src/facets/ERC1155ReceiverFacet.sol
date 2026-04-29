// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

/**
 * @title ERC1155ReceiverFacet
 * @author OddMaki Protocol
 * @notice ERC-1155 token receiver interface. Allows the Diamond proxy to receive
 *         outcome tokens from the Conditional Tokens Framework (CTF).
 */
contract ERC1155ReceiverFacet {
    /// @notice Handle receipt of a single ERC-1155 token type.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    /// @notice Handle receipt of a batch of ERC-1155 token types.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
