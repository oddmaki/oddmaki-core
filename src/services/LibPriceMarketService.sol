// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {IPythExtended} from "../interfaces/IPythExtended.sol";
import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";
import {LibMarketCreationService} from "./LibMarketCreationService.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {MarketStatus, FeedProvider, PriceMarket} from "../interfaces/Types.sol";

/**
 * @title LibPriceMarketService
 * @notice Business logic for Pyth-powered price markets: deterministic price selection
 *         from a window of submitted VAAs, ETH refund handling, and feed metadata reads.
 */
library LibPriceMarketService {
    /// @notice Emitted when a Pyth price-market overlay is created — by BOTH the CLOB
    ///         (PythResolutionFacet.createPriceMarketPyth) and DPM (DpmMarketFacet.createDpmPriceMarket)
    ///         paths. Declared and emitted here (mirroring MarketCreated in LibMarketCreationService) so
    ///         the indexer always receives it regardless of which facet created the market. The signature
    ///         must stay byte-for-byte stable — the subgraph (handlePriceMarketCreatedPyth) decodes it.
    event PriceMarketCreatedPyth(
        uint256 indexed marketId,
        uint256 indexed venueId,
        bytes32 indexed pythFeedId,
        int64 strikePrice,
        int32 priceExpo,
        uint256 openTime,
        uint256 closeTime,
        uint256 resolutionWindow
    );

    /// @notice Read the price exponent for a Pyth feed without updating.
    ///         Uses getPriceUnsafe which returns the last stored data (no fee required).
    ///         The expo field is fixed per feed and always valid regardless of staleness.
    function getFeedExponent(bytes32 pythFeedId) internal view returns (int32) {
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        PythStructs.Price memory price = pyth.getPriceUnsafe(pythFeedId);
        return price.expo;
    }

    /// @notice Create the base OddMaki market + Pyth price overlay shared by `createPriceMarketPyth`
    ///         and the DPM price-market path. Does NOT do venue/access/collateral guards or collect
    ///         the creation fee — those stay in the calling facet (they need msg.sender / differ per
    ///         entry). Steps: read the feed exponent, create a standard Active market with the UMA
    ///         reward NOT escrowed (additionalReward 0), force `oracle.reward = 0` (price markets are
    ///         Pyth-only; a non-zero reward would make a UMA fallback transfer funds the Diamond never
    ///         held and lock the market — see PythResolutionFacet), then write the price overlay.
    /// @return marketId The allocated market id.
    function createPriceMarketBase(
        address creator,
        uint256 venueId,
        bytes calldata ancillaryData,
        string[] calldata outcomes,
        uint256 tickSize,
        address collateralToken,
        uint64 liveness,
        bytes32[] calldata tags,
        bytes32 pythFeedId,
        int64 strikePrice,
        uint256 effectiveOpenTime,
        uint256 closeTime,
        uint256 resolutionWindow
    ) internal returns (uint256 marketId) {
        int32 priceExpo = getFeedExponent(pythFeedId);

        marketId = LibMarketCreationService.createMarket(
            creator,
            venueId,
            ancillaryData,
            outcomes,
            tickSize,
            collateralToken,
            0, // additionalReward: price markets do not escrow a UMA reward
            liveness,
            0, // groupId: standalone
            MarketStatus.Active,
            tags
        );

        // Force the stored UMA reward to zero (createMarket copies venue.umaRewardAmount, but price
        // markets never escrowed it). Keeps any UMA fallback a safe no-op.
        LibMarketOracleStorage.getMarketOracleData(
            LibMarketRegistryStorage.getMarketRegistryData(marketId).questionId
        ).reward = 0;

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        pm.feedId = pythFeedId;
        pm.feedProvider = FeedProvider.PYTH;
        pm.openTime = effectiveOpenTime;
        pm.closeTime = closeTime;
        pm.priceExpo = priceExpo;
        pm.resolutionWindow =
            resolutionWindow > 0 ? resolutionWindow : LibPriceMarketStorage.DEFAULT_RESOLUTION_WINDOW;
        pm.strikePrice = strikePrice;
        // openPriceTime stays 0; the resolver fills it for deferred markets at resolution time.

        // Emit the price-overlay creation event here (not in the facet) so every creation path —
        // CLOB and DPM — indexes identically. MarketCreated already fired inside createMarket above.
        emit PriceMarketCreatedPyth(
            marketId, venueId, pythFeedId, strikePrice, priceExpo, effectiveOpenTime, closeTime, pm.resolutionWindow
        );
    }

    /// @notice Refund excess ETH sent beyond the Pyth fees actually consumed.
    function refundExcess(uint256 fee, uint256 msgValue, address recipient) internal {
        uint256 refund = msgValue - fee;
        if (refund > 0) {
            (bool ok,) = recipient.call{value: refund}("");
            if (!ok) revert LibPriceMarketValidator.ETHRefundFailed();
        }
    }

    /// @notice Parse each submitted VAA individually and return the price for the
    ///         FIRST in-range Pyth update in `[fromTime, fromTime + window]`.
    ///         Uses `parsePriceFeedUpdatesUnique`, which enforces that the
    ///         submitted VAA's encoded `prevPublishTime` is strictly less than
    ///         `minPublishTime`. Any later in-window VAA has a `prevPublishTime`
    ///         that falls inside the window and is rejected by Pyth. This makes
    ///         the chosen price deterministic per (feed, window) regardless of
    ///         which VAAs the caller submits or in what order, closing an
    ///         outcome-manipulation vector where a resolver could omit an
    ///         earlier in-range VAA whose price favored the opposite outcome.
    ///
    ///         For deferred Up/Down markets the same submitted array carries VAAs for
    ///         two windows (open and close). VAAs outside the window-under-test, and
    ///         non-earliest VAAs within the window, both cause `parsePriceFeedUpdatesUnique`
    ///         to revert — the revert is caught and the VAA is skipped, so out-of-range
    ///         and non-first entries contribute nothing to this window's selection
    ///         (the earliest in-range VAA, submitted in either position, is selected).
    ///         On a caught revert the forwarded `singleFee` is rolled back with the
    ///         call and remains in the Diamond's balance; the caller's `refundExcess`
    ///         returns any unspent value to the resolver.
    ///
    ///         Returns `(price, publishTime, found, feeConsumed)`. When `found == false`
    ///         no submitted VAA was both in-range AND the first update at or after
    ///         `fromTime` — the caller must revert with a context-specific error
    ///         (`NoOpenPriceInWindow` / `NoClosePriceInWindow`).
    function pickFirstInWindow(
        bytes32 pythFeedId,
        bytes[] calldata pythUpdateData,
        uint256 fromTime,
        uint256 window
    ) internal returns (int64 finalPrice, uint64 finalPublishTime, bool found, uint256 feeConsumed) {
        if (pythUpdateData.length == 0) return (0, 0, false, 0);

        address pythContract = LibPriceMarketStorage.getPythContract();
        IPythExtended pyth = IPythExtended(pythContract);

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = pythFeedId;
        uint64 minPT = uint64(fromTime);
        uint64 maxPT = uint64(fromTime + window);

        bytes[] memory single = new bytes[](1);

        for (uint256 i = 0; i < pythUpdateData.length; i++) {
            single[0] = pythUpdateData[i];
            uint256 singleFee = pyth.getUpdateFee(single);
            try pyth.parsePriceFeedUpdatesUnique{value: singleFee}(single, feedIds, minPT, maxPT) returns (
                PythStructs.PriceFeed[] memory feeds
            ) {
                // At most one submitted VAA per feed per window can satisfy the
                // uniqueness constraint, so we accept the first success and stop.
                feeConsumed += singleFee;
                finalPrice = feeds[0].price.price;
                finalPublishTime = uint64(feeds[0].price.publishTime);
                found = true;
                break;
            } catch {
                // The submitted VAA was either out-of-range for THIS window, or
                // not the first update at or after `minPT` (its `prevPublishTime`
                // falls in the window). The forwarded singleFee is rolled back
                // with the reverted external call and stays in the Diamond's
                // balance for refund.
                continue;
            }
        }
    }
}
