// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title IPythExtended
 * @notice Local extension of `IPyth` that exposes `parsePriceFeedUpdatesUnique`.
 *
 *         The deployed Pyth oracle on Base mainnet and Base Sepolia implements
 *         `parsePriceFeedUpdatesUnique`, but the vendored `pyth-sdk-solidity`
 *         v2.2.0 in `lib/` predates the function and does not declare it. This
 *         interface adds the declaration without modifying the vendored SDK.
 *
 *         Semantics (from Pyth's `IPyth.sol` in pyth-sdk-solidity v3+):
 *         A submitted price update is accepted only if its encoded
 *         `prevPublishTime` is strictly less than `minPublishTime` AND its
 *         `publishTime` falls in `[minPublishTime, maxPublishTime]`. This makes
 *         the call effectively pick the FIRST price update at or after
 *         `minPublishTime`: any later VAA within the window has a
 *         `prevPublishTime` >= `minPublishTime` and is rejected. Resolvers
 *         therefore cannot bias the outcome by omitting earlier in-window
 *         VAAs — the function forces the earliest one to be used.
 */
interface IPythExtended is IPyth {
    /// @notice Parse `updateData` and return the price feed for the FIRST in-range
    ///         price update per `priceIds` in `[minPublishTime, maxPublishTime]`.
    /// @dev Reverts if any submitted update for `priceIds[i]` has
    ///      `prevPublishTime >= minPublishTime`, or if no in-range update exists.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds);
}
