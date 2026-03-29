// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {VenueData} from "../interfaces/Types.sol";

/**
 * @title LibMarketCreationFeeService
 * @notice Collects upfront market creation fee, split 50/50 between protocol treasury and venue fee recipient.
 *         No-op when protocolTreasury is not set (backward compatible).
 */
library LibMarketCreationFeeService {
    event MarketCreationFeeCollected(
        uint256 indexed venueId,
        address indexed payer,
        uint256 protocolShare,
        uint256 venueShare
    );

    function collectCreationFee(
        uint256 venueId,
        address payer,
        address collateralToken
    ) internal {
        address treasury = LibProtocolStorage.getProtocolTreasury();

        // If no treasury set, fees are disabled (backward compatible)
        if (treasury == address(0)) return;

        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        uint256 totalFee = venue.marketCreationFee;
        if (totalFee == 0) return;

        // 50/50 split (protocol gets the odd wei if totalFee is odd)
        uint256 venueShare = totalFee / 2;
        uint256 protocolShare = totalFee - venueShare;

        // Transfer from payer to protocol treasury
        TransferHelper._transferFromErc20(collateralToken, payer, treasury, protocolShare);

        // Transfer from payer to venue fee recipient
        address venueRecipient = venue.feeRecipient;
        if (venueRecipient != address(0)) {
            TransferHelper._transferFromErc20(collateralToken, payer, venueRecipient, venueShare);
        }

        emit MarketCreationFeeCollected(venueId, payer, protocolShare, venueShare);
    }
}
