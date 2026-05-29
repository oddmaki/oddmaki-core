// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibMarketCreationService} from "../services/LibMarketCreationService.sol";
import {LibMarketCreationFeeService} from "../services/LibMarketCreationFeeService.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibVenueStorage} from "../storage/LibVenueStorage.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

import {LibDpmService} from "../services/LibDpmService.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";
import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibDpmPricingService} from "../services/LibDpmPricingService.sol";
import {LibFeeCalculatorService} from "../services/LibFeeCalculatorService.sol";

import {DpmMarket, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title DpmFacet
 * @author OddMaki Protocol
 * @notice Entry points for DPM (Dynamic Pari-Mutuel) markets — Pennock 2004 §4 ("DPM I").
 *         A self-funded trading mode parallel to the CLOB: pick a side, deposit collateral, and
 *         price moves with flow. v1 is binary, UMA-resolved, no group / no Pyth / no exit.
 *
 *         Thin wrappers: all lifecycle guards, pricing, fees and accounting live in LibDpmService;
 *         this facet adds the diamond `nonReentrant` boundary, creation fee/reward collection
 *         (mirroring MarketsFacet.createMarket), events for indexing, and read-only views.
 */
contract DpmFacet is ReentrancyGuard {
    /// @dev Nominal tick size for the base market. DPM does not tick-quantize; this only satisfies
    ///      the base creation validator and feeds the cosmetic last-trade-tick stat. 1e16 = 1%.
    uint256 private constant DPM_TICK_SIZE = 1e16;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    event DpmMarketCreated(
        uint256 indexed marketId,
        uint256 indexed venueId,
        address indexed creator,
        uint256 outcomeCount,
        uint256 openTime,
        uint256 closeTime
    );
    event DpmIntentEntered(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount);
    event DpmIntentExited(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount);
    event DpmEntered(uint256 indexed marketId, address indexed user, uint256 outcome, uint256 amount, uint256 shares);
    event DpmClaimed(uint256 indexed marketId, address indexed user, uint256 payout);

    // =========================================================================
    // Creation (v1: binary, UMA-resolved)
    // =========================================================================

    /**
     * @notice Create a standalone binary DPM market with an optional intent (pre-game) phase.
     * @param venueId          Venue this market belongs to (existing, active).
     * @param ancillaryData    SDK ancillary data (title, description, resolution criteria).
     * @param outcomes         Outcome strings — must be ["Yes", "No"].
     * @param collateralToken  ERC20 collateral for the pool and UMA bond/reward.
     * @param additionalReward Extra UMA reward on top of the venue default.
     * @param liveness         UMA liveness seconds (min 2h enforced downstream).
     * @param openTime         Dynamic pricing begins; `0` => immediate (no intent phase).
     *                         Before openTime, enterIntent/exitIntent are 1:1 refundable.
     * @param closeTime        Trading ends (must be strictly after the effective openTime).
     * @param tags             Off-chain indexing tags.
     * @return marketId        The allocated market identifier.
     */
    function createDpmMarket(
        uint256 venueId,
        bytes calldata ancillaryData,
        string[] calldata outcomes,
        address collateralToken,
        uint256 additionalReward,
        uint64 liveness,
        uint256 openTime,
        uint256 closeTime,
        bytes32[] calldata tags
    ) external nonReentrant returns (uint256 marketId) {
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);

        // Resolve the lifecycle window (openTime == 0 is the "immediate" sentinel).
        LibDpmValidator.requireValidOpenTime(openTime);
        uint256 effectiveOpenTime = openTime == 0 ? block.timestamp : openTime;
        LibDpmValidator.requireValidCloseTime(effectiveOpenTime, closeTime);

        // Creation fee + UMA reward collection (identical to MarketsFacet.createMarket).
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);
        uint256 reward = LibVenueStorage.getVenueData(venueId).umaRewardAmount + additionalReward;
        if (reward > 0) {
            TransferHelper._transferFromErc20(collateralToken, msg.sender, address(this), reward);
        }

        // Base market: standalone (groupId 0), Active, nominal tick. Outcomes length (2) enforced here.
        marketId = LibMarketCreationService.createMarket(
            msg.sender,
            venueId,
            ancillaryData,
            outcomes,
            DPM_TICK_SIZE,
            collateralToken,
            additionalReward,
            liveness,
            0,
            MarketStatus.Active,
            tags
        );

        // DPM overlay: binary => outcomeCount 2.
        LibDpmService.initPool(marketId, 2, effectiveOpenTime, closeTime);

        emit DpmMarketCreated(marketId, venueId, msg.sender, 2, effectiveOpenTime, closeTime);
    }

    // =========================================================================
    // Trading
    // =========================================================================

    /// @notice Deposit a 1:1 refundable intent stake before openTime (no fee, no pricing).
    function enterIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.enterIntent(msg.sender, marketId, outcome, amount);
        emit DpmIntentEntered(marketId, msg.sender, outcome, amount);
    }

    /// @notice Withdraw a refundable intent stake before openTime (1:1).
    function exitIntent(uint256 marketId, uint256 outcome, uint256 amount) external nonReentrant {
        LibDpmService.exitIntent(msg.sender, marketId, outcome, amount);
        emit DpmIntentExited(marketId, msg.sender, outcome, amount);
    }

    /// @notice Enter the dynamic pool (openTime <= now < closeTime). Charges the entry fee and
    ///         buys shares at the Pennock price. Returns the shares minted.
    function enter(uint256 marketId, uint256 outcome, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = LibDpmService.enter(msg.sender, marketId, outcome, amount);
        emit DpmEntered(marketId, msg.sender, outcome, amount, shares);
    }

    /// @notice Claim a resolved market's payout (DPM I: refund of price paid + losers'-pool slice;
    ///         full refund on invalid / no-contest). Returns the collateral paid out.
    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        payout = LibDpmService.claim(msg.sender, marketId);
        emit DpmClaimed(marketId, msg.sender, payout);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function isDpmMarket(uint256 marketId) external view returns (bool) {
        return LibDpmStorage.isDpmMarket(marketId);
    }

    function getDpmMarket(uint256 marketId) external view returns (DpmMarket memory) {
        return LibDpmStorage.getDpmMarket(marketId);
    }

    /// @notice Live pool collateral M_i on `outcome`.
    function getMarketCollateral(uint256 marketId, uint256 outcome) external view returns (uint256) {
        return LibDpmStorage.getCollateral(marketId, outcome);
    }

    /// @notice Live shares outstanding N_i on `outcome`.
    function getMarketShares(uint256 marketId, uint256 outcome) external view returns (uint256) {
        return LibDpmStorage.getShares(marketId, outcome);
    }

    function getIntentStake(uint256 marketId, address user, uint256 outcome) external view returns (uint256) {
        return LibDpmStorage.getIntentStake(marketId, user, outcome);
    }

    function getUserShares(uint256 marketId, address user, uint256 outcome) external view returns (uint256) {
        return LibDpmStorage.getUserShares(marketId, user, outcome);
    }

    function getUserPaid(uint256 marketId, address user, uint256 outcome) external view returns (uint256) {
        return LibDpmStorage.getUserPaid(marketId, user, outcome);
    }

    /// @notice Quote shares received for `amount` collateral on `outcome`, net of the entry fee.
    /// @dev Advisory: simulates the lazy intent seed (uses intent totals before the pool is
    ///      initialized) and the protocol-favorable share rounding. Actual fills may differ if the
    ///      pool state changes before the transaction lands.
    function quoteEntryShares(uint256 marketId, uint256 outcome, uint256 amount) external view returns (uint256) {
        LibDpmValidator.requireValidOutcome(marketId, outcome);

        uint256 totalFeeBps = LibFeeCalculatorService.getSnapshotedTotalFeeBps(marketId);
        uint256 net = amount - (amount * totalFeeBps) / BPS_DENOMINATOR;

        bool seeded = LibDpmStorage.getDpmMarket(marketId).poolInitialized;
        uint256 mI;
        uint256 nOther;
        if (seeded) {
            mI = LibDpmStorage.getCollateral(marketId, outcome);
            nOther = LibDpmStorage.getOtherShares(marketId, outcome);
        } else {
            // Pre-seed: par seed sets M_i = N_i = intentTotals_i, so N_other = Σ_{j!=i} intentTotals_j.
            mI = LibDpmStorage.getIntentTotal(marketId, outcome);
            uint256 oc = LibDpmStorage.getDpmMarket(marketId).outcomeCount;
            for (uint256 j = 0; j < oc; j++) {
                if (j != outcome) nOther += LibDpmStorage.getIntentTotal(marketId, j);
            }
        }
        return LibDpmPricingService.sharesForCollateral(mI, nOther, net);
    }
}
