// SPDX-License-Identifier: MIT
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
