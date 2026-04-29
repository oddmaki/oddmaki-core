// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {PriceMarket, FeedProvider} from "../interfaces/Types.sol";

/**
 * @title PriceMarketFacet
 * @author OddMaki Protocol
 * @notice Provider-agnostic read functions for price markets.
 *         Provider-specific config and resolution live in dedicated facets
 *         (e.g., PythResolutionFacet, future ChainlinkResolutionFacet).
 */
contract PriceMarketFacet {
    function getPriceMarket(uint256 marketId)
        external
        view
        returns (
            bytes32 feedId,
            FeedProvider feedProvider,
            uint256 openTime,
            uint256 closeTime,
            int32 priceExpo,
            int64 finalPrice,
            uint256 resolutionWindow,
            bool resolved,
            int64 strikePrice,
            uint256 openPriceTime
        )
    {
        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        return (
            pm.feedId,
            pm.feedProvider,
            pm.openTime,
            pm.closeTime,
            pm.priceExpo,
            pm.finalPrice,
            pm.resolutionWindow,
            pm.resolved,
            pm.strikePrice,
            pm.openPriceTime
        );
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
