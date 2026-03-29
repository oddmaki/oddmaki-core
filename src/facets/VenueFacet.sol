// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibVenueAggregate} from "../aggregates/LibVenueAggregate.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {VenueData} from "../interfaces/Types.sol";

/**
 * @title VenueFacet
 * @author OddMaki Protocol
 * @notice Venue creation and management. Venues are operator-owned containers that define
 *         trading rules, fee structures, access controls, and oracle parameters for their markets.
 */
contract VenueFacet is ReentrancyGuard {
    // ---- Events ----
    event VenueCreated(uint256 indexed venueId, address indexed operator, string name, string metadata);
    event VenueUpdated(uint256 indexed venueId, address indexed operator, string name, string metadata);
    event VenueFeesUpdated(uint256 indexed venueId, uint256 venueFeeBps, uint256 creatorFeeBps);
    event VenueOracleParamsUpdated(uint256 indexed venueId, uint256 umaRewardAmount, uint256 umaMinBond);
    event VenueAccessControlUpdated(uint256 indexed venueId, address tradingAccessControl, address creationAccessControl);
    event VenuePaused(uint256 indexed venueId, address indexed operator);
    event VenueUnpaused(uint256 indexed venueId, address indexed operator);

    // ---- Mutations ----

    /**
     * @notice Create a new venue. The caller becomes the venue operator.
     * @param name                  human-readable venue name (must be non-empty).
     * @param metadata              off-chain metadata URI (e.g. IPFS hash for description/branding).
     * @param tradingAccessControl   access control contract for trading (address(0) for open access).
     * @param creationAccessControl  access control contract for market creation (address(0) for open access).
     * @param feeRecipient          address that receives venue and creator fees from trades.
     * @param venueFeeBps           venue fee in basis points (1–200 bps).
     * @param creatorFeeBps         creator fee in basis points (0–venueFeeBps). Subtracted from venue fee.
     * @param defaultTickSize       default price increment for markets created under this venue.
     * @param marketCreationFee     upfront fee (in collateral) charged to create a market (minimum 5 USDC).
     * @param umaRewardAmount       base UMA reward amount for oracle assertions.
     * @param umaMinBond            minimum bond required for UMA assertions.
     * @return venueId              the allocated venue identifier.
     */
    function createVenue(
        string calldata name,
        string calldata metadata,
        address tradingAccessControl,
        address creationAccessControl,
        address feeRecipient,
        uint256 venueFeeBps,
        uint256 creatorFeeBps,
        uint256 defaultTickSize,
        uint256 marketCreationFee,
        uint256 umaRewardAmount,
        uint256 umaMinBond
    ) external nonReentrant returns (uint256 venueId) {
        venueId = LibVenueAggregate.createVenue(
            msg.sender,
            name,
            metadata,
            tradingAccessControl,
            creationAccessControl,
            feeRecipient,
            venueFeeBps,
            creatorFeeBps,
            defaultTickSize,
            marketCreationFee,
            umaRewardAmount,
            umaMinBond
        );
        emit VenueCreated(venueId, msg.sender, name, metadata);
        emit VenueAccessControlUpdated(venueId, tradingAccessControl, creationAccessControl);
    }

    /**
     * @notice Update venue identity, access controls, and fee recipient. Operator-only.
     * @param venueId               the venue to update.
     * @param name                  new venue name.
     * @param metadata              new off-chain metadata URI.
     * @param tradingAccessControl   new trading access control contract (address(0) for open access).
     * @param creationAccessControl  new market creation access control contract (address(0) for open access).
     * @param feeRecipient          new fee recipient address.
     */
    function updateVenue(
        uint256 venueId,
        string calldata name,
        string calldata metadata,
        address tradingAccessControl,
        address creationAccessControl,
        address feeRecipient
    ) external nonReentrant {
        LibVenueAggregate.updateVenue(
            venueId, msg.sender, name, metadata, tradingAccessControl, creationAccessControl, feeRecipient
        );
        emit VenueUpdated(venueId, msg.sender, name, metadata);
        emit VenueAccessControlUpdated(venueId, tradingAccessControl, creationAccessControl);
    }

    /**
     * @notice Update venue fee rates. Operator-only.
     * @param venueId      the venue to update.
     * @param venueFeeBps  new venue fee in basis points (1–200 bps).
     * @param creatorFeeBps new creator fee in basis points (0–venueFeeBps).
     * @dev Fee changes only affect markets created after this call.
     *      Existing markets use the fee rates that were snapshotted at market creation.
     */
    function updateVenueFees(uint256 venueId, uint256 venueFeeBps, uint256 creatorFeeBps) external nonReentrant {
        LibVenueAggregate.updateVenueFees(venueId, msg.sender, venueFeeBps, creatorFeeBps);
        emit VenueFeesUpdated(venueId, venueFeeBps, creatorFeeBps);
    }

    /**
     * @notice Update UMA oracle parameters for future markets. Operator-only.
     * @param venueId        the venue to update.
     * @param umaRewardAmount new base UMA reward amount.
     * @param umaMinBond     new minimum bond for UMA assertions.
     */
    function updateVenueOracleParams(uint256 venueId, uint256 umaRewardAmount, uint256 umaMinBond)
        external
        nonReentrant
    {
        LibVenueAggregate.updateVenueOracleParams(venueId, msg.sender, umaRewardAmount, umaMinBond);
        emit VenueOracleParamsUpdated(venueId, umaRewardAmount, umaMinBond);
    }

    /// @notice Pause a venue, blocking new orders and market creation. Operator-only.
    /// @param venueId the venue to pause.
    function pauseVenue(uint256 venueId) external nonReentrant {
        LibVenueAggregate.pauseVenue(venueId, msg.sender);
        emit VenuePaused(venueId, msg.sender);
    }

    /// @notice Unpause a previously paused venue. Operator-only.
    /// @param venueId the venue to unpause.
    /// @dev Reverts if the venue is suspended at the protocol level.
    function unpauseVenue(uint256 venueId) external nonReentrant {
        LibVenueAggregate.unpauseVenue(venueId, msg.sender);
        emit VenueUnpaused(venueId, msg.sender);
    }

    // ---- Views ----

    /// @notice Get the full configuration for a venue.
    /// @param venueId the venue to query.
    function getVenue(uint256 venueId) external view returns (VenueData memory) {
        if (!LibVenueStorage.venueExists(venueId)) revert LibVenueValidator.VenueNotFound();
        return LibVenueStorage.getVenueData(venueId);
    }

    /// @notice Get the next venue ID that will be allocated.
    function getNextVenueId() external view returns (uint256) {
        return LibVenueStorage.getNextVenueId();
    }

    /// @notice Get the current fee rates for a venue.
    /// @param venueId the venue to query.
    /// @return venueFeeBps the venue fee in basis points.
    /// @return creatorFeeBps the creator fee in basis points.
    function getVenueFees(uint256 venueId) external view returns (uint256 venueFeeBps, uint256 creatorFeeBps) {
        if (!LibVenueStorage.venueExists(venueId)) revert LibVenueValidator.VenueNotFound();
        VenueData storage venue = LibVenueStorage.getVenueData(venueId);
        return (venue.venueFeeBps, venue.creatorFeeBps);
    }

    /// @notice Check if a user is authorized to trade on a venue.
    /// @param user the address to check.
    /// @param venueId the venue to check against.

    function canTrade(address user, uint256 venueId) external view returns (bool) {
        return LibAccessControlValidator.canTradeOnVenue(user, venueId);
    }

    /// @notice Check if a user is authorized to create markets on a venue.
    /// @param user the address to check.
    /// @param venueId the venue to check against.

    function canCreateMarket(address user, uint256 venueId) external view returns (bool) {
        return LibAccessControlValidator.canCreateMarket(user, venueId);
    }
}
