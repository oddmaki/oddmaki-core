// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketRegistryAggregate} from "../aggregates/LibMarketRegistryAggregate.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibVaultRegistrationService} from "./LibVaultRegistrationService.sol";
import {LibOracleInitializationService} from "./LibOracleInitializationService.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibProtocolStorage} from "../storage/LibProtocolStorage.sol";
import {LibAncillaryData} from "../libraries/LibAncillaryData.sol";
import {LibTagValidator} from "../validators/LibTagValidator.sol";
import {LibTickSizeValidator} from "../validators/LibTickSizeValidator.sol";
import {MarketStatus} from "../interfaces/Types.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title LibMarketCreationService
 * @notice Shared market creation path used by MarketsFacet (standalone) and the future
 *         market-groups facet (grouped markets).
 *
 *         External calls reduced to ONE: CTF.prepareCondition (inside LibOracleInitializationService).
 *         All state writes go directly to diamond storage via aggregates.
 *
 *         Creation order (each step runs only when its inputs are available):
 *           1. Validate inputs
 *           2. Allocate marketId
 *           3. Enrich ancillaryData (market identity + oracle resolution fields, one pass)
 *           4. Generate stable questionId
 *           5. Fetch oracle parameters from venue (stubs until venues are wired)
 *           6. Write Registry
 *           7. Oracle init → conditionId (writes MarketOracleData, calls CTF.prepareCondition)
 *           8. Vault registration → positionIds
 *           9. Write Trading
 */
library LibMarketCreationService {
    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed venueId,
        address indexed creator,
        bytes32 conditionId,
        address collateralToken,
        uint256 tickSize,
        string question,
        string[] outcomes,
        uint256 groupId,
        bytes32[] tags
    );

    error InvalidOutcomesLength();

    /**
     * @notice Create a market and write all three storage layers (Registry, Oracle, Trading).
     * @param creator         Address that initiated the market (msg.sender from facet).
     * @param venueId         Venue this market belongs to.
     * @param ancillaryData   SDK-provided ancillary data (title, description, resolution criteria).
     * @param outcomes        Outcome strings — must be length 2 (["Yes", "No"]).
     * @param tickSize        Price increment per tick; must be > 0.
     * @param collateralToken ERC20 collateral for trading and oracle economics.
     * @param additionalReward Extra UMA reward on top of venue default.
     * @param liveness        UMA liveness in seconds (floored to 2h inside oracle service).
     * @param groupId         0 for standalone markets; >0 for market group members.
     * @param initialStatus   MarketStatus.Active for standalone; MarketStatus.Draft for grouped.
     * @return marketId       The allocated market identifier.
     */
    function createMarket(
        address creator,
        uint256 venueId,
        bytes memory ancillaryData,
        string[] memory outcomes,
        uint256 tickSize,
        address collateralToken,
        uint256 additionalReward,
        uint64 liveness,
        uint256 groupId,
        MarketStatus initialStatus,
        bytes32[] memory tags,
        bool allowMultiOutcome
    ) internal returns (uint256 marketId) {
        // Step 1: Validate inputs. Tokenized binary markets (CLOB orderbook + binary DPM) MUST have
        //         exactly 2 outcomes; only multi-outcome DPM (allowMultiOutcome) may exceed 2. The
        //         oracle/condition layer below is sized from `outcomes.length`; the binary-specific
        //         step is vault registration (Step 8), itself gated on length == 2.
        if (outcomes.length < 2) revert InvalidOutcomesLength();
        if (!allowMultiOutcome && outcomes.length != 2) revert InvalidOutcomesLength();
        LibTickSizeValidator.requireValidTickSize(tickSize);
        LibTagValidator.validateTagsMemory(tags);

        // Step 2: Allocate marketId first so it can be embedded in ancillaryData and questionId.
        marketId = LibMarketRegistryStorage.allocateMarketId();

        // Step 3: Enrich ancillaryData in one pass.
        //   Appends: market_id, venue_id, initializer, res_data (payout mapping), ooRequester (Diamond), chain_id.
        bytes memory enrichedAncillaryData =
            LibAncillaryData.enrichAncillaryData(ancillaryData, marketId, venueId, creator, address(this), block.chainid);

        // Step 4: Generate stable questionId — independent of ancillaryData content so placeholder
        //         markets can update their question without invalidating CTF tokens or conditionId.
        bytes32 questionId =
            LibAncillaryData.generateQuestionId(address(this), block.chainid, venueId, marketId);

        // Step 5: Fetch oracle parameters from venue.
        // Grouped markets have reward = 0 here; their reward is collected at group level.
        uint256 reward = groupId > 0 ? 0 : LibVenueStorage.getVenueData(venueId).umaRewardAmount + additionalReward;
        uint256 requiredBond = LibVenueStorage.getVenueData(venueId).umaMinBond;

        // Step 6: Write Registry — all fields known; conditionId not in registry.
        LibMarketRegistryAggregate.createRegistry(
            marketId,
            venueId,
            creator,
            initialStatus,
            groupId,
            questionId,
            address(this), // Diamond proxy is the oracle (via address(this) in delegatecall)
            tickSize
        );

        // Step 6b: Snapshot fee BPS and recipient addresses onto market (immutable per market).
        LibMarketRegistryAggregate.setFeeSnapshot(
            marketId,
            LibVenueStorage.getVenueData(venueId).venueFeeBps,
            LibVenueStorage.getVenueData(venueId).creatorFeeBps,
            LibProtocolStorage.getProtocolFeeBps(),
            LibProtocolStorage.getProtocolTreasury(),
            LibVenueStorage.getVenueData(venueId).feeRecipient
        );

        // Step 7: Oracle initialization.
        //   Computes conditionId = keccak256(abi.encodePacked(Diamond, questionId, 2)),
        //   writes MarketOracleData, then calls CTF.prepareCondition (the only external call).
        bytes32 conditionId = LibOracleInitializationService.initialize(
            questionId, enrichedAncillaryData, outcomes, collateralToken, reward, requiredBond, liveness
        );

        // Step 8: Vault registration — computes [YES, NO] CTF outcome-token position IDs. This is
        //   binary-only: N-outcome markets (DPM) trade no outcome tokens, so they skip registration
        //   and carry empty position IDs. groupId > 0 signals wrapped collateral (NegRisk), which is
        //   itself binary, so it only ever co-occurs with outcomes.length == 2.
        uint256[2] memory positionIds;
        if (outcomes.length == 2) {
            bool needsWrapping = groupId > 0;
            positionIds = LibVaultRegistrationService.registerCondition(conditionId, collateralToken, needsWrapping);
        }

        // Step 9: Write Trading — all fields now available.
        LibMarketTradingAggregate.createTrading(
            marketId,
            tickSize,
            IERC20(collateralToken),
            positionIds,
            initialStatus == MarketStatus.Active
        );

        // Step 10: Emit enriched MarketCreated with all indexing data.
        emit MarketCreated(
            marketId,
            venueId,
            creator,
            conditionId,
            collateralToken,
            tickSize,
            string(ancillaryData),
            outcomes,
            groupId,
            tags
        );

        return marketId;
    }
}
