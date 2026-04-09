// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {MarketRegistryData, MarketStatus} from "../interfaces/Types.sol";
import {LibTickSizeValidator} from "../validators/LibTickSizeValidator.sol";

/**
 * @title LibMarketRegistryAggregate
 * @notice Writes for market registry: create registry row, set status, set questionId→marketId.
 */
library LibMarketRegistryAggregate {
    error InvalidMarketId();
    error RegistryAlreadyExists();

    /// @notice Write registry data and set reverse index questionId → marketId. Does not allocate id (call allocateMarketId first).
    function createRegistry(
        uint256 marketId,
        uint256 venueId,
        address creator,
        MarketStatus status,
        uint256 groupId,
        bytes32 questionId,
        address oracle,
        uint256 tickSize
    ) internal returns (MarketRegistryData memory data) {
        if (marketId == 0) revert InvalidMarketId();
        LibTickSizeValidator.requireValidTickSize(tickSize);

        LibMarketRegistryStorage.Storage storage s = LibMarketRegistryStorage.getStorage();
        if (s.byMarketId[marketId].marketId != 0) revert RegistryAlreadyExists();

        data = MarketRegistryData({
            marketId: marketId,
            venueId: venueId,
            creator: creator,
            status: status,
            groupId: groupId,
            questionId: questionId,
            oracle: oracle,
            tickSize: tickSize,
            venueFeeBps: 0,
            creatorFeeBps: 0,
            protocolFeeBps: 0
        });
        s.byMarketId[marketId] = data;
        s.marketIdByQuestionId[questionId] = marketId;
        return data;
    }

    /// @notice Snapshot fee BPS onto market registry (immutable per market).
    function setFeeSnapshot(uint256 marketId, uint256 venueFeeBps, uint256 creatorFeeBps, uint256 protocolFeeBps) internal {
        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        registry.venueFeeBps = venueFeeBps;
        registry.creatorFeeBps = creatorFeeBps;
        registry.protocolFeeBps = protocolFeeBps;
    }

    function setStatus(uint256 marketId, MarketStatus status) internal {
        LibMarketRegistryStorage.getMarketRegistryData(marketId).status = status;
    }
}
