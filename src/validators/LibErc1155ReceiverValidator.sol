// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IERC1155Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";

/**
 * @title LibErc1155ReceiverValidator
 * @notice Guards SELL placement from contracts that cannot receive ERC-1155 outcome tokens.
 *
 *         SELL makers hold deposited outcome tokens inside the Diamond vault. Any later
 *         outcome-token refund (fill rounding, cancellation, expiry, resolved-market
 *         cleanup) is routed back to the maker via CTF.safeTransferFrom, which invokes
 *         onERC1155Received on contract recipients. A contract maker missing that hook
 *         would permanently strand its refund and grief the order book — so we block the
 *         placement up front.
 *
 *         EOAs are accepted unconditionally (no code). See H-05 for background.
 */
library LibErc1155ReceiverValidator {
    error MakerNotErc1155Receiver();
    error MakerErc165CallFailed();

    /// @notice Require `maker` to be able to receive ERC-1155 outcome tokens.
    ///         EOAs (no code) are accepted. Contracts must return true from
    ///         supportsInterface(type(IERC1155Receiver).interfaceId).
    function requireCanReceiveErc1155(address maker) internal view {
        if (maker.code.length == 0) return;

        try IERC165(maker).supportsInterface(type(IERC1155Receiver).interfaceId) returns (bool supported) {
            if (!supported) revert MakerNotErc1155Receiver();
        } catch {
            revert MakerErc165CallFailed();
        }
    }
}
