// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibOrderAggregate} from "../aggregates/LibOrderAggregate.sol";
import {LibOrderBookService} from "./LibOrderBookService.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "./LibVaultOutcomeTokenService.sol";
import {LibErc1155ReceiverValidator} from "../validators/LibErc1155ReceiverValidator.sol";
import {MarketTradingData, Order, Side} from "../interfaces/Types.sol";

/**
 * @title LibOrderPlacementService
 * @notice Saga: place a limit order (create order, deposit collateral/outcome tokens, enqueue on book).
 */
library LibOrderPlacementService {
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256 qty,
        address indexed owner
    );

    function placeOrder(
        address user,
        uint256 marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256 qty,
        uint256 expiry
    ) internal returns (uint256 orderId) {
        MarketTradingData memory config = LibMarketTradingStorage.getMarketTradingData(marketId);
        require(config.active, "Market not active");

        Order memory order = LibOrderAggregate.createOrder(
            user,
            qty,
            tick,
            side,
            outcomeId,
            marketId,
            expiry,
            config.tickSize
        );
        orderId = order.id;

        if (side == Side.BUY) {
            uint256 collateralAmount = (tick * qty * config.tickSize) / 1e18;
            LibVaultCollateralService.depositCollateral(address(config.collateralToken), user, collateralAmount);
        } else {
            // H-05: reject contract makers that cannot receive refunded outcome tokens.
            LibErc1155ReceiverValidator.requireCanReceiveErc1155(user);
            LibVaultOutcomeTokenService.depositOutcomeTokens(config.positionIds[outcomeId], user, qty);
        }

        LibOrderBookService.enqueueOrder(orderId);

        emit OrderPlaced(orderId, marketId, outcomeId, side, tick, qty, user);
        return orderId;
    }
}
