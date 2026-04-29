// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketGroupStorage} from "../storage/LibMarketGroupStorage.sol";
import {MarketGroupData, MarketGroupItem, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title LibMarketGroupValidator
 * @notice Market group validation logic and errors. Only reads storage — no mutations.
 *         Used by aggregates and facets to enforce market group invariants.
 */
library LibMarketGroupValidator {
    // ---- Constants ----
    uint256 constant MAX_MARKETS_PER_GROUP = 50;
    uint256 constant MIN_MARKETS_FOR_ACTIVATION = 2;

    // ---- Errors: existence / ownership ----
    error MarketGroupNotFound();
    error NotGroupCreator();
    error GroupNotDraft();
    error GroupNotActive();

    // ---- Errors: input validation ----
    error InvalidQuestion();
    error InsufficientMarkets();
    error TooManyMarkets();
    error MarketNotPlaceholder();

    // ---- Existence / ownership checks ----

    /// @notice Group must exist.
    function requireGroupExists(uint256 groupId) internal view {
        if (!LibMarketGroupStorage.groupExists(groupId)) revert MarketGroupNotFound();
    }

    /// @notice Group must exist and caller must be the creator.
    function requireGroupCreator(uint256 groupId, address caller) internal view {
        requireGroupExists(groupId);
        if (LibMarketGroupStorage.getMarketGroupData(groupId).creator != caller) revert NotGroupCreator();
    }

    /// @notice Group must exist, be Draft, and caller must be creator.
    function requireDraftGroupCreator(uint256 groupId, address caller) internal view {
        requireGroupCreator(groupId, caller);
        if (LibMarketGroupStorage.getMarketGroupData(groupId).status != MarketStatus.Draft) revert GroupNotDraft();
    }

    /// @notice Group must exist, be Active, and caller must be creator.
    function requireActiveGroupCreator(uint256 groupId, address caller) internal view {
        requireGroupCreator(groupId, caller);
        if (LibMarketGroupStorage.getMarketGroupData(groupId).status != MarketStatus.Active) revert GroupNotActive();
    }

    // ---- Input validation ----

    function validateCreateGroupParams(string calldata question) internal pure {
        if (bytes(question).length == 0) revert InvalidQuestion();
    }

    /// @notice Validate that a market can be added to the group.
    function validateAddMarket(uint256 groupId) internal view {
        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        if (group.marketIds.length >= MAX_MARKETS_PER_GROUP) revert TooManyMarkets();
    }

    /// @notice Validate that a group can be activated (>= 2 total markets, >= 1 non-placeholder).
    function validateActivation(uint256 groupId) internal view {
        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        if (group.marketIds.length < MIN_MARKETS_FOR_ACTIVATION) revert InsufficientMarkets();

        // M-9: Require at least one non-placeholder market so the group has tradeable markets
        LibMarketGroupStorage.Storage storage s = LibMarketGroupStorage.getStorage();
        bool hasNonPlaceholder = false;
        for (uint256 i = 0; i < group.marketIds.length; i++) {
            if (!s.itemByMarketId[group.marketIds[i]].isPlaceholder) {
                hasNonPlaceholder = true;
                break;
            }
        }
        if (!hasNonPlaceholder) revert InsufficientMarkets();
    }

    /// @notice Validate that a market is a placeholder.
    function requirePlaceholder(uint256 marketId) internal view {
        MarketGroupItem storage item = LibMarketGroupStorage.getMarketGroupItem(marketId);
        if (!item.isPlaceholder) revert MarketNotPlaceholder();
    }
}
