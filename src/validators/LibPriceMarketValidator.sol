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
    error CloseTimeNotAfterOpenTime();
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
    error InvalidOpenTime();
    error NoOpenPriceInWindow();
    error NoClosePriceInWindow();

    function requirePythConfigured() internal view {
        if (LibPriceMarketStorage.getPythContract() == address(0)) {
            revert PythContractNotConfigured();
        }
    }

    /// @notice Validates the user-supplied `openTime`. `0` is the immediate sentinel —
    ///         the facet resolves it to `block.timestamp`. Any other value must be
    ///         strictly in the future. No upper bound: scheduling horizon is a venue/UI
    ///         concern, not a protocol invariant.
    function requireValidOpenTime(uint256 openTime) internal view {
        if (openTime != 0 && openTime <= block.timestamp) revert InvalidOpenTime();
    }

    /// @notice The only protocol-level duration invariant: trading must end strictly
    ///         after it begins. Any positive duration is allowed. Business-level
    ///         bounds (minimum useful trading time, maximum listing horizon) belong
    ///         to venues and frontends.
    function requireValidCloseTime(uint256 effectiveOpenTime, uint256 closeTime) internal pure {
        if (closeTime <= effectiveOpenTime) revert CloseTimeNotAfterOpenTime();
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
