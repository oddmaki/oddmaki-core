// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {MarketTradingData} from "../interfaces/Types.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LibTickSizeValidator} from "../validators/LibTickSizeValidator.sol";

/**
 * @title LibMarketTradingAggregate
 * @notice Writes for market trading: create trading row, update volume/lastTradeTick/active.
 */
library LibMarketTradingAggregate {
    error InvalidMarketId();
    error InvalidCollateral();
    error TradingAlreadyExists();

    function createTrading(
        uint256 marketId,
        uint256 tickSize,
        IERC20 collateralToken,
        uint256[2] memory positionIds,
        bool active
    ) internal returns (MarketTradingData memory data) {
        if (marketId == 0) revert InvalidMarketId();
        LibTickSizeValidator.requireValidTickSize(tickSize);
        if (address(collateralToken) == address(0)) revert InvalidCollateral();

        LibMarketTradingStorage.Storage storage s = LibMarketTradingStorage.getStorage();
        if (s.byMarketId[marketId].marketId != 0) revert TradingAlreadyExists();

        data = MarketTradingData({
            marketId: marketId,
            tickSize: tickSize,
            collateralToken: collateralToken,
            positionIds: positionIds,
            totalVolume: [uint256(0), uint256(0)],
            lastTradeTick: [uint256(0), uint256(0)],
            active: active
        });
        s.byMarketId[marketId] = data;
        return data;
    }

    function recordTotalVolume(uint256 marketId, uint256 outcomeId, uint256 amount) internal {
        LibMarketTradingStorage.getMarketTradingData(marketId).totalVolume[outcomeId] += amount;
    }

    function recordLastTradeTick(uint256 marketId, uint256 outcomeId, uint256 priceTick) internal {
        LibMarketTradingStorage.getMarketTradingData(marketId).lastTradeTick[outcomeId] = priceTick;
    }

    function setActive(uint256 marketId, bool active) internal {
        LibMarketTradingStorage.getMarketTradingData(marketId).active = active;
    }

    function setPaused(uint256 marketId, bool paused) internal {
        LibMarketTradingStorage.getStorage().marketPaused[marketId] = paused;
    }
}
