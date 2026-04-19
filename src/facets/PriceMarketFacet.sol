// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {PriceMarket} from "../interfaces/Types.sol";

/**
 * @title PriceMarketFacet
 * @author OddMaki Protocol
 * @notice Provider-agnostic read functions for price markets.
 *         Provider-specific config and resolution live in dedicated facets
 *         (e.g., PythResolutionFacet, future ChainlinkResolutionFacet).
 */
contract PriceMarketFacet {
    function getPriceMarket(uint256 marketId) external view returns (PriceMarket memory) {
        return LibPriceMarketStorage.getPriceMarket(marketId);
    }

    function isPriceMarket(uint256 marketId) external view returns (bool) {
        return LibPriceMarketStorage.isPriceMarket(marketId);
    }

    function canResolvePriceMarket(uint256 marketId) external view returns (bool) {
        if (!LibPriceMarketStorage.isPriceMarket(marketId)) return false;
        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        return !pm.resolved && block.timestamp >= pm.closeTime;
    }
}
