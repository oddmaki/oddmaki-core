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
