// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {FeedProvider} from "../interfaces/Types.sol";

/**
 * @title LibPriceMarketValidator
 * @notice Read-only guard checks for price market operations.
 *         Errors are defined here, not in services or aggregates.
 */
library LibPriceMarketValidator {
    error PythContractNotConfigured();
    error DurationTooShort();
    error DurationTooLong();
    error CloseTimeTooSoon();
    error CloseTimeTooFar();
    error ZeroStrikePrice();
    error NotPriceMarket();
    error PriceMarketAlreadyResolved();
    error CloseTimeNotReached();
    error FeedProviderMismatch(FeedProvider expected, FeedProvider actual);
    error InsufficientPythFee();
    error MarketNotActive();
    error ZeroAddress();
    error ETHRefundFailed();
    error ResolutionWindowTooLarge();
    error NoValidPriceUpdate();

    function requirePythConfigured() internal view {
        if (LibPriceMarketStorage.getPythContract() == address(0)) {
            revert PythContractNotConfigured();
        }
    }

    function requireValidDuration(uint256 duration) internal pure {
        if (duration < LibPriceMarketStorage.MIN_DURATION) revert DurationTooShort();
        if (duration > LibPriceMarketStorage.MAX_DURATION) revert DurationTooLong();
    }

    function requireValidCloseTime(uint256 closeTime) internal view {
        if (closeTime < block.timestamp + LibPriceMarketStorage.MIN_DURATION) revert CloseTimeTooSoon();
        if (closeTime > block.timestamp + LibPriceMarketStorage.MAX_DURATION) revert CloseTimeTooFar();
    }

    function requireNonZeroStrikePrice(int64 strikePrice) internal pure {
        if (strikePrice <= 0) revert ZeroStrikePrice();
    }

    function requireIsPriceMarket(uint256 marketId) internal view {
        if (!LibPriceMarketStorage.isPriceMarket(marketId)) revert NotPriceMarket();
    }

    function requireNotResolved(uint256 marketId) internal view {
        if (LibPriceMarketStorage.getPriceMarket(marketId).resolved) {
            revert PriceMarketAlreadyResolved();
        }
    }

    function requireCloseTimeReached(uint256 marketId) internal view {
        if (block.timestamp < LibPriceMarketStorage.getPriceMarket(marketId).closeTime) {
            revert CloseTimeNotReached();
        }
    }

    function requireFeedProvider(uint256 marketId, FeedProvider expected) internal view {
        FeedProvider actual = LibPriceMarketStorage.getPriceMarket(marketId).feedProvider;
        if (actual != expected) revert FeedProviderMismatch(expected, actual);
    }

    function requireValidResolutionWindow(uint256 window) internal pure {
        if (window > LibPriceMarketStorage.MAX_RESOLUTION_WINDOW) revert ResolutionWindowTooLarge();
    }
}
