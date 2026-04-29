// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibNegRiskPositionService} from "./LibNegRiskPositionService.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ApprovalHelper} from "../libraries/ApprovalHelper.sol";

/**
 * @title LibVaultPositionService
 * @notice Split collateral into outcome tokens and merge outcome tokens back to collateral.
 * Routes to CTF (standalone) or NegRisk position service (market group) via LibVaultStorage.needsWrapping.
 */
library LibVaultPositionService {
    bytes32 constant PARENT_COLLECTION_ID = bytes32(0);

    function splitPosition(address collateralToken, bytes32 conditionId, uint256 amount) internal {
        if (LibVaultStorage.needsWrapping(conditionId)) {
            LibNegRiskPositionService.splitPosition(collateralToken, conditionId, amount);
        } else {
            address ctf = LibVaultStorage.getCtf();
            require(ctf != address(0), "Vault: ctf not set");
            ApprovalHelper.approveErc20IfNeeded(collateralToken, ctf, amount);
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;
            IConditionalTokens(ctf).splitPosition(
                IERC20(collateralToken), PARENT_COLLECTION_ID, conditionId, partition, amount
            );
        }
    }

    function mergePositions(address collateralToken, bytes32 conditionId, uint256 amount) internal {
        if (LibVaultStorage.needsWrapping(conditionId)) {
            LibNegRiskPositionService.mergePositions(collateralToken, conditionId, amount);
        } else {
            address ctf = LibVaultStorage.getCtf();
            require(ctf != address(0), "Vault: ctf not set");
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;
            IConditionalTokens(ctf).mergePositions(
                IERC20(collateralToken), PARENT_COLLECTION_ID, conditionId, partition, amount
            );
        }
    }
}
