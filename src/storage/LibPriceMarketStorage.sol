// SPDX-License-Identifier: MIT
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

    // Duration constraints
    uint256 constant MIN_DURATION = 300; // 5 minutes
    uint256 constant MAX_DURATION = 31_536_000; // 1 year
    uint256 constant DEFAULT_RESOLUTION_WINDOW = 60; // ±60 seconds
    // Upper bound on the resolution window the creator may request. An unbounded
    // window lets a creator cherry-pick an archived Pyth VAA hours after closeTime
    // and steer the outcome; 5 minutes is a tight compromise between liveness
    // (wallet/bundler latency) and attack surface.
    uint256 constant MAX_RESOLUTION_WINDOW = 300; // 5 minutes

    // Opening price staleness window (see captureOpenPrice).
    // The exploit requires VAAs that are hours-to-days old; 5 minutes blocks it
    // with massive margin while accommodating slow wallet signing flows.
    uint256 constant DEFAULT_OPEN_MAX_STALENESS = 300; // 5 minutes
    // Small forward tolerance for Hermes/block clock drift.
    uint64 constant OPEN_FUTURE_SKEW = 10;

    struct Storage {
        mapping(uint256 => PriceMarket) byMarketId;
        address pythContract;
        uint256 openMaxStaleness; // 0 => use DEFAULT_OPEN_MAX_STALENESS
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

    function getOpenMaxStaleness() internal view returns (uint256) {
        uint256 v = getStorage().openMaxStaleness;
        return v == 0 ? DEFAULT_OPEN_MAX_STALENESS : v;
    }

    function isPriceMarket(uint256 marketId) internal view returns (bool) {
        return getStorage().byMarketId[marketId].feedId != bytes32(0);
    }
}
