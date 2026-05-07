// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibProtocolValidator} from "./LibProtocolValidator.sol";
import {VenueData} from "../interfaces/Types.sol";

/**
 * @title LibVenueValidator
 * @notice Venue validation logic and errors. Only reads storage — no mutations.
 *         Used by aggregates, services, and facets to enforce venue invariants.
 */
library LibVenueValidator {
    // ---- Errors: existence / ownership ----
    error VenueNotFound();
    error VenueInactive();
    error OnlyVenueOperator();

    // ---- Errors: input validation ----
    error InvalidVenueName();
    error InvalidVenueFee();
    error InvalidCreatorFee();
    error InvalidFeeRecipient();
    error InvalidUmaMinBond();

    // ---- Existence / ownership checks ----

    /// @notice Venue must exist, be active (not protocol-paused, not suspended, not operator-paused), and caller must be the operator.
    function requireActiveVenueOperator(uint256 venueId, address caller) internal view {
        LibProtocolValidator.requireProtocolNotPaused();
        if (!LibVenueStorage.venueExists(venueId)) revert VenueNotFound();
        LibProtocolValidator.requireVenueNotSuspended(venueId);
        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        if (!venue.active) revert VenueInactive();
        if (venue.operator != caller) revert OnlyVenueOperator();
    }

    /// @notice Venue must exist and caller must be operator. Venue can be inactive (for unpause).
    function requireExistingVenueOperator(uint256 venueId, address caller) internal view {
        if (!LibVenueStorage.venueExists(venueId)) revert VenueNotFound();
        if (LibVenueStorage.getVenueData(venueId).operator != caller) revert OnlyVenueOperator();
    }

    /// @notice Venue must exist and be active (not protocol-paused, not suspended, not operator-paused).
    function requireActiveVenue(uint256 venueId) internal view {
        LibProtocolValidator.requireProtocolNotPaused();
        if (!LibVenueStorage.venueExists(venueId)) revert VenueNotFound();
        LibProtocolValidator.requireVenueNotSuspended(venueId);
        if (!LibVenueStorage.getVenueData(venueId).active) revert VenueInactive();
    }

    /// @notice The venue that owns the given market must be active.
    function requireActiveVenueForMarket(uint256 marketId) internal view {
        uint256 venueId = LibMarketRegistryStorage.getMarketRegistryData(marketId).venueId;
        requireActiveVenue(venueId);
    }

    // ---- Input validation ----

    function validateCreateVenueParams(
        string calldata name,
        address feeRecipient,
        uint256 venueFeeBps,
        uint256 creatorFeeBps
    ) internal pure {
        if (bytes(name).length == 0) revert InvalidVenueName();
        if (venueFeeBps < 1 || venueFeeBps > 200) revert InvalidVenueFee();
        if (creatorFeeBps > venueFeeBps) revert InvalidCreatorFee();
        if (feeRecipient == address(0)) revert InvalidFeeRecipient();
    }

    function validateUpdateVenueParams(string calldata name, address feeRecipient) internal pure {
        if (bytes(name).length == 0) revert InvalidVenueName();
        if (feeRecipient == address(0)) revert InvalidFeeRecipient();
    }

    function validateFeeParams(uint256 venueFeeBps, uint256 creatorFeeBps) internal pure {
        if (venueFeeBps < 1 || venueFeeBps > 200) revert InvalidVenueFee();
        if (creatorFeeBps > venueFeeBps) revert InvalidCreatorFee();
    }

    function validateOracleParams(uint256 umaMinBond) internal pure {
        if (umaMinBond == 0) revert InvalidUmaMinBond();
    }
}
