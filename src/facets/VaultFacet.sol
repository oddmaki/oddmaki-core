// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVaultStorage} from "../storage/LibVaultStorage.sol";
import {LibVaultAggregate} from "../aggregates/LibVaultAggregate.sol";
import {LibVaultCollateralService} from "../services/LibVaultCollateralService.sol";
import {LibVaultOutcomeTokenService} from "../services/LibVaultOutcomeTokenService.sol";
import {LibVaultPositionService} from "../services/LibVaultPositionService.sol";
import {LibMarketContextService} from "../services/LibMarketContextService.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibMarketTradingValidator} from "../validators/LibMarketTradingValidator.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";

/**
 * @title VaultFacet
 * @author OddMaki Protocol
 * @notice Vault configuration and direct split/merge operations for collateral and outcome tokens.
 */
contract VaultFacet is ReentrancyGuard {
    event CtfUpdated(address indexed ctf);
    event PositionSplit(address indexed trader, uint256 indexed marketId, uint256 amount);
    event PositionsMerged(address indexed trader, uint256 indexed marketId, uint256 amount);

    /// @notice Get the vault address (the Diamond proxy itself).
    function getVault() external view returns (address) {
        return address(this);
    }

    /// @notice Get the Conditional Token Framework (CTF) contract address.
    function getCtfAddress() external view returns (address) {
        return LibVaultStorage.getCtf();
    }

    /// @notice Set the CTF contract address. Owner-only.
    /// @param ctf the Conditional Token Framework contract address.
    function setCtf(address ctf) external {
        LibDiamond.enforceIsContractOwner();
        LibVaultAggregate.setCtf(ctf);
        emit CtfUpdated(ctf);
    }

    /**
     * @notice Split `amount` of collateral into YES and NO outcome tokens.
     *         Pulls collateral from caller, mints YES + NO to caller via the CTF.
     * @param marketId The market whose condition to split against.
     * @param amount   Amount of collateral (in collateral token decimals).
     */
    function splitPosition(uint256 marketId, uint256 amount) external nonReentrant {
        LibDpmValidator.requireNotDpmMarket(marketId); // DPM markets hold no CTF outcome tokens
        LibVenueValidator.requireActiveVenueForMarket(marketId);
        LibMarketTradingValidator.requireMarketNotPaused(marketId);

        (address collateralToken, bytes32 conditionId, uint256[2] memory positionIds) =
            LibMarketContextService.getMarketTradingContext(marketId);

        LibVaultCollateralService.depositCollateral(collateralToken, msg.sender, amount);
        LibVaultPositionService.splitPosition(collateralToken, conditionId, amount);
        LibVaultOutcomeTokenService.withdrawOutcomeTokens(positionIds[0], msg.sender, amount);
        LibVaultOutcomeTokenService.withdrawOutcomeTokens(positionIds[1], msg.sender, amount);
        emit PositionSplit(msg.sender, marketId, amount);
    }

    /**
     * @notice Merge `amount` of YES and NO outcome tokens back into collateral.
     *         Pulls both outcome tokens from caller (requires setApprovalForAll on CTF),
     *         merges via the CTF, and returns collateral to caller.
     * @param marketId The market whose condition to merge.
     * @param amount   Amount of each outcome token to merge.
     */
    function mergePositions(uint256 marketId, uint256 amount) external nonReentrant {
        LibDpmValidator.requireNotDpmMarket(marketId); // DPM markets hold no CTF outcome tokens
        (address collateralToken, bytes32 conditionId, uint256[2] memory positionIds) =
            LibMarketContextService.getMarketTradingContext(marketId);

        LibVaultOutcomeTokenService.depositOutcomeTokens(positionIds[0], msg.sender, amount);
        LibVaultOutcomeTokenService.depositOutcomeTokens(positionIds[1], msg.sender, amount);
        LibVaultPositionService.mergePositions(collateralToken, conditionId, amount);
        LibVaultCollateralService.withdrawCollateral(collateralToken, msg.sender, amount);
        emit PositionsMerged(msg.sender, marketId, amount);
    }

}
