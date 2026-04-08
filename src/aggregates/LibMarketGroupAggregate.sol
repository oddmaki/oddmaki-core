// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibMarketGroupStorage} from "../storage/LibMarketGroupStorage.sol";
import {MarketGroupData, MarketGroupItem, MarketStatus} from "../interfaces/Types.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/**
 * @title LibMarketGroupAggregate
 * @notice Own-storage-only mutations for the MarketGroup domain (LibMarketGroupStorage).
 *         Cross-domain orchestration (market creation, activation, placeholder lifecycle)
 *         is inlined at the facet level (MarketsFacet, MarketGroupFacet).
 */
library LibMarketGroupAggregate {
    // ---- Create Group ----

    function createGroup(
        address creator,
        uint256 venueId,
        string calldata question,
        string calldata description,
        address collateralToken,
        uint256 tickSize,
        uint256 additionalReward,
        uint64 liveness,
        uint256 reward
    ) internal returns (uint256 groupId) {
        groupId = LibMarketGroupStorage.allocateGroupId();

        LibMarketGroupStorage.Storage storage s = LibMarketGroupStorage.getStorage();
        s.byGroupId[groupId] = MarketGroupData({
            groupId: groupId,
            marketIds: new uint256[](0),
            totalMarkets: 0,
            question: question,
            description: description,
            status: MarketStatus.Draft,
            createdAt: block.timestamp,
            resolvedMarketId: 0,
            creator: creator,
            venueId: venueId,
            collateralToken: IERC20(collateralToken),
            tickSize: tickSize,
            additionalReward: additionalReward,
            liveness: liveness,
            reward: reward
        });
    }

    // ---- Own-storage setters ----

    /// @notice Register a market in the group: push to marketIds array and store item data.
    function addMarketToGroup(uint256 groupId, uint256 marketId, string memory marketName, bool isPlaceholder)
        internal
    {
        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        LibMarketGroupStorage.getStorage().itemByMarketId[marketId] =
            MarketGroupItem({isPlaceholder: isPlaceholder, marketName: marketName});
        group.marketIds.push(marketId);
    }

    /// @notice Lock totalMarkets at current marketIds.length (immutable for conversion math).
    function lockTotalMarkets(uint256 groupId) internal {
        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        group.totalMarkets = group.marketIds.length;
    }

    /// @notice Set group status (Draft -> Active -> Resolved).
    function setGroupStatus(uint256 groupId, MarketStatus status) internal {
        LibMarketGroupStorage.getMarketGroupData(groupId).status = status;
    }

    /// @notice Set the winning market ID after resolution cascade.
    function setResolvedMarketId(uint256 groupId, uint256 marketId) internal {
        LibMarketGroupStorage.getMarketGroupData(groupId).resolvedMarketId = marketId;
    }

    /// @notice Convert a placeholder into a real market (update item data).
    function updatePlaceholderItem(uint256 marketId, string memory marketName) internal {
        MarketGroupItem storage item = LibMarketGroupStorage.getStorage().itemByMarketId[marketId];
        item.isPlaceholder = false;
        item.marketName = marketName;
    }
}
