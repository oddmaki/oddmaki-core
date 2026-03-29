// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibFillStorage} from "../storage/LibFillStorage.sol";
import {Fill, SettlementPath} from "../interfaces/Types.sol";

/**
 * @title LibFillAggregate
 * @notice Mutation-only aggregate for fill records. Allocates fill IDs and writes Fill structs.
 */
library LibFillAggregate {
    function recordFill(
        uint256 marketId,
        SettlementPath path,
        uint256 order1Id,
        uint256 order2Id,
        uint256 qty,
        uint256 priceTick
    ) internal returns (uint256 fillId) {
        LibFillStorage.Storage storage s = LibFillStorage.getStorage();
        fillId = s.nextFillId + 1;
        s.nextFillId = fillId;

        s.fills[fillId] = Fill({
            id: fillId,
            marketId: marketId,
            path: path,
            order1Id: order1Id,
            order2Id: order2Id,
            qty: qty,
            priceTick: priceTick,
            operator: msg.sender
        });
    }
}
