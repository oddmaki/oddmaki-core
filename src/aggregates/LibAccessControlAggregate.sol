// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibAccessControlStorage} from "../storage/LibAccessControlStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {MarketRegistryData} from "../interfaces/Types.sol";

/**
 * @title LibAccessControlAggregate
 * @notice Mutations for access control configuration.
 *         Only venue operators can set market-level AC overrides.
 */
library LibAccessControlAggregate {
    function setMarketTradingAC(uint256 marketId, address acContract, address caller) internal {
        MarketRegistryData storage market = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        LibVenueValidator.requireActiveVenueOperator(market.venueId, caller);
        LibAccessControlStorage.setMarketTradingAC(marketId, acContract);
    }

    function removeMarketTradingAC(uint256 marketId, address caller) internal {
        MarketRegistryData storage market = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        LibVenueValidator.requireActiveVenueOperator(market.venueId, caller);
        LibAccessControlStorage.setMarketTradingAC(marketId, address(0));
    }
}
