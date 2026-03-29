// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";

/**
 * @title LibProtocolValidator
 * @notice Protocol-level validation logic and errors. Only reads storage — no mutations.
 */
library LibProtocolValidator {
    error CollateralNotWhitelisted();
    error ProtocolPaused();
    error VenueSuspended();

    function requireWhitelistedCollateral(address token) internal view {
        if (!LibProtocolStorage.isCollateralWhitelisted(token)) revert CollateralNotWhitelisted();
    }

    function requireProtocolNotPaused() internal view {
        if (LibProtocolStorage.isProtocolPaused()) revert ProtocolPaused();
    }

    function requireVenueNotSuspended(uint256 venueId) internal view {
        if (LibProtocolStorage.isVenueSuspended(venueId)) revert VenueSuspended();
    }
}
