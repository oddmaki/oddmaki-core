// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title LibProtocolStorage
 * @notice Protocol-wide settings (e.g. vault address). Writes via init or admin.
 */
library LibProtocolStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.protocol");

    struct Storage {
        address vault;
        address protocolTreasury;
        address umaOracle;
        bytes32 umaIdentifier;
        mapping(address => bool) collateralWhitelist;
        bool protocolPaused;
        mapping(uint256 => bool) venueSuspended;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getVault() internal view returns (address) {
        return getStorage().vault;
    }

    function getProtocolTreasury() internal view returns (address) {
        return getStorage().protocolTreasury;
    }

    function getUmaOracle() internal view returns (address) {
        return getStorage().umaOracle;
    }

    function getUmaIdentifier() internal view returns (bytes32) {
        return getStorage().umaIdentifier;
    }

    function isCollateralWhitelisted(address token) internal view returns (bool) {
        return getStorage().collateralWhitelist[token];
    }

    function isProtocolPaused() internal view returns (bool) {
        return getStorage().protocolPaused;
    }

    function isVenueSuspended(uint256 venueId) internal view returns (bool) {
        return getStorage().venueSuspended[venueId];
    }
}
