// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketGroupData, MarketGroupItem} from "../interfaces/Types.sol";

/**
 * @title LibMarketGroupStorage
 * @notice Diamond storage for market groups: groupId -> MarketGroupData, marketId -> MarketGroupItem.
 */
library LibMarketGroupStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.marketgroup");

    struct Storage {
        mapping(uint256 => MarketGroupData) byGroupId;
        mapping(uint256 => MarketGroupItem) itemByMarketId;
        uint256 nextGroupId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getMarketGroupData(uint256 groupId) internal view returns (MarketGroupData storage) {
        return getStorage().byGroupId[groupId];
    }

    function getMarketGroupItem(uint256 marketId) internal view returns (MarketGroupItem storage) {
        return getStorage().itemByMarketId[marketId];
    }

    /// @notice Allocate next group id (increment first, then return). IDs start at 1.
    function allocateGroupId() internal returns (uint256 groupId) {
        Storage storage s = getStorage();
        groupId = s.nextGroupId + 1;
        s.nextGroupId = groupId;
        return groupId;
    }

    function getNextGroupId() internal view returns (uint256) {
        return getStorage().nextGroupId;
    }

    function groupExists(uint256 groupId) internal view returns (bool) {
        return getMarketGroupData(groupId).groupId != 0;
    }
}
