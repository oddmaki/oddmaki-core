// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {IPythExtended} from "../../src/interfaces/IPythExtended.sol";

/// @title MockPythUnique
/// @notice Test mock that extends `MockPyth` with `parsePriceFeedUpdatesUnique`.
///         The vendored `pyth-sdk-solidity` v2.2.0 predates the unique-parse
///         function but the deployed Pyth contracts on Base support it. This
///         mock simulates the on-chain semantics for tests:
///
///         A submitted update is accepted only when both
///         - `publishTime` ∈ `[minPublishTime, maxPublishTime]`
///         - `prevPublishTime` < `minPublishTime`
///         hold; otherwise the call reverts with `PriceFeedNotFoundWithinRange`,
///         matching the failure surface the production library uses for
///         "no first-in-window VAA submitted".
contract MockPythUnique is MockPyth, IPythExtended {
    constructor(uint validTimePeriod, uint singleUpdateFeeInWei) MockPyth(validTimePeriod, singleUpdateFeeInWei) {}

    /// @notice Build a unique-parse-compatible VAA payload. Bundles the standard
    ///         `PriceFeed` struct with the encoded `prevPublishTime` that the
    ///         on-chain Pyth contract carries in its wire format.
    function createPriceFeedUpdateDataUnique(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 prevPublishTime,
        uint64 publishTime
    ) external pure returns (bytes memory) {
        PythStructs.PriceFeed memory priceFeed;
        priceFeed.id = id;
        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;
        priceFeed.emaPrice.price = emaPrice;
        priceFeed.emaPrice.conf = emaConf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;
        return abi.encode(priceFeed, prevPublishTime);
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable override returns (PythStructs.PriceFeed[] memory feeds) {
        uint requiredFee = getUpdateFee(updateData);
        if (msg.value < requiredFee) revert PythErrors.InsufficientFee();

        feeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint i = 0; i < priceIds.length; i++) {
            bool found = false;
            for (uint j = 0; j < updateData.length; j++) {
                (PythStructs.PriceFeed memory pf, uint64 prevPubTime) =
                    abi.decode(updateData[j], (PythStructs.PriceFeed, uint64));
                if (pf.id != priceIds[i]) continue;

                uint publishTime = pf.price.publishTime;
                if (publishTime < minPublishTime || publishTime > maxPublishTime) continue;

                // Uniqueness: the VAA must be the FIRST update at or after
                // minPublishTime. If the previous publish lies inside the
                // window, an earlier in-range VAA exists and this one is
                // not the first.
                if (prevPubTime >= minPublishTime) continue;

                feeds[i] = pf;
                found = true;
                break;
            }
            if (!found) revert PythErrors.PriceFeedNotFoundWithinRange();
        }
    }
}
