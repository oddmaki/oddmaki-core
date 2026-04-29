// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";

/**
 * @title LibProtocolAggregate
 * @notice Protocol-wide writes (e.g. set vault). Access control is the caller's responsibility.
 */
library LibProtocolAggregate {
    function setVault(address vault) internal {
        require(vault != address(0), "Invalid vault");
        LibProtocolStorage.getStorage().vault = vault;
    }

    function setProtocolTreasury(address treasury) internal {
        require(treasury != address(0), "Invalid treasury");
        LibProtocolStorage.getStorage().protocolTreasury = treasury;
    }

    function setUmaOracle(address oracle) internal {
        require(oracle != address(0), "Invalid UMA oracle");
        LibProtocolStorage.getStorage().umaOracle = oracle;
    }

    function setUmaIdentifier(bytes32 identifier) internal {
        require(identifier != bytes32(0), "Invalid identifier");
        LibProtocolStorage.getStorage().umaIdentifier = identifier;
    }

    function setCollateralWhitelisted(address token, bool whitelisted) internal {
        require(token != address(0), "Invalid token");
        LibProtocolStorage.getStorage().collateralWhitelist[token] = whitelisted;
    }

    function setProtocolPaused(bool paused) internal {
        LibProtocolStorage.getStorage().protocolPaused = paused;
    }

    function setVenueSuspended(uint256 venueId, bool suspended) internal {
        LibProtocolStorage.getStorage().venueSuspended[venueId] = suspended;
    }

    function setProtocolFeeBps(uint256 bps) internal {
        require(bps <= 200, "Protocol fee exceeds max");
        LibProtocolStorage.getStorage().protocolFeeBps = bps;
    }
}
