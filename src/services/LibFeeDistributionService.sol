// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketFees, FeeBreakdown} from "../interfaces/Types.sol";
import {LibVaultCollateralService} from "./LibVaultCollateralService.sol";

/**
 * @title LibFeeDistributionService
 * @notice Distributes calculated fees to four recipients: protocol, venue, creator, operator.
 *         Protocol receives rounding remainder. Operator fee goes to msg.sender (preserved via delegatecall).
 */
library LibFeeDistributionService {
    event FeesDistributed(
        uint256 indexed marketId,
        uint256 indexed fillId,
        uint256 protocolFee,
        uint256 venueNetFee,
        uint256 creatorFee,
        uint256 operatorFee,
        uint256 totalFee
    );

    function distributeFees(
        address collateralToken,
        FeeBreakdown memory breakdown,
        MarketFees memory fees,
        uint256 marketId,
        uint256 fillId
    ) internal {
        // If totalFee is zero, nothing to distribute (fees disabled)
        if (breakdown.totalFee == 0 && breakdown.remainder == 0) return;

        // Protocol gets protocolFee + rounding remainder
        uint256 protocolAmount = breakdown.protocolFee + breakdown.remainder;
        if (protocolAmount > 0 && fees.protocolTreasury != address(0)) {
            LibVaultCollateralService.transferCollateral(collateralToken, fees.protocolTreasury, protocolAmount);
        }

        // Venue gets venueNetFee
        if (breakdown.venueNetFee > 0 && fees.venueTreasury != address(0)) {
            LibVaultCollateralService.transferCollateral(collateralToken, fees.venueTreasury, breakdown.venueNetFee);
        }

        // Creator gets creatorFee
        if (breakdown.creatorFee > 0 && fees.marketCreator != address(0)) {
            LibVaultCollateralService.transferCollateral(collateralToken, fees.marketCreator, breakdown.creatorFee);
        }

        // Operator gets operatorFee (msg.sender in Diamond delegatecall context)
        if (breakdown.operatorFee > 0) {
            LibVaultCollateralService.transferCollateral(collateralToken, msg.sender, breakdown.operatorFee);
        }

        emit FeesDistributed(
            marketId,
            fillId,
            protocolAmount,
            breakdown.venueNetFee,
            breakdown.creatorFee,
            breakdown.operatorFee,
            breakdown.totalFee + breakdown.remainder
        );
    }
}
