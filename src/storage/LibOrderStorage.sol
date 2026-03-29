// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Order} from "../interfaces/Types.sol";

/**
 * @title LibOrderStorage
 * @notice Order domain storage: layout and read-only accessors.
 * Writes and events live in LibOrderAggregate.
 */
library LibOrderStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.orders");

    struct Storage {
        mapping(uint256 => Order) orders;
        uint256 nextOrderId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    // -------------------------------------------------------------------------
    // Read-only accessors
    // -------------------------------------------------------------------------

    function getOrder(uint256 orderId) internal view returns (Order storage) {
        return getStorage().orders[orderId];
    }

    function orderExists(uint256 orderId) internal view returns (bool) {
        return getOrder(orderId).id != 0;
    }

    /// @notice Next ID that would be assigned (read-only). Creation allocates internally via LibOrderAggregate.createOrder.
    function getNextOrderId() internal view returns (uint256) {
        return getStorage().nextOrderId;
    }
}
