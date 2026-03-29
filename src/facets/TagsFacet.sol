// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibTagValidator} from "../validators/LibTagValidator.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketGroupValidator} from "../validators/LibMarketGroupValidator.sol";
import {MarketRegistryData} from "../interfaces/Types.sol";

/**
 * @title TagsFacet
 * @author OddMaki Protocol
 * @notice Tag editing for markets and market groups. Creator-only.
 *         Tags are event-only (no storage writes) — indexed by the subgraph.
 */
contract TagsFacet is ReentrancyGuard {
    event MarketTagsUpdated(uint256 indexed marketId, bytes32[] tags);
    event MarketGroupTagsUpdated(uint256 indexed groupId, bytes32[] tags);

    error NotMarketCreator();

    /**
     * @notice Update tags for a standalone market. Event-only, no storage writes.
     * @param marketId The market to update tags for.
     * @param tags     New tag set (replaces previous; max 5).
     */
    function updateMarketTags(uint256 marketId, bytes32[] calldata tags) external nonReentrant {
        LibTagValidator.validateTags(tags);

        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (registry.creator != msg.sender) revert NotMarketCreator();

        emit MarketTagsUpdated(marketId, tags);
    }

    /**
     * @notice Update tags for a market group. Event-only, no storage writes.
     * @param groupId The group to update tags for.
     * @param tags    New tag set (replaces previous; max 5).
     */
    function updateMarketGroupTags(uint256 groupId, bytes32[] calldata tags) external nonReentrant {
        LibTagValidator.validateTags(tags);
        LibMarketGroupValidator.requireGroupCreator(groupId, msg.sender);

        emit MarketGroupTagsUpdated(groupId, tags);
    }
}
