// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketOrderService} from "../services/LibMarketOrderService.sol";
import {LibMarketSellService} from "../services/LibMarketSellService.sol";
import {LibMarketTakeService} from "../services/LibMarketTakeService.sol";
import {LibMarketOrderValidator} from "../validators/LibMarketOrderValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibVaultCollateralService} from "../services/LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "../services/LibVaultOutcomeTokenService.sol";
import {LibErc1155ReceiverValidator} from "../validators/LibErc1155ReceiverValidator.sol";
import {MarketOrderType, MarketBuyResult, MarketSellResult, MarketTradingData} from "../interfaces/Types.sol";

/**
 * @title MarketOrdersFacet
 * @author OddMaki Protocol
 * @notice Market orders: immediate execution against resting liquidity (buy and sell side).
 */
contract MarketOrdersFacet is ReentrancyGuard {
    /// @notice Emitted on completion of a V2 market BUY (multi-path).
    event MarketOrderBuyV2(
        address indexed buyer,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 collateralSpent,
        uint256 tokensReceived,
        uint256 avgPrice,
        uint256 unusedCollateral,
        uint256 markTick,
        uint256 maxEffTick,
        uint256 fillCount
    );

    /// @notice Emitted on completion of a V2 market SELL (multi-path).
    event MarketOrderSellV2(
        address indexed seller,
        uint256 indexed marketId,
        uint256 outcomeId,
        uint256 tokensSold,
        uint256 collateralReceived,
        uint256 avgPrice,
        uint256 unsoldTokens,
        uint256 markTick,
        uint256 minEffTick,
        uint256 fillCount
    );

    /**
     * @notice [LEGACY] Place a market buy order against same-outcome SELL liquidity only.
     *         Reverts with NoLiquidityAvailable when no same-outcome asks exist, even when
     *         opposite-outcome bids could mint-fill the order — use {placeMarketBuyV2}
     *         (multi-path, slippage-anchored) for that case.
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
     * @notice [LEGACY] Place a market sell order against same-outcome BUY liquidity only.
     *         See {placeMarketSellV2} for the multi-path (normal + merge) variant.
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

    // -------------------------------------------------------------------------
    // V2: multi-path market orders (normal + mint/merge), slippage-anchored
    // -------------------------------------------------------------------------

    /**
     * @notice Place a multi-path market BUY. Anchors slippage to the on-chain
     *         mark price (no caller-supplied price), then walks both books
     *         picking the cheapest crossable path (normal fill against the
     *         same outcome's ask, or mint fill against the opposite outcome's
     *         bid) at each step.
     * @param marketId    Market to buy in.
     * @param outcomeId   Outcome to acquire (0=YES, 1=NO).
     * @param budget      Collateral the taker is willing to spend.
     * @param slippageBps Maximum slippage above the resolved mark tick (bps).
     *                    Capped at {LibMarketTakeService.MAX_SLIPPAGE_BPS}.
     * @param orderType   FOK (revert on partial) or FAK (refund unspent).
     */
    function placeMarketBuyV2(
        uint256 marketId,
        uint256 outcomeId,
        uint256 budget,
        uint256 slippageBps,
        MarketOrderType orderType
    ) external nonReentrant returns (MarketBuyResult memory result) {
        LibMarketOrderValidator.requireActiveMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);
        LibMarketOrderValidator.validateOutcomeId(outcomeId);
        if (budget == 0) revert LibMarketOrderValidator.ZeroCollateralAmount();

        MarketTradingData storage md = LibMarketTradingStorage.getMarketTradingData(marketId);

        // Pull taker's collateral upfront — used by both normal and mint paths.
        LibVaultCollateralService.depositCollateral(address(md.collateralToken), msg.sender, budget);

        LibMarketTakeService.TakeBuyResult memory take = LibMarketTakeService.takeMarketBuy(
            marketId, outcomeId, msg.sender, budget, slippageBps, md
        );

        if (take.filledQty == 0) revert LibMarketOrderValidator.NoLiquidityAvailable();

        if (take.remainingBudget > 0) {
            if (orderType == MarketOrderType.FOK && take.remainingBudget > md.tickSize) {
                revert LibMarketOrderValidator.InsufficientLiquidityForFOK();
            }
            LibVaultCollateralService.withdrawCollateral(
                address(md.collateralToken), msg.sender, take.remainingBudget
            );
        }

        uint256 avgPrice = take.filledQty > 0 ? (take.consumedBudget * 1e18) / take.filledQty : 0;

        emit MarketOrderBuyV2(
            msg.sender, marketId, outcomeId,
            take.consumedBudget, take.filledQty, avgPrice, take.remainingBudget,
            take.markTick, take.maxEffTick, take.fillCount
        );

        result = MarketBuyResult({
            tokensReceived: take.filledQty,
            avgPrice: avgPrice,
            collateralSpent: take.consumedBudget,
            unusedCollateral: take.remainingBudget
        });
    }

    /**
     * @notice Place a multi-path market SELL. Anchors slippage to the on-chain
     *         mark price, walks both books picking the path with the highest
     *         net taker tick (normal fill against same-outcome bid, or merge
     *         fill against opposite-outcome ask) at each step.
     * @param marketId    Market to sell in.
     * @param outcomeId   Outcome to sell (0=YES, 1=NO).
     * @param tokenAmount Outcome tokens the taker is offering.
     * @param slippageBps Maximum slippage below the resolved mark tick (bps).
     * @param orderType   FOK (revert on partial) or FAK (refund unsold).
     */
    function placeMarketSellV2(
        uint256 marketId,
        uint256 outcomeId,
        uint256 tokenAmount,
        uint256 slippageBps,
        MarketOrderType orderType
    ) external nonReentrant returns (MarketSellResult memory result) {
        LibMarketOrderValidator.requireActiveMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibAccessControlValidator.validateTradingAccess(msg.sender, marketId);
        LibMarketOrderValidator.validateOutcomeId(outcomeId);
        if (tokenAmount == 0) revert LibMarketOrderValidator.ZeroTokenAmount();
        // H-05: reject contract sellers that cannot receive FAK refund tokens.
        LibErc1155ReceiverValidator.requireCanReceiveErc1155(msg.sender);

        MarketTradingData storage md = LibMarketTradingStorage.getMarketTradingData(marketId);

        LibVaultOutcomeTokenService.depositOutcomeTokens(md.positionIds[outcomeId], msg.sender, tokenAmount);

        LibMarketTakeService.TakeSellResult memory take = LibMarketTakeService.takeMarketSell(
            marketId, outcomeId, msg.sender, tokenAmount, slippageBps, md
        );

        if (take.soldQty == 0) revert LibMarketOrderValidator.NoLiquidityAvailable();

        if (take.remainingQty > 0) {
            if (orderType == MarketOrderType.FOK) {
                revert LibMarketOrderValidator.InsufficientLiquidityForFOK();
            }
            LibVaultOutcomeTokenService.withdrawOutcomeTokens(
                md.positionIds[outcomeId], msg.sender, take.remainingQty
            );
        }

        uint256 avgPrice = take.soldQty > 0 ? (take.grossProceeds * 1e18) / take.soldQty : 0;

        emit MarketOrderSellV2(
            msg.sender, marketId, outcomeId,
            take.soldQty, take.netProceeds, avgPrice, take.remainingQty,
            take.markTick, take.minEffTick, take.fillCount
        );

        result = MarketSellResult({
            tokensSold: take.soldQty,
            avgPrice: avgPrice,
            collateralReceived: take.netProceeds,
            unsoldTokens: take.remainingQty
        });
    }
}
