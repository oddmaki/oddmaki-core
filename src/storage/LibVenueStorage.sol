// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueData} from "../interfaces/Types.sol";

/**
 * @title LibVenueStorage
 * @notice Diamond storage for venues: venueId -> VenueData, nextVenueId counter.
 *         Follows the same pattern as LibMarketRegistryStorage.
 */
library LibVenueStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.venue");

    struct Storage {
        mapping(uint256 => VenueData) byVenueId;
        uint256 nextVenueId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getVenueData(uint256 venueId) internal view returns (VenueData storage) {
        return getStorage().byVenueId[venueId];
    }

    /// @notice Allocate next venue id (increment first, then return). IDs start at 1.
    function allocateVenueId() internal returns (uint256 venueId) {
        Storage storage s = getStorage();
        venueId = s.nextVenueId + 1;
        s.nextVenueId = venueId;
        return venueId;
    }

    function getNextVenueId() internal view returns (uint256) {
        return getStorage().nextVenueId;
    }

    function venueExists(uint256 venueId) internal view returns (bool) {
        return getVenueData(venueId).venueId != 0;
    }
}
