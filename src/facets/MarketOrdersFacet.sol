// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketOrderService} from "../services/LibMarketOrderService.sol";
import {LibMarketOrderValidator} from "../validators/LibMarketOrderValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {MarketOrderType, MarketBuyResult} from "../interfaces/Types.sol";

/**
 * @title MarketOrdersFacet
 * @author OddMaki Protocol
 * @notice Market orders: immediate execution against resting sell-side liquidity.
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
}
