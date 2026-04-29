// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketGroupValidator} from "../validators/LibMarketGroupValidator.sol";
import {MarketRegistryData} from "../interfaces/Types.sol";

/**
 * @title MetadataFacet
 * @author OddMaki Protocol
 * @notice Metadata URI editing for markets and market groups. Creator-only.
 *         Metadata is event-only (no storage writes) — indexed by the subgraph.
 */
contract MetadataFacet is ReentrancyGuard {
    event MarketMetadataUpdated(uint256 indexed marketId, string metadataURI);
    event MarketGroupMetadataUpdated(uint256 indexed groupId, string metadataURI);

    error NotMarketCreator();

    /**
     * @notice Update metadata URI for a standalone market. Event-only, no storage writes.
     * @param marketId    The market to update metadata for.
     * @param metadataURI IPFS URI or URL pointing to the market's metadata JSON.
     */
    function updateMarketMetadata(uint256 marketId, string calldata metadataURI) external nonReentrant {
        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (registry.creator != msg.sender) revert NotMarketCreator();

        emit MarketMetadataUpdated(marketId, metadataURI);
    }

    /**
     * @notice Update metadata URI for a market group. Event-only, no storage writes.
     * @param groupId     The group to update metadata for.
     * @param metadataURI IPFS URI or URL pointing to the group's metadata JSON.
     */
    function updateMarketGroupMetadata(uint256 groupId, string calldata metadataURI) external nonReentrant {
        LibMarketGroupValidator.requireGroupCreator(groupId, msg.sender);

        emit MarketGroupMetadataUpdated(groupId, metadataURI);
    }
}
