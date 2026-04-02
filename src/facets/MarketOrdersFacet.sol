// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketOrderService} from "../services/LibMarketOrderService.sol";
import {LibMarketSellService} from "../services/LibMarketSellService.sol";
import {LibMarketOrderValidator} from "../validators/LibMarketOrderValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {MarketOrderType, MarketBuyResult, MarketSellResult} from "../interfaces/Types.sol";

/**
 * @title MarketOrdersFacet
 * @author OddMaki Protocol
 * @notice Market orders: immediate execution against resting liquidity (buy and sell side).
 */
contract MarketOrdersFacet is ReentrancyGuard {
    /**
     * @notice Place a market buy order: deposit collateral and consume sell-side liquidity.
     * @param marketId        Market to buy in.
     * @param outcomeId       Outcome to acquire (0=YES, 1=NO).
     * @param collateralAmount Total collateral willing to spend.
     * @param maxPriceTick    Maximum price tick willing to pay.
     * @param orderType       FOK (all-or-nothing) or FAK (partial fills allowed).
     * @return result         Execution summary.
     */
    function placeMarketOrder(
        uint256 marketId,
        uint256 outcomeId,
        uint256 collateralAmount,
        uint256 maxPriceTick,
        MarketOrderType orderType
    ) external nonReentrant returns (MarketBuyResult memory result) {
        LibMarketOrderValidator.requireActiveMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);
        return LibMarketOrderService.placeMarketOrder(marketId, outcomeId, collateralAmount, maxPriceTick, orderType);
    }

    /**
     * @notice Place a market sell order: deposit outcome tokens and consume buy-side liquidity.
     * @dev Caller must have approved the Diamond for ERC-1155 outcome tokens (setApprovalForAll).
     * @param marketId     Market to sell in.
     * @param outcomeId    Outcome to sell (0=YES, 1=NO).
     * @param tokenAmount  Total outcome tokens willing to sell.
     * @param minPriceTick Minimum price tick willing to accept.
     * @param orderType    FOK (all-or-nothing) or FAK (partial fills allowed).
     * @return result      Execution summary.
     */
    function placeMarketSell(
        uint256 marketId,
        uint256 outcomeId,
        uint256 tokenAmount,
        uint256 minPriceTick,
        MarketOrderType orderType
    ) external nonReentrant returns (MarketSellResult memory result) {
        LibMarketOrderValidator.requireActiveMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);
        return LibMarketSellService.placeMarketSell(marketId, outcomeId, tokenAmount, minPriceTick, orderType);
    }
}
