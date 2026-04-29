// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMatchingService} from "../services/LibMatchingService.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";

/**
 * @title MatchingFacet
 * @author OddMaki Protocol
 * @notice Order matching engine. Anyone may call matchOrders to advance the order book.
 * @dev The caller (msg.sender) receives the operator fee for each fill executed.
 */
contract MatchingFacet is ReentrancyGuard {
    error MarketNotActive();

    /**
     * @notice Run up to `maxSteps` matching iterations for `marketId`.
     *         Tries normal fills, mint-to-fill, and merge-to-fill in that priority order each step.
     * @param marketId  Market to match.
     * @param maxSteps  Maximum number of fill steps per call (gas budget).
     * @return fillCount Number of fills executed.
     */
    function matchOrders(uint256 marketId, uint256 maxSteps)
        external
        nonReentrant
        returns (uint256 fillCount)
    {
        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        return LibMatchingService.matchOrders(marketId, maxSteps);
    }
}
