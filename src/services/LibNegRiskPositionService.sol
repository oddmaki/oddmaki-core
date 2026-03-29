// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibNegRiskStorage} from "../storage/LibNegRiskStorage.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WrappedCollateralToken} from "../tokens/WrappedCollateralToken.sol";
import {ApprovalHelper} from "../libraries/ApprovalHelper.sol";

/**
 * @title LibNegRiskPositionService
 * @notice NegRisk split/merge only. Collateral and outcome tokens are in the Diamond (caller context).
 *        Vault position (split/merge) uses this when needsWrapping; no registration or conversion here.
 */
library LibNegRiskPositionService {
    bytes32 constant PARENT_COLLECTION_ID = bytes32(0);

    function splitPosition(address collateralToken, bytes32 conditionId, uint256 amount) internal {
        address wrapped = LibNegRiskStorage.getWrappedCollateral(collateralToken);
        require(wrapped != address(0), "NegRisk: wrapped not registered");

        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        ApprovalHelper.approveErc20IfNeeded(collateralToken, wrapped, amount);
        WrappedCollateralToken(wrapped).wrap(address(this), amount);

        ApprovalHelper.approveErc20IfNeeded(wrapped, ctf, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        IConditionalTokens(ctf).splitPosition(
            IERC20(wrapped), PARENT_COLLECTION_ID, conditionId, partition, amount
        );
    }

    function mergePositions(address collateralToken, bytes32 conditionId, uint256 amount) internal {
        address wrapped = LibNegRiskStorage.getWrappedCollateral(collateralToken);
        require(wrapped != address(0), "NegRisk: wrapped not registered");

        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        IConditionalTokens(ctf).mergePositions(
            IERC20(wrapped), PARENT_COLLECTION_ID, conditionId, partition, amount
        );
        WrappedCollateralToken(wrapped).unwrap(address(this), amount);
    }
}
