// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketFees, FeeBreakdown, VenueData, MarketRegistryData} from "../interfaces/Types.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";

/**
 * @title LibFeeCalculatorService
 * @notice Fee config reader (composed view) + pure fee math.
 *
 * Venue-Controlled Fee Model:
 * - Protocol: 20 bps (fixed) -> protocol treasury
 * - Venue: 1-200 bps (configurable) -> split between venue net and creator
 * - Operator: 10 bps (fixed) -> msg.sender who called matchOrders
 *
 * Rounding: floor each component, remainder goes to protocol during distribution.
 */
library LibFeeCalculatorService {
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant PROTOCOL_FEE_BPS = 20;
    uint256 constant OPERATOR_FEE_BPS = 10;

    // =========================================================================
    // FEE CONFIG READER (composed view across multiple storage namespaces)
    // =========================================================================

    /**
     * @notice Compose MarketFees from live venue config, market registry, and protocol storage.
     *         Returns all-zero struct if protocolTreasury == address(0) (fees disabled).
     */
    function getMarketFees(uint256 marketId) internal view returns (MarketFees memory fees) {
        address treasury = LibProtocolStorage.getProtocolTreasury();

        // If no treasury set, return all-zero struct (fees disabled, backward compatible)
        if (treasury == address(0)) {
            return fees;
        }

        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        VenueData storage venue = LibVenueStorage.getVenueData(registry.venueId);

        fees.protocolFeeBps = PROTOCOL_FEE_BPS;
        fees.venueFeeBps = registry.venueFeeBps;
        fees.creatorFeeBps = registry.creatorFeeBps;
        fees.operatorFeeBps = OPERATOR_FEE_BPS;
        fees.protocolTreasury = treasury;
        fees.venueTreasury = venue.feeRecipient;
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
}
