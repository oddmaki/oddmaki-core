// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LibNegRiskStorage} from "../storage/LibNegRiskStorage.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {IConditionalTokens} from "../interfaces/IConditionalTokens.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC1155} from "forge-std/interfaces/IERC1155.sol";
import {WrappedCollateralToken} from "../tokens/WrappedCollateralToken.sol";
import {CTFHelpers} from "../libraries/CTFHelpers.sol";
import {ApprovalHelper} from "../libraries/ApprovalHelper.sol";
import {ArrayHelpers} from "../libraries/ArrayHelpers.sol";

/**
 * @title LibNegRiskConversionService
 * @notice NegRisk conversion: NO positions → complementary YES positions + collateral.
 *        NO tokens (already in Diamond) are burned; wrapped is minted and split for complementary markets;
 *        (N-1)*amount collateral released to user; YES tokens remain in Diamond (caller transfers to user).
 */
library LibNegRiskConversionService {
    bytes32 constant PARENT_COLLECTION_ID = bytes32(0);
    address constant NO_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("NO_TOKEN_BURN_ADDRESS"))));

    error UnregisteredConditionId(bytes32 conditionId);
    error InvalidIndexSet();

    function calculateConversionPositionIds(bytes32[] calldata conditionIds, address collateralToken, uint256 indexSet)
        internal
        view
        returns (uint256[] memory noPositionIds, uint256[] memory yesPositionIds)
    {
        address wrapped = LibNegRiskStorage.getWrappedCollateral(collateralToken);
        require(wrapped != address(0), "NegRisk: wrapped not registered");
        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        uint256 totalMarkets = conditionIds.length;
        // Reject indexSets with bits beyond the supplied conditions (C-02: bit-alignment check).
        if (totalMarkets < 256 && indexSet >> totalMarkets != 0) revert InvalidIndexSet();

        uint256 noPositionCount = 0;
        for (uint256 i = 0; i < totalMarkets; i++) {
            // C-02: every conditionId must be a Diamond-registered neg-risk condition. Blocks
            // attacker-prepared CTF conditions that would otherwise mint unbacked WCT / drain release().
            if (!LibVaultStorage.needsWrapping(conditionIds[i])) revert UnregisteredConditionId(conditionIds[i]);
            if ((indexSet & (uint256(1) << i)) != 0) noPositionCount++;
        }
        uint256 yesPositionCount = totalMarkets - noPositionCount;

        noPositionIds = new uint256[](noPositionCount);
        yesPositionIds = new uint256[](yesPositionCount);

        uint256 noIndex = 0;
        uint256 yesIndex = 0;
        for (uint256 i = 0; i < totalMarkets; i++) {
            if ((indexSet & (uint256(1) << i)) != 0) {
                bytes32 noCollectionId = IConditionalTokens(ctf).getCollectionId(PARENT_COLLECTION_ID, conditionIds[i], 2);
                noPositionIds[noIndex] = CTFHelpers.getPositionId(IERC20(wrapped), noCollectionId);
                noIndex++;
            } else {
                bytes32 yesCollectionId = IConditionalTokens(ctf).getCollectionId(PARENT_COLLECTION_ID, conditionIds[i], 1);
                yesPositionIds[yesIndex] = CTFHelpers.getPositionId(IERC20(wrapped), yesCollectionId);
                yesIndex++;
            }
        }
        return (noPositionIds, yesPositionIds);
    }

    /**
     * @notice Execute the NegRisk conversion: user's NO positions → complementary YES positions + collateral.
     * @param noPositionIds NO position IDs (already in Diamond from user transfer)
     * @param conditionIds Complementary condition IDs (for splitting to create YES)
     * @param collateralToken Underlying collateral
     * @param amount Amount per position
     * @param user Recipient of (noCount-1)*amount collateral; YES tokens stay in Diamond (caller sends to user)
     *
     * @dev Solvency invariant of WrappedCollateralToken (WCT) is preserved by the following accounting:
     *
     *   Let N = noPositionIds.length, M = conditionIds.length (complementary markets).
     *
     *   Step 1 (mint + split): M*amount WCT is minted without collateral and transferred to CTF via
     *   splitPosition. This creates M*amount YES[comp] + M*amount NO[comp] outcome tokens. The minted
     *   WCT is now held by CTF as collateral for those outcome pairs.
     *
     *   Step 2 (burn NOs): All N user NO tokens and all M new NO[comp] tokens are sent to NO_TOKEN_BURN_ADDRESS.
     *   Since that address can never call redeemPositions(), the WCT backing those burned positions is
     *   permanently locked in CTF: N*amount (from user's original splits) + M*amount (from new splits).
     *
     *   Step 3 (release): (N-1)*amount USDC is released from WCT to the user. The (N-1) formula ensures
     *   that exactly 1*amount WCT remains locked in CTF per user NO position to cover the USDC paid out.
     *
     *   Net effect: WCT.usdc_balance decreases by (N-1)*amount. The maximum redeemable USDC by all
     *   legitimate YES[comp] and NO[survivor] holders after resolution decreases by exactly (N-1)*amount
     *   in all resolution scenarios. The invariant WCT.usdc_balance >= redeemable_claims is preserved.
     *
     *   Assumes: oracle reports exactly one YES per NegRisk group; this function is called atomically
     *   (nonReentrant at the facet level); Diamond is the sole ADAPTER on WCT.
     */
    function convertPositions(
        uint256[] memory noPositionIds,
        bytes32[] memory conditionIds,
        address collateralToken,
        uint256 amount,
        address user
    ) internal {
        address wrapped = LibNegRiskStorage.getWrappedCollateral(collateralToken);
        require(wrapped != address(0), "NegRisk: wrapped not registered");
        address ctf = LibVaultStorage.getCtf();
        require(ctf != address(0), "Vault: ctf not set");

        uint256 noPositionCount = noPositionIds.length;
        uint256 yesPositionCount = conditionIds.length;
        uint256[] memory accumulatedNoPositionIds = new uint256[](yesPositionCount);

        // Step 1: Mint wrapped and split complementary markets
        uint256 wrapAmount = yesPositionCount * amount;
        WrappedCollateralToken(wrapped).mint(address(this), wrapAmount);
        ApprovalHelper.approveErc20IfNeeded(wrapped, ctf, wrapAmount);

        for (uint256 i = 0; i < yesPositionCount; i++) {
            bytes32 conditionId = conditionIds[i];
            // C-02: defense-in-depth — reject any conditionId not registered as a neg-risk
            // condition by the Diamond. Prevents minting unbacked WCT on attacker conditions.
            if (!LibVaultStorage.needsWrapping(conditionId)) revert UnregisteredConditionId(conditionId);
            bytes32 noCollectionId = IConditionalTokens(ctf).getCollectionId(PARENT_COLLECTION_ID, conditionId, 2);
            accumulatedNoPositionIds[i] = CTFHelpers.getPositionId(IERC20(wrapped), noCollectionId);

            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;
            IConditionalTokens(ctf).splitPosition(
                IERC20(wrapped), PARENT_COLLECTION_ID, conditionId, partition, amount
            );
        }

        // Step 2: Burn all NO tokens (user's + from splits)
        if (noPositionCount > 0) {
            IERC1155(ctf).safeBatchTransferFrom(
                address(this), NO_TOKEN_BURN_ADDRESS, noPositionIds, ArrayHelpers.filled(noPositionCount, amount), ""
            );
        }
        if (yesPositionCount > 0) {
            IERC1155(ctf).safeBatchTransferFrom(
                address(this), NO_TOKEN_BURN_ADDRESS, accumulatedNoPositionIds, ArrayHelpers.filled(yesPositionCount, amount), ""
            );
        }

        // Step 3: Release (N-1)*amount collateral to user
        if (noPositionCount > 1) {
            uint256 collateralOut = (noPositionCount - 1) * amount;
            WrappedCollateralToken(wrapped).release(user, collateralOut);
        }
    }
}
