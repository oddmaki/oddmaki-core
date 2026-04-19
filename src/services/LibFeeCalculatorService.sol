// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketFees, FeeBreakdown, MarketRegistryData} from "../interfaces/Types.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";

/**
 * @title LibFeeCalculatorService
 * @notice Fee config reader (composed view) + pure fee math.
 *
 * Fee Model:
 * - Protocol: 0-200 bps (configurable, snapshotted per market) -> protocol treasury
 * - Venue: 1-200 bps (configurable, snapshotted per market) -> split between venue net and creator
 * - Operator: 10 bps (fixed) -> msg.sender who called matchOrders
 * - Maker pays 0%. Taker bears all fees.
 *
 * Rounding: floor each component, remainder goes to protocol during distribution.
 */
library LibFeeCalculatorService {
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant OPERATOR_FEE_BPS = 10;

    // =========================================================================
    // FEE CONFIG READER (composed view across multiple storage namespaces)
    // =========================================================================

    /**
     * @notice Compose MarketFees from the market registry's fee snapshot. Rates AND recipients
     *         are read from the per-market snapshot taken at creation — mutations to venue.feeRecipient
     *         or protocolTreasury after the market is live never redirect fees that resting makers
     *         priced in at placement (H-01 fix).
     *         Returns all-zero struct if protocolFeeRecipient == address(0) (fees disabled at creation).
     */
    function getMarketFees(uint256 marketId) internal view returns (MarketFees memory fees) {
        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);

        // If no protocol treasury was snapshotted, the market was created with fees disabled.
        if (registry.protocolFeeRecipient == address(0)) {
            return fees;
        }

        fees.protocolFeeBps = registry.protocolFeeBps;
        fees.venueFeeBps = registry.venueFeeBps;
        fees.creatorFeeBps = registry.creatorFeeBps;
        fees.operatorFeeBps = OPERATOR_FEE_BPS;
        fees.protocolTreasury = registry.protocolFeeRecipient;
        fees.venueTreasury = registry.venueFeeRecipient;
        fees.marketCreator = registry.creator;
    }

    // =========================================================================
    // FEE MATH (pure)
    // =========================================================================

    /**
     * @notice Calculate fee breakdown for a fill.
     *         Each component is floored; remainder tracked separately.
     */
    function calculateFees(uint256 tradeVolume, MarketFees memory fees)
        internal
        pure
        returns (FeeBreakdown memory breakdown)
    {
        breakdown.protocolFee = (tradeVolume * fees.protocolFeeBps) / BPS_DENOMINATOR;
        breakdown.creatorFee = (tradeVolume * fees.creatorFeeBps) / BPS_DENOMINATOR;
        breakdown.venueNetFee = (tradeVolume * (fees.venueFeeBps - fees.creatorFeeBps)) / BPS_DENOMINATOR;
        breakdown.operatorFee = (tradeVolume * fees.operatorFeeBps) / BPS_DENOMINATOR;

        breakdown.totalFee =
            breakdown.protocolFee + breakdown.venueNetFee + breakdown.creatorFee + breakdown.operatorFee;

        // Remainder from rounding dust -> goes to protocol during distribution
        uint256 expectedTotal = (tradeVolume * getTotalFeeBps(fees)) / BPS_DENOMINATOR;
        if (expectedTotal > breakdown.totalFee) {
            breakdown.remainder = expectedTotal - breakdown.totalFee;
        }
    }

    /**
     * @notice Total fee in basis points: protocol + venue + operator.
     *         Note: creatorFeeBps is a sub-split of venueFeeBps, not additive.
     */
    function getTotalFeeBps(MarketFees memory fees) internal pure returns (uint256) {
        return fees.protocolFeeBps + fees.venueFeeBps + fees.operatorFeeBps;
    }

    // =========================================================================
    // FEASIBILITY CHECKS (for Mint/Merge matching)
    // =========================================================================

    /**
     * @notice Check if Mint-to-Fill is feasible accounting for fees.
     *         (yesBid + noBid) >= fullPrice * (1 + totalFeeBps / 10000)
     */
    function checkMintFeasibility(
        uint256 yesBidTick,
        uint256 noBidTick,
        uint256 tickSize,
        MarketFees memory fees
    ) internal pure returns (bool) {
        uint256 fullPriceTicks = 1e18 / tickSize;
        uint256 totalFeeBps = getTotalFeeBps(fees);
        uint256 minRequiredTicks = (fullPriceTicks * (BPS_DENOMINATOR + totalFeeBps) + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        return (yesBidTick + noBidTick) >= minRequiredTicks;
    }

    /**
     * @notice Check if Merge-to-Fill is feasible accounting for fees.
     *         (yesAsk + noAsk) <= fullPrice * (1 - totalFeeBps / 10000)
     */
    function checkMergeFeasibility(
        uint256 yesAskTick,
        uint256 noAskTick,
        uint256 tickSize,
        MarketFees memory fees
    ) internal pure returns (bool) {
        uint256 fullPriceTicks = 1e18 / tickSize;
        uint256 totalFeeBps = getTotalFeeBps(fees);
        uint256 maxAllowedTicks = (fullPriceTicks * (BPS_DENOMINATOR - totalFeeBps)) / BPS_DENOMINATOR;
        return (yesAskTick + noAskTick) <= maxAllowedTicks;
    }

    // =========================================================================
    // SNAPSHOT HELPERS
    // =========================================================================

    /**
     * @notice Total fee BPS from market snapshot (protocol + venue + operator).
     */
    function getSnapshotedTotalFeeBps(uint256 marketId) internal view returns (uint256) {
        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        return registry.protocolFeeBps + registry.venueFeeBps + OPERATOR_FEE_BPS;
    }
}
