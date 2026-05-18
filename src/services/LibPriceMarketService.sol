// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";

/**
 * @title LibPriceMarketService
 * @notice Business logic for Pyth-powered price markets: deterministic price selection
 *         from a window of submitted VAAs, ETH refund handling, and feed metadata reads.
 */
library LibPriceMarketService {
    /// @notice Read the price exponent for a Pyth feed without updating.
    ///         Uses getPriceUnsafe which returns the last stored data (no fee required).
    ///         The expo field is fixed per feed and always valid regardless of staleness.
    function getFeedExponent(bytes32 pythFeedId) internal view returns (int32) {
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        PythStructs.Price memory price = pyth.getPriceUnsafe(pythFeedId);
        return price.expo;
    }

    /// @notice Refund excess ETH sent beyond the Pyth fees actually consumed.
    function refundExcess(uint256 fee, uint256 msgValue, address recipient) internal {
        uint256 refund = msgValue - fee;
        if (refund > 0) {
            (bool ok,) = recipient.call{value: refund}("");
            if (!ok) revert LibPriceMarketValidator.ETHRefundFailed();
        }
    }

    /// @notice Parse each submitted VAA individually and return the price whose
    ///         publishTime is the smallest value in `[fromTime, fromTime + window]`.
    ///         Selecting the earliest in-range VAA prevents resolvers from biasing the
    ///         chosen price by reordering `pythUpdateData`.
    ///
    ///         For deferred Up/Down markets the same submitted array carries VAAs for
    ///         two windows (open and close). VAAs outside the window-under-test cause
    ///         `parsePriceFeedUpdates` to revert with `PriceFeedNotFoundWithinRange` —
    ///         that revert is caught and the VAA is skipped, so out-of-range entries
    ///         contribute nothing to this window's selection (they're picked up by the
    ///         caller's second invocation against the other window). On a caught
    ///         revert the forwarded `singleFee` is rolled back with the call and
    ///         remains in the Diamond's balance; the caller's `refundExcess` returns
    ///         any unspent value to the resolver.
    ///
    ///         Returns `(price, publishTime, found, feeConsumed)`. When `found == false`
    ///         no submitted VAA fell in `[fromTime, fromTime + window]` — the caller
    ///         must revert with a context-specific error (`NoOpenPriceInWindow` /
    ///         `NoClosePriceInWindow`).
    function pickEarliestInWindow(
        bytes32 pythFeedId,
        bytes[] calldata pythUpdateData,
        uint256 fromTime,
        uint256 window
    ) internal returns (int64 finalPrice, uint64 finalPublishTime, bool found, uint256 feeConsumed) {
        if (pythUpdateData.length == 0) return (0, 0, false, 0);

        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = pythFeedId;
        uint64 minPT = uint64(fromTime);
        uint64 maxPT = uint64(fromTime + window);

        uint64 earliestPublishTime = type(uint64).max;
        bytes[] memory single = new bytes[](1);

        for (uint256 i = 0; i < pythUpdateData.length; i++) {
            single[0] = pythUpdateData[i];
            uint256 singleFee = pyth.getUpdateFee(single);
            try pyth.parsePriceFeedUpdates{value: singleFee}(single, feedIds, minPT, maxPT) returns (
                PythStructs.PriceFeed[] memory feeds
            ) {
                feeConsumed += singleFee;
                uint64 pt = uint64(feeds[0].price.publishTime);
                if (pt < earliestPublishTime) {
                    earliestPublishTime = pt;
                    finalPrice = feeds[0].price.price;
                    finalPublishTime = pt;
                    found = true;
                }
            } catch {
                // Out-of-range VAA for THIS window. The forwarded singleFee is rolled
                // back with the reverted external call and stays in the Diamond's
                // balance for refund.
                continue;
            }
        }
    }
}
