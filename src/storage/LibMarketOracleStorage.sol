// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketOracleData} from "../interfaces/Types.sol";

/**
 * @title LibMarketOracleStorage
 * @notice Market oracle (UMA/CTF): questionId → MarketOracleData. Condition, outcomes, UMA economics.
 */
library LibMarketOracleStorage {
    bytes32 constant STORAGE_POSITION = keccak256("oddmaki.storage.market.oracle");

    struct Storage {
        mapping(bytes32 => MarketOracleData) byQuestionId;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function getMarketOracleData(bytes32 questionId) internal view returns (MarketOracleData storage) {
        return getStorage().byQuestionId[questionId];
    }

    function marketOracleDataExists(bytes32 questionId) internal view returns (bool) {
        return getMarketOracleData(questionId).initialized;
    }
}
