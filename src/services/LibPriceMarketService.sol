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
    /// @notice Capture the opening price from Pyth using updatePriceFeeds + getPriceUnsafe.
    ///         Uses updatePriceFeeds instead of parsePriceFeedUpdates because the latter
    ///         enforces publishTime within a narrow window of block.timestamp, which breaks
    ///         when wallet signing takes too long. updatePriceFeeds only requires the data
    ///         be newer than what's stored — no relationship to block.timestamp.
    function captureOpenPrice(bytes32 pythFeedId, bytes[] calldata pythUpdateData, uint256 msgValue)
        internal
        returns (int64 openPrice, int32 priceExpo, uint256 pythFee)
    {
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        pythFee = pyth.getUpdateFee(pythUpdateData);
        if (msgValue < pythFee) revert LibPriceMarketValidator.InsufficientPythFee();

        pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
        PythStructs.Price memory openPriceData = pyth.getPriceUnsafe(pythFeedId);

        openPrice = openPriceData.price;
        priceExpo = openPriceData.expo;
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
}
