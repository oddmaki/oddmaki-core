// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";

/**
 * @title LibPriceMarketService
 * @notice Business logic for Pyth-powered price markets: opening price capture
 *         and ETH refund handling.
 */
library LibPriceMarketService {
    /// @notice Capture the opening price by parsing the submitted VAA directly.
    ///         Uses parsePriceFeedUpdates (not updatePriceFeeds + getPriceUnsafe) so the
    ///         opening price comes straight from the submitted update, with its publishTime
    ///         enforced within [block.timestamp - OPEN_MAX_STALENESS, block.timestamp + OPEN_FUTURE_SKEW].
    ///         This closes the stale-price exploit where a historical VAA — merely newer than
    ///         Pyth's stored value — could pin an advantageous opening price at market creation.
    function captureOpenPrice(bytes32 pythFeedId, bytes[] calldata pythUpdateData, uint256 msgValue)
        internal
        returns (int64 openPrice, int32 priceExpo, uint256 pythFee, uint256 openPriceTime)
    {
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        pythFee = pyth.getUpdateFee(pythUpdateData);
        if (msgValue < pythFee) revert LibPriceMarketValidator.InsufficientPythFee();

        uint256 maxStaleness = LibPriceMarketStorage.getOpenMaxStaleness();
        uint64 minPub = uint64(block.timestamp > maxStaleness ? block.timestamp - maxStaleness : 0);
        uint64 maxPub = uint64(block.timestamp) + LibPriceMarketStorage.OPEN_FUTURE_SKEW;

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = pythFeedId;

        PythStructs.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdates{value: pythFee}(pythUpdateData, feedIds, minPub, maxPub);

        openPrice = feeds[0].price.price;
        priceExpo = feeds[0].price.expo;
        openPriceTime = feeds[0].price.publishTime;
    }

    /// @notice Read the price exponent for a Pyth feed without updating.
    ///         Uses getPriceUnsafe which returns the last stored data (no fee required).
    ///         The expo field is fixed per feed and always valid regardless of staleness.
    function getFeedExponent(bytes32 pythFeedId) internal view returns (int32) {
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        PythStructs.Price memory price = pyth.getPriceUnsafe(pythFeedId);
        return price.expo;
    }

    /// @notice Refund excess ETH sent beyond the Pyth fee.
    function refundExcess(uint256 fee, uint256 msgValue, address recipient) internal {
        uint256 refund = msgValue - fee;
        if (refund > 0) {
            (bool ok,) = recipient.call{value: refund}("");
            if (!ok) revert LibPriceMarketValidator.ETHRefundFailed();
        }
    }

    /// @notice Parse each submitted VAA individually and return the price whose
    ///         publishTime is the smallest value in `[closeTime, closeTime + window]`.
    ///         Selecting the earliest in-range VAA prevents resolvers from biasing the
    ///         chosen price by reordering `pythUpdateData`.
    ///         Reverts if no submitted VAA falls in range (propagated from Pyth).
    function pickEarliestClosePrice(
        bytes32 pythFeedId,
        bytes[] calldata pythUpdateData,
        uint256 closeTime,
        uint256 window
    ) internal returns (int64 finalPrice) {
        if (pythUpdateData.length == 0) revert LibPriceMarketValidator.NoValidPriceUpdate();

        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = pythFeedId;
        uint64 minPT = uint64(closeTime);
        uint64 maxPT = uint64(closeTime + window);

        uint64 earliestPublishTime = type(uint64).max;
        bytes[] memory single = new bytes[](1);

        for (uint256 i = 0; i < pythUpdateData.length; i++) {
            single[0] = pythUpdateData[i];
            uint256 singleFee = pyth.getUpdateFee(single);
            PythStructs.PriceFeed[] memory feeds =
                pyth.parsePriceFeedUpdates{value: singleFee}(single, feedIds, minPT, maxPT);
            uint64 pt = uint64(feeds[0].price.publishTime);
            if (pt < earliestPublishTime) {
                earliestPublishTime = pt;
                finalPrice = feeds[0].price.price;
            }
        }
    }
}
