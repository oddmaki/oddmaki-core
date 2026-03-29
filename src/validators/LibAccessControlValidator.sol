// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibAccessControlStorage} from "../storage/LibAccessControlStorage.sol";
import {IAccessControl} from "../interfaces/IAccessControl.sol";
import {VenueData, MarketRegistryData} from "../interfaces/Types.sol";

/**
 * @title LibAccessControlValidator
 * @notice Access control validation for venues and markets.
 *         Reads from LibVenueStorage, LibMarketRegistryStorage, and LibAccessControlStorage.
 *         Replaces LibVenueAccessService with the validator pattern.
 *         Operator always bypasses access control.
 */
library LibAccessControlValidator {
    // ---- Errors ----
    error TradingAccessDenied();
    error CreationAccessDenied();

    // ---- Trading access (market-aware, venue fallback) ----

    /// @notice Validate that `caller` can trade on `marketId`. Reverts on failure.
    ///         Checks market-level AC first; falls back to venue-level if unset.
    function validateTradingAccess(address caller, uint256 marketId) internal view {
        MarketRegistryData storage market = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        VenueData storage venue = LibVenueStorage.getVenueData(market.venueId);

        // Venue operator always bypasses
        if (venue.operator == caller) return;

        // Check market-level AC override
        address marketAC = LibAccessControlStorage.getMarketTradingAC(marketId);
        if (marketAC != address(0)) {
            _requireAllowed(marketAC, caller);
            return;
        }

        // Fall back to venue-level trading AC
        if (venue.tradingAccessControl == address(0)) return; // Public

        _requireAllowed(venue.tradingAccessControl, caller);
    }

    /// @notice Check if `user` can trade on `marketId`. Returns bool (no revert).
    function canTrade(address user, uint256 marketId) internal view returns (bool) {
        if (!LibMarketRegistryStorage.marketRegistryDataExists(marketId)) return false;
        MarketRegistryData storage market = LibMarketRegistryStorage.getMarketRegistryData(marketId);

        if (!LibVenueStorage.venueExists(market.venueId)) return false;
        VenueData storage venue = LibVenueStorage.getVenueData(market.venueId);
        if (!venue.active) return false;

        // Operator always bypasses
        if (venue.operator == user) return true;

        // Check market-level AC override
        address marketAC = LibAccessControlStorage.getMarketTradingAC(marketId);
        if (marketAC != address(0)) {
            return _checkAllowed(marketAC, user);
        }

        // Fall back to venue-level trading AC
        if (venue.tradingAccessControl == address(0)) return true; // Public

        return _checkAllowed(venue.tradingAccessControl, user);
    }

    // ---- Venue-level trading access (no market context) ----

    /// @notice Check if `user` can trade in `venueId` at the venue level. Returns bool (no revert).
    function canTradeOnVenue(address user, uint256 venueId) internal view returns (bool) {
        if (!LibVenueStorage.venueExists(venueId)) return false;
        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        if (!venue.active) return false;

        // Operator always bypasses
        if (venue.operator == user) return true;

        // No AC contract = public venue
        if (venue.tradingAccessControl == address(0)) return true;

        return _checkAllowed(venue.tradingAccessControl, user);
    }

    // ---- Creation access (venue-level only) ----

    /// @notice Validate that `caller` can create a market in `venueId`. Reverts on failure.
    ///         Caller must ensure venue exists and is active before calling this.
    function validateCreationAccess(address caller, uint256 venueId) internal view {
        VenueData storage venue = LibVenueStorage.getVenueData(venueId);

        // Operator always bypasses
        if (venue.operator == caller) return;

        // No AC contract = public venue
        if (venue.creationAccessControl == address(0)) return;

        // Delegate to external contract
        try IAccessControl(venue.creationAccessControl).isAllowed(caller) returns (bool result) {
            if (!result) revert CreationAccessDenied();
        } catch {
            revert CreationAccessDenied();
        }
    }

    /// @notice Check if `user` can create markets in `venueId`. Returns bool (no revert).
    function canCreateMarket(address user, uint256 venueId) internal view returns (bool) {
        if (!LibVenueStorage.venueExists(venueId)) return false;
        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        if (!venue.active) return false;

        // Operator always bypasses
        if (venue.operator == user) return true;

        // No AC contract = public venue
        if (venue.creationAccessControl == address(0)) return true;

        return _checkAllowed(venue.creationAccessControl, user);
    }

    // ---- Internal helpers ----

    /// @dev Reverts with TradingAccessDenied if the AC contract denies the user.
    function _requireAllowed(address acContract, address user) private view {
        try IAccessControl(acContract).isAllowed(user) returns (bool result) {
            if (!result) revert TradingAccessDenied();
        } catch {
            revert TradingAccessDenied();
        }
    }

    /// @dev Returns the result of the AC check; false on revert.
    function _checkAllowed(address acContract, address user) private view returns (bool) {
        try IAccessControl(acContract).isAllowed(user) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
}
