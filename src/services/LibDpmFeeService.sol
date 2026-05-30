// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {MarketFees, FeeBreakdown} from "../interfaces/Types.sol";
import {LibFeeCalculatorService} from "./LibFeeCalculatorService.sol";
import {LibFeeDistributionService} from "./LibFeeDistributionService.sol";

/**
 * @title LibDpmFeeService
 * @notice DPM fee math, separated from the trading saga (LibDpmService) so it can be reused by the
 *         intent seed, the dynamic `enter`, and future market types (e.g. groups) without each one
 *         re-deriving the split. Two responsibilities:
 *           - {feeBps}: the snapshotted total fee rate for a market (0 if fees are disabled).
 *           - {distribute}: route an exact `feeOut` amount to the fee recipients, folding the
 *             operator slice into the protocol bucket (DPM `enter`/`seed` has no keeper to receive
 *             an operator fee — per design it accrues to the protocol instead).
 */
library LibDpmFeeService {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Total DPM fee rate in bps (protocol + venue + operator), or 0 when fees are disabled
    ///         (no protocol treasury snapshotted at creation — see LibFeeCalculatorService.getMarketFees).
    function feeBps(uint256 marketId) internal view returns (uint256) {
        return LibFeeCalculatorService.getTotalFeeBps(LibFeeCalculatorService.getMarketFees(marketId));
    }

    /// @notice Distribute exactly `feeOut` collateral to the fee recipients, operator -> protocol.
    /// @dev Builds a FeeBreakdown whose components sum to exactly `feeOut` (the remainder sweeps any
    ///      component-rounding dust into the protocol bucket, which LibFeeDistributionService pays to
    ///      the protocol treasury). Keeping the distributed total == the caller's M-reduction is what
    ///      preserves `Σ M_i == custody`. No-op when `feeOut == 0` or fees are disabled.
    function distribute(uint256 marketId, address token, uint256 feeOut) internal {
        if (feeOut == 0) return;
        MarketFees memory fees = LibFeeCalculatorService.getMarketFees(marketId);
        uint256 totalBps = LibFeeCalculatorService.getTotalFeeBps(fees);
        if (totalBps == 0) return;

        FeeBreakdown memory bd;
        bd.protocolFee = (feeOut * (fees.protocolFeeBps + fees.operatorFeeBps)) / totalBps; // operator -> protocol
        bd.creatorFee = (feeOut * fees.creatorFeeBps) / totalBps;
        bd.venueNetFee = (feeOut * (fees.venueFeeBps - fees.creatorFeeBps)) / totalBps;
        bd.operatorFee = 0;
        bd.totalFee = bd.protocolFee + bd.creatorFee + bd.venueNetFee;
        bd.remainder = feeOut - bd.totalFee; // dust -> protocol

        LibFeeDistributionService.distributeFees(token, bd, fees, marketId, 0);
    }
}
