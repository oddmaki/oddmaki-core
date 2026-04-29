// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibVaultAggregate} from "../aggregates/LibVaultAggregate.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibNegRiskRegistrationService} from "./LibNegRiskRegistrationService.sol";
import {CTFHelpers} from "../libraries/CTFHelpers.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title LibVaultRegistrationService
 * @notice Register condition: set needsWrapping (aggregate) and compute [YES, NO] position IDs (CTF or NegRisk).
 */
library LibVaultRegistrationService {
    bytes32 constant PARENT_COLLECTION_ID = bytes32(0);

    function registerCondition(bytes32 conditionId, address collateralToken, bool needsWrapping)
        internal
        returns (uint256[2] memory positionIds)
    {
        LibVaultAggregate.setNeedsWrapping(conditionId, needsWrapping);

        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        address collateralForPositions = collateralToken;
        if (needsWrapping) {
            collateralForPositions = LibNegRiskRegistrationService.registerWrappedCollateral(collateralToken);
        }
        for (uint256 i = 0; i < 2; i++) {
            bytes32 collectionId =
                IConditionalTokens(ctf).getCollectionId(PARENT_COLLECTION_ID, conditionId, i + 1);
            positionIds[i] = CTFHelpers.getPositionId(IERC20(collateralForPositions), collectionId);
        }
        return positionIds;
    }
}
