// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketGroupAggregate} from "../aggregates/LibMarketGroupAggregate.sol";
import {LibMarketGroupValidator} from "../validators/LibMarketGroupValidator.sol";
import {LibMarketGroupStorage} from "../storage/LibMarketGroupStorage.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibTagValidator} from "../validators/LibTagValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibMarketCreationFeeService} from "../services/LibMarketCreationFeeService.sol";
import {LibTickSizeValidator} from "../validators/LibTickSizeValidator.sol";
import {LibMarketRegistryAggregate} from "../aggregates/LibMarketRegistryAggregate.sol";
import {LibMarketTradingAggregate} from "../aggregates/LibMarketTradingAggregate.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {MarketGroupData, MarketGroupItem, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title MarketGroupFacet
 * @author OddMaki Protocol
 * @notice Market group lifecycle management. Market groups bundle N mutually exclusive binary
 *         markets where exactly one resolves YES (e.g. "Which team wins the championship?").
 *         Flow: createMarketGroup -> add markets via MarketsFacet -> activateMarketGroup.
 */
contract MarketGroupFacet is ReentrancyGuard {
    // ---- Events ----
    event MarketGroupCreated(
        uint256 indexed groupId, uint256 indexed venueId, address indexed creator, string question, uint256 timestamp, bytes32[] tags
    );
    event MarketGroupActivated(uint256 indexed groupId, uint256 marketCount, uint256 timestamp);

    // ---- Mutations ----

    /**
     * @notice Create a new market group (parent metadata only). Markets added via MarketsFacet.addMarket().
     * @param venueId         Venue this group belongs to (must be active, caller must have creation access).
     * @param question        Group-level question (e.g. "Where will Giannis be traded?").
     * @param description     Resolution criteria (reused across all markets in the group).
     * @param collateralToken ERC20 collateral for all markets in the group.
     * @param tickSize        Price increment per tick for all markets in the group.
     * @param additionalReward Extra UMA reward on top of venue default.
     * @param liveness        UMA liveness in seconds.
     * @return groupId        The allocated group identifier.
     */
    function createMarketGroup(
        uint256 venueId,
        string calldata question,
        string calldata description,
        address collateralToken,
        uint256 tickSize,
        uint256 additionalReward,
        uint64 liveness,
        bytes32[] calldata tags
    ) external nonReentrant returns (uint256 groupId) {
        LibMarketGroupValidator.validateCreateGroupParams(question);
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibTagValidator.validateTags(tags);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);
        LibTickSizeValidator.requireValidTickSize(tickSize);
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);

        // Collect UMA reward from creator — held by Diamond until group resolution.
        uint256 reward = LibVenueStorage.getVenueData(venueId).umaRewardAmount + additionalReward;
        if (reward > 0) {
            TransferHelper._transferFromErc20(collateralToken, msg.sender, address(this), reward);
        }

        groupId = LibMarketGroupAggregate.createGroup(
            msg.sender, venueId, question, description, collateralToken, tickSize, additionalReward, liveness, reward
        );

        emit MarketGroupCreated(groupId, venueId, msg.sender, question, block.timestamp, tags);
    }

    /**
     * @notice Activate a market group. Locks totalMarkets and activates non-placeholder markets.
     * @param groupId The group (must be Draft, >= 2 markets, caller must be creator).
     */
    function activateMarketGroup(uint256 groupId) external nonReentrant {
        LibMarketGroupValidator.requireDraftGroupCreator(groupId, msg.sender);
        LibMarketGroupValidator.validateActivation(groupId);

        MarketGroupData storage group = LibMarketGroupStorage.getMarketGroupData(groupId);
        LibMarketGroupStorage.Storage storage s = LibMarketGroupStorage.getStorage();

        // Lock totalMarkets and set status
        LibMarketGroupAggregate.lockTotalMarkets(groupId);
        LibMarketGroupAggregate.setGroupStatus(groupId, MarketStatus.Active);

        // Activate non-placeholder markets
        uint256 activeCount = 0;
        for (uint256 i = 0; i < group.marketIds.length; i++) {
            uint256 mId = group.marketIds[i];
            if (!s.itemByMarketId[mId].isPlaceholder) {
                activeCount++;
                LibMarketRegistryAggregate.setStatus(mId, MarketStatus.Active);
                LibMarketTradingAggregate.setActive(mId, true);
            }
        }

        emit MarketGroupActivated(groupId, activeCount, block.timestamp);
    }

    // ---- Views ----

    /// @notice Get full data for a market group.
    /// @param groupId the group to query.
    function getMarketGroup(uint256 groupId) external view returns (MarketGroupData memory) {
        LibMarketGroupValidator.requireGroupExists(groupId);
        return LibMarketGroupStorage.getMarketGroupData(groupId);
    }

    /// @notice Get all market IDs belonging to a group.
    /// @param groupId the group to query.
    function getGroupMarketIds(uint256 groupId) external view returns (uint256[] memory) {
        LibMarketGroupValidator.requireGroupExists(groupId);
        return LibMarketGroupStorage.getMarketGroupData(groupId).marketIds;
    }

    /// @notice Get group-specific data for a market (placeholder status, display name).
    /// @param marketId the market to query.
    function getMarketGroupItem(uint256 marketId) external view returns (MarketGroupItem memory) {
        return LibMarketGroupStorage.getMarketGroupItem(marketId);
    }

    /// @notice Get the next group ID that will be allocated.
    function getNextGroupId() external view returns (uint256) {
        return LibMarketGroupStorage.getNextGroupId();
    }
}
