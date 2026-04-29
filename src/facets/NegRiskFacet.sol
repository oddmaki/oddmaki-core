// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibNegRiskConversionService} from "../services/LibNegRiskConversionService.sol";
import {IERC1155} from "forge-std/interfaces/IERC1155.sol";

/**
 * @title NegRiskFacet
 * @author OddMaki Protocol
 * @notice Neg-risk conversion for market groups: convert NO positions into complementary YES positions
 *         plus collateral. Caller must approve the Diamond on the CTF (setApprovalForAll) first.
 */
contract NegRiskFacet is ReentrancyGuard {
    /**
     * @notice Get position IDs involved in a conversion (for approvals / UX)
     * @param conditionIds All condition IDs in the market group (order must match indexSet bits)
     * @param collateralToken Underlying collateral (e.g. USDC)
     * @param indexSet Bitmap: bit i set = user holds NO for conditionIds[i] (to convert); unset = complementary YES output
     */
    function getConversionPositionIds(bytes32[] calldata conditionIds, address collateralToken, uint256 indexSet)
        external
        view
        returns (uint256[] memory noPositionIds, uint256[] memory yesPositionIds)
    {
        return LibNegRiskConversionService.calculateConversionPositionIds(conditionIds, collateralToken, indexSet);
    }

    /**
     * @notice Convert NO positions to complementary YES positions + (N-1)*amount collateral
     * @param conditionIds All condition IDs in the market group (order must match indexSet)
     * @param collateralToken Underlying collateral
     * @param indexSet Bitmap: bit i set = NO position to convert for conditionIds[i]
     * @param amount Amount per position
     * @dev Pulls NO tokens from msg.sender, runs conversion, sends YES tokens and collateral to msg.sender
     */
    function convertPositions(
        bytes32[] calldata conditionIds,
        address collateralToken,
        uint256 indexSet,
        uint256 amount
    ) external nonReentrant {
        (uint256[] memory noPositionIds, uint256[] memory yesPositionIds) =
            LibNegRiskConversionService.calculateConversionPositionIds(conditionIds, collateralToken, indexSet);

        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        // Pull user's NO tokens into Diamond
        uint256 noCount = noPositionIds.length;
        if (noCount > 0) {
            uint256[] memory noAmounts = new uint256[](noCount);
            for (uint256 i = 0; i < noCount; i++) noAmounts[i] = amount;
            IERC1155(ctf).safeBatchTransferFrom(msg.sender, address(this), noPositionIds, noAmounts, "");
        }

        // Build complementary condition IDs (markets where we output YES)
        uint256 yesCount = yesPositionIds.length;
        bytes32[] memory complementaryConditionIds = new bytes32[](yesCount);
        uint256 yesIndex = 0;
        for (uint256 i = 0; i < conditionIds.length; i++) {
            if ((indexSet & (uint256(1) << i)) == 0) {
                complementaryConditionIds[yesIndex] = conditionIds[i];
                yesIndex++;
            }
        }

        LibNegRiskConversionService.convertPositions(
            noPositionIds, complementaryConditionIds, collateralToken, amount, msg.sender
        );

        // Send YES tokens to user
        if (yesCount > 0) {
            uint256[] memory yesAmounts = new uint256[](yesCount);
            for (uint256 i = 0; i < yesCount; i++) yesAmounts[i] = amount;
            IERC1155(ctf).safeBatchTransferFrom(address(this), msg.sender, yesPositionIds, yesAmounts, "");
        }
    }
}
