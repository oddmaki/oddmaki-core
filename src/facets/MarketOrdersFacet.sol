// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
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
 * @notice Multi-path market orders: walks both books per step, takes the
 *         cheapest crossable path (normal vs mint for BUY; normal vs merge
 *         for SELL), bounded by a slippage cap anchored to the on-chain mark
 *         price at facet entry. No caller-supplied price — slippage tolerance
 *         is the only knob.
 */
contract MarketOrdersFacet is ReentrancyGuard {
    event MarketOrderBuy(
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

    event MarketOrderSell(
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
     * @notice Place a market BUY. Slippage is the only price knob — the
     *         protocol resolves the reference price on-chain via the mark
     *         price waterfall and walks both books taking the cheapest path
     *         per step (normal fill against same-outcome ask, or mint fill
     *         against opposite-outcome bid).
     * @param marketId    Market to buy in.
     * @param outcomeId   Outcome to acquire (0=YES, 1=NO).
     * @param budget      Collateral the taker is willing to spend.
     * @param slippageBps Maximum slippage above the resolved mark tick (bps).
     *                    Capped at {LibMarketTakeService.MAX_SLIPPAGE_BPS}.
     * @param orderType   FOK (revert on partial) or FAK (refund unspent).
     */
    function placeMarketBuy(
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

        emit MarketOrderBuy(
            msg.sender, marketId, outcomeId,
            take.consumedBudget, take.filledQty, avgPrice, take.remainingBudget,
            take.anchorTick, take.maxEffTick, take.fillCount
        );

        result = MarketBuyResult({
            tokensReceived: take.filledQty,
            avgPrice: avgPrice,
            collateralSpent: take.consumedBudget,
            unusedCollateral: take.remainingBudget
        });
    }

    /**
     * @notice Place a market SELL. Multi-path (normal + merge), slippage-anchored.
     * @param marketId    Market to sell in.
     * @param outcomeId   Outcome to sell (0=YES, 1=NO).
     * @param tokenAmount Outcome tokens the taker is offering.
     * @param slippageBps Maximum slippage below the resolved mark tick (bps).
     * @param orderType   FOK (revert on partial) or FAK (refund unsold).
     */
    function placeMarketSell(
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

        emit MarketOrderSell(
            msg.sender, marketId, outcomeId,
            take.soldQty, take.netProceeds, avgPrice, take.remainingQty,
            take.anchorTick, take.minEffTick, take.fillCount
        );

        result = MarketSellResult({
            tokensSold: take.soldQty,
            avgPrice: avgPrice,
            collateralReceived: take.netProceeds,
            unsoldTokens: take.remainingQty
        });
    }
}
