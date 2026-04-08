// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketCreationService} from "../services/LibMarketCreationService.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibMarketCreationFeeService} from "../services/LibMarketCreationFeeService.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {LibMarketTradingStorage} from "../storage/LibMarketTradingStorage.sol";
import {LibMarketGroupValidator} from "../validators/LibMarketGroupValidator.sol";
import {LibMarketGroupStorage} from "../storage/LibMarketGroupStorage.sol";
import {LibMarketGroupAggregate} from "../aggregates/LibMarketGroupAggregate.sol";
import {LibAncillaryData} from "../libraries/LibAncillaryData.sol";
import {LibMarketOracleAggregate} from "../aggregates/LibMarketOracleAggregate.sol";
import {LibMarketRegistryAggregate} from "../aggregates/LibMarketRegistryAggregate.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {MarketRegistryData, MarketOracleData, MarketTradingData, MarketGroupData, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title MarketsFacet
 * @author OddMaki Protocol
 * @notice Market creation, market group membership, and market data queries.
 *         Supports standalone markets and grouped markets (add, placeholder, activate).
 */
contract MarketsFacet is ReentrancyGuard {

    // ---- Events ----
    event MarketPausedEvent(uint256 indexed marketId, uint256 indexed venueId, address indexed operator);
    event MarketUnpausedEvent(uint256 indexed marketId, uint256 indexed venueId, address indexed operator);
    event MarketAddedToGroup(uint256 indexed groupId, uint256 indexed marketId, string marketName, string marketQuestion);
    event PlaceholderMarketsAdded(uint256 indexed groupId, uint256[] marketIds, uint256 count);
    event PlaceholderActivated(
        uint256 indexed groupId, uint256 indexed marketId, string marketName, string marketQuestion, uint256 timestamp
    );

    // ---- Mutations ----

    /**
     * @notice Create a standalone binary market.
     * @param venueId         Venue this market belongs to (must be an existing, active venue).
     * @param ancillaryData   SDK-provided ancillary data (title, description, resolution criteria).
     * @param outcomes        Outcome strings — must be ["Yes", "No"].
     * @param tickSize        Price increment per tick (e.g. 1e16 = 1%).
     * @param collateralToken ERC20 collateral for trading and oracle bond/reward.
     * @param additionalReward Extra UMA reward on top of venue default.
     * @param liveness        UMA liveness in seconds (minimum 2h enforced by oracle service).
     * @return marketId       The allocated market identifier.
     */
    function createMarket(
        uint256 venueId,
        bytes calldata ancillaryData,
        string[] calldata outcomes,
        uint256 tickSize,
        address collateralToken,
        uint256 additionalReward,
        uint64 liveness,
        bytes32[] calldata tags
    ) external nonReentrant returns (uint256 marketId) {
        // Venue must exist and be active; then check creation access control.
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);

        // Fee collection — stays in facet (needs msg.sender; reads fee amount from venue config).
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);

        // Collect UMA reward from creator — held by Diamond until resolution.
        uint256 reward = LibVenueStorage.getVenueData(venueId).umaRewardAmount + additionalReward;
        if (reward > 0) {
            TransferHelper._transferFromErc20(collateralToken, msg.sender, address(this), reward);
        }

        // All creation logic delegated to the shared service.
        // Standalone markets: groupId = 0, initialStatus = Active.
        marketId = LibMarketCreationService.createMarket(
            msg.sender,
            venueId,
            ancillaryData,
            outcomes,
            tickSize,
            collateralToken,
            additionalReward,
            liveness,
            0, // groupId: standalone
            MarketStatus.Active,
            tags
        );
    }

    /**
     * @notice Add a named market to a Draft group.
     * @param groupId       The group to add to (must be Draft, caller must be creator).
     * @param marketName    Short name for display (e.g. "Warriors").
     * @param marketQuestion The question for this specific market.
     * @return marketId     The allocated market identifier.
     */
    function addMarket(uint256 groupId, string calldata marketName, string calldata marketQuestion)
        external
        nonReentrant
        returns (uint256 marketId)
    {
        LibMarketGroupValidator.requireDraftGroupCreator(groupId, msg.sender);

        marketId = _addMarketToGroup(groupId, msg.sender, marketName, marketQuestion, false);

        emit MarketAddedToGroup(groupId, marketId, marketName, marketQuestion);
    }

    /**
     * @notice Add placeholder markets to a Draft group (to be activated later).
     * @param groupId The group to add to (must be Draft, caller must be creator).
     * @param count   Number of placeholders to add (max 50 total in group).
     * @return marketIds Array of allocated market identifiers.
     */
    function addPlaceholderMarkets(uint256 groupId, uint256 count)
        external
        nonReentrant
        returns (uint256[] memory marketIds)
    {
        LibMarketGroupValidator.requireDraftGroupCreator(groupId, msg.sender);

        marketIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            marketIds[i] = _addMarketToGroup(groupId, msg.sender, "", "", true);
        }

        emit PlaceholderMarketsAdded(groupId, marketIds, count);
    }

    /**
     * @notice Activate a placeholder market within an Active group.
     * @param groupId       The group (must be Active, caller must be creator).
     * @param marketId      The placeholder market to activate.
     * @param marketName    New display name.
     * @param marketQuestion New question (updates UMA ancillary data).
     */
    function activatePlaceholder(
        uint256 groupId,
        uint256 marketId,
        string calldata marketName,
        string calldata marketQuestion
    ) external nonReentrant {
        LibMarketGroupValidator.requireActiveGroupCreator(groupId, msg.sender);
        LibMarketGroupValidator.requirePlaceholder(marketId);

        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);

        // Update own-domain item data
        LibMarketGroupAggregate.updatePlaceholderItem(marketId, marketName);

        // Build new ancillaryData with real question
        bytes memory newAncillaryData = LibAncillaryData.create(marketQuestion, group.description);

        // Enrich with market identity fields
        MarketRegistryData storage registry = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        bytes memory enrichedAncillaryData = LibAncillaryData.enrichAncillaryData(
            newAncillaryData, marketId, group.venueId, group.creator, address(this), block.chainid
        );

        // Update oracle ancillaryData so UMA question is correct
        LibMarketOracleAggregate.setAncillaryData(registry.questionId, enrichedAncillaryData);

        // Activate the market
        LibMarketRegistryAggregate.setStatus(marketId, MarketStatus.Active);
        LibMarketTradingAggregate.setActive(marketId, true);

        emit PlaceholderActivated(groupId, marketId, marketName, marketQuestion, block.timestamp);
    }

    // ---- Market Moderation ----

    /// @notice Pause a market. Only the venue operator can call. Blocks trading but allows cancellations.
    function pauseMarket(uint256 marketId) external nonReentrant {
        uint256 venueId = LibMarketRegistryStorage.getMarketRegistryData(marketId).venueId;
        LibVenueValidator.requireExistingVenueOperator(venueId, msg.sender);
        LibMarketTradingAggregate.setPaused(marketId, true);
        emit MarketPausedEvent(marketId, venueId, msg.sender);
    }

    /// @notice Unpause a market. Only the venue operator can call.
    function unpauseMarket(uint256 marketId) external nonReentrant {
        uint256 venueId = LibMarketRegistryStorage.getMarketRegistryData(marketId).venueId;
        LibVenueValidator.requireExistingVenueOperator(venueId, msg.sender);
        LibMarketTradingAggregate.setPaused(marketId, false);
        emit MarketUnpausedEvent(marketId, venueId, msg.sender);
    }

    // ---- Internal ----

    function _addMarketToGroup(
        uint256 groupId,
        address caller,
        string memory marketName,
        string memory marketQuestion,
        bool isPlaceholder
    ) private returns (uint256 marketId) {
        LibMarketGroupValidator.validateAddMarket(groupId);

        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);

        // Build ancillaryData from question + group description
        bytes memory ancillaryData = LibAncillaryData.create(marketQuestion, group.description);

        // Create outcomes
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";

        // Create market via shared service (Draft status, grouped)
        // Grouped markets inherit tags from their group (indexed in subgraph).
        bytes32[] memory emptyTags = new bytes32[](0);
        marketId = LibMarketCreationService.createMarket(
            caller,
            group.venueId,
            ancillaryData,
            outcomes,
            group.tickSize,
            address(group.collateralToken),
            group.additionalReward,
            group.liveness,
            groupId,
            MarketStatus.Draft,
            emptyTags
        );

        // Register in group storage
        LibMarketGroupAggregate.addMarketToGroup(groupId, marketId, marketName, isPlaceholder);
    }

    // ---- Views ----

    /// @notice Lifecycle and identity data for a market (venue, creator, status, oracle link).
    function getMarketRegistryData(uint256 marketId) external view returns (MarketRegistryData memory) {
        return LibMarketRegistryStorage.getMarketRegistryData(marketId);
    }

    /// @notice Exchange-facing data for a market (tickSize, active, collateralToken, positionIds, volume).
    function getMarketTradingData(uint256 marketId) external view returns (MarketTradingData memory) {
        return LibMarketTradingStorage.getMarketTradingData(marketId);
    }

    /// @notice Oracle / CTF data for a market (conditionId, outcomes, UMA economics).
    ///         Resolves marketId → questionId via the Registry layer internally.
    function getMarketOracleData(uint256 marketId) external view returns (MarketOracleData memory) {
        bytes32 questionId = LibMarketRegistryStorage.getStorage().byMarketId[marketId].questionId;
        return LibMarketOracleStorage.getMarketOracleData(questionId);
    }

    /// @notice Returns the next market ID that will be allocated on the next createMarket call.
    function getNextMarketId() external view returns (uint256) {
        return LibMarketRegistryStorage.getNextMarketId();
    }
}
