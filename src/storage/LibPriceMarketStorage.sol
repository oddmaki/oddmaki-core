// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {PriceMarket} from "../interfaces/Types.sol";

/**
 * @title LibPriceMarketStorage
 * @notice Diamond storage for price markets.
 *         Each price market is an overlay on a standard OddMaki market —
 *         it stores the oracle-specific data (feed, open/close prices, timestamps)
 *         while the underlying market uses the normal registry/trading/oracle storage.
 */
library LibPriceMarketStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.price.market");

    uint256 constant DEFAULT_RESOLUTION_WINDOW = 60; // ±60 seconds
    // Upper bound on the resolution window the creator may request. An unbounded
    // window lets a creator cherry-pick an archived Pyth VAA hours after closeTime
    // and steer the outcome; 5 minutes is a tight compromise between liveness
    // (wallet/bundler latency) and attack surface.
    uint256 constant MAX_RESOLUTION_WINDOW = 300; // 5 minutes

    // Note: no MIN_DURATION / MAX_DURATION. The protocol only requires
    // closeTime > effectiveOpenTime — markets can be arbitrarily short or long.
    // Venue operators and frontends enforce business-level bounds.

    struct Storage {
        mapping(uint256 => PriceMarket) byMarketId;
        address pythContract;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getPriceMarket(uint256 marketId) internal view returns (PriceMarket storage) {
        return getStorage().byMarketId[marketId];
    }

    function getPythContract() internal view returns (address) {
        return getStorage().pythContract;
    }

    function isPriceMarket(uint256 marketId) internal view returns (bool) {
        return getStorage().byMarketId[marketId].feedId != bytes32(0);
    }
}
