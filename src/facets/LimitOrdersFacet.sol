// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibOrderPlacementService} from "../services/LibOrderPlacementService.sol";
import {LibOrderCancellationService} from "../services/LibOrderCancellationService.sol";
import {LibOrderExpiryService} from "../services/LibOrderExpiryService.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {LibOrderStorage} from "../storage/LibOrderStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {Order, Side, MarketStatus} from "../interfaces/Types.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title LimitOrdersFacet
 * @author OddMaki Protocol
 * @notice Limit order lifecycle: place, cancel, query, and expire orders.
 */
contract LimitOrdersFacet is ReentrancyGuard {
    error MarketNotActive();
    error MarketNotResolved();
    error BatchTooLarge();

    /**
     * @notice Place a limit order on a market's order book.
     * @param marketId  the market to place the order on (must be active and unpaused).
     * @param outcomeId the outcome to trade (0 = YES, 1 = NO).
     * @param side      BUY or SELL.
     * @param tick      price level in ticks (1 to 1e18/tickSize).
     * @param qty       number of outcome tokens to buy or sell.
     * @param expiry    unix timestamp after which the order can be expired (0 = no expiration).
     * @return orderId  the allocated order identifier.
     * @dev BUY orders lock collateral; SELL orders lock outcome tokens. The caller must have
     *      approved the Diamond to spend the required collateral or outcome tokens.
     */
    function placeOrder(
        uint256 marketId,
        uint256 outcomeId,
        Side side,
        uint256 tick,
        uint256 qty,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);
        return LibOrderPlacementService.placeOrder(
            msg.sender,
            marketId,
            outcomeId,
            side,
            tick,
            qty,
            expiry
        );
    }

    /// @notice Cancel a resting limit order and refund locked assets to the caller.
    /// @param orderId the order to cancel.
    /// @dev Only the order owner can cancel.
    function cancelOrder(uint256 orderId) external nonReentrant {
        LibOrderCancellationService.cancelOrder(msg.sender, orderId);
    }

    /// @notice Get full order data by ID.
    /// @param orderId the order to query.
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return LibOrderStorage.getOrder(orderId);
    }

    /// @notice Expire a batch of orders whose expiry timestamp has passed. Full refund to each order owner.
    /// @param marketId  the market the orders belong to (must be active).
    /// @param orderIds  array of order IDs to attempt expiry on.
    /// @return expiredCount number of orders actually expired.
    /// @return rewardEarned reward earned by the caller (currently 0, reserved for future use).
    function expireOrders(uint256 marketId, uint256[] calldata orderIds)
        external
        nonReentrant
        returns (uint256 expiredCount, uint256 rewardEarned)
    {
        if (!LibMarketTradingStorage.marketIsActive(marketId)) revert MarketNotActive();
        expiredCount = LibOrderExpiryService.expireOrders(marketId, orderIds);
        rewardEarned = 0;
    }

    /// @notice Cancel resting orders on a resolved market. Permissionless — anyone can call.
    ///         Refunds locked collateral (BUY) or outcome tokens (SELL) to each order's owner.
    ///         Already-deleted orders are silently skipped.
    /// @param marketId  Market that must be in Resolved status.
    /// @param orderIds  Batch of order IDs to cancel (max 100).
    /// @return cancelledCount Number of orders actually cancelled.
    function cancelOrdersOnResolvedMarket(uint256 marketId, uint256[] calldata orderIds)
        external
        nonReentrant
        returns (uint256 cancelledCount)
    {
        if (LibMarketRegistryStorage.getMarketRegistryData(marketId).status != MarketStatus.Resolved) {
            revert MarketNotResolved();
        }
        uint256 len = orderIds.length;
        if (len > 100) revert BatchTooLarge();

        for (uint256 i = 0; i < len; i++) {
            if (LibOrderCancellationService.cancelOrderOnResolvedMarket(orderIds[i], marketId)) {
                cancelledCount++;
            }
        }
    }
}
