// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibTickSizeValidator} from "../validators/LibTickSizeValidator.sol";
import {VenueData} from "../interfaces/Types.sol";

/**
 * @title LibVenueAggregate
 * @notice Mutation-only aggregate for venues. Creates, updates, pauses/unpauses venues.
 *         No getter functions (per diamond architecture rule: getters in Storage or Services).
 */
library LibVenueAggregate {
    // ---- Create ----

    function createVenue(
        address operator,
        string calldata name,
        string calldata metadata,
        address tradingAccessControl,
        address creationAccessControl,
        address feeRecipient,
        uint256 venueFeeBps,
        uint256 creatorFeeBps,
        uint256 defaultTickSize,
        uint256 marketCreationFee,
        uint256 umaRewardAmount,
        uint256 umaMinBond
    ) internal returns (uint256 venueId) {
        LibVenueValidator.validateCreateVenueParams(name, feeRecipient, venueFeeBps, creatorFeeBps, marketCreationFee);
        LibVenueValidator.validateOracleParams(umaMinBond);
        LibTickSizeValidator.requireValidTickSize(defaultTickSize);

        venueId = LibVenueStorage.allocateVenueId();

        LibVenueStorage.getStorage().byVenueId[venueId] = VenueData({
            venueId: venueId,
            operator: operator,
            name: name,
            metadata: metadata,
            tradingAccessControl: tradingAccessControl,
            creationAccessControl: creationAccessControl,
            feeRecipient: feeRecipient,
            venueFeeBps: venueFeeBps,
            creatorFeeBps: creatorFeeBps,
            defaultTickSize: defaultTickSize,
            marketCreationFee: marketCreationFee,
            umaRewardAmount: umaRewardAmount,
            umaMinBond: umaMinBond,
            active: true
        });
    }

    // ---- Update ----

    function updateVenue(
        uint256 venueId,
        address caller,
        string calldata name,
        string calldata metadata,
        address tradingAccessControl,
        address creationAccessControl,
        address feeRecipient
    ) internal {
        LibVenueValidator.requireActiveVenueOperator(venueId, caller);
        LibVenueValidator.validateUpdateVenueParams(name, feeRecipient);

        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        venue.name = name;
        venue.metadata = metadata;
        venue.tradingAccessControl = tradingAccessControl;
        venue.creationAccessControl = creationAccessControl;
        venue.feeRecipient = feeRecipient;
    }

    function updateVenueFees(uint256 venueId, address caller, uint256 venueFeeBps, uint256 creatorFeeBps) internal {
        LibVenueValidator.requireActiveVenueOperator(venueId, caller);
        LibVenueValidator.validateFeeParams(venueFeeBps, creatorFeeBps);

        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        venue.venueFeeBps = venueFeeBps;
        venue.creatorFeeBps = creatorFeeBps;
    }

    function updateVenueOracleParams(uint256 venueId, address caller, uint256 umaRewardAmount, uint256 umaMinBond)
        internal
    {
        LibVenueValidator.requireActiveVenueOperator(venueId, caller);
        LibVenueValidator.validateOracleParams(umaMinBond);

        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        venue.umaRewardAmount = umaRewardAmount;
        venue.umaMinBond = umaMinBond;
    }

    // ---- Pause / Unpause ----

    function pauseVenue(uint256 venueId, address caller) internal {
        LibVenueValidator.requireActiveVenueOperator(venueId, caller);
        LibVenueStorage.getVenueData(venueId).active = false;
    }

    function unpauseVenue(uint256 venueId, address caller) internal {
        LibVenueValidator.requireExistingVenueOperator(venueId, caller);
        LibProtocolValidator.requireVenueNotSuspended(venueId);
        LibVenueStorage.getVenueData(venueId).active = true;
    }
}
