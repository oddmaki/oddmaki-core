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

import {LibPriceMarketService} from "../services/LibPriceMarketService.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";

import {LibDpmService} from "../services/LibDpmService.sol";
import {LibDpmFeeService} from "../services/LibDpmFeeService.sol";
import {LibDpmValidator} from "../validators/LibDpmValidator.sol";
import {LibDpmStorage} from "../storage/LibDpmStorage.sol";
import {LibDpmPricingService} from "../services/LibDpmPricingService.sol";

import {DpmMarket, MarketStatus} from "../interfaces/Types.sol";

/**
 * @title DpmMarketFacet
 * @author OddMaki Protocol
 * @notice Creation + read views for DPM (Dynamic Pari-Mutuel) markets — Pennock 2004 §4 ("DPM I").
 *         A self-funded trading mode parallel to the CLOB: pick a side, deposit collateral, price
 *         moves with flow. Trading (intent/enter/claim) lives in DpmTradingFacet; the split keeps
 *         each facet under the 24KB code-size limit with headroom for the N-outcome group variant.
 *
 *         v1 supports binary UMA-resolved markets (createDpmMarket) and binary Pyth price markets
 *         (createDpmPriceMarket). claim() (in DpmTradingFacet) is resolution-source-agnostic — it
 *         reads the winner from the CTF payout numerators that the shared resolution path writes.
 */
contract DpmMarketFacet is ReentrancyGuard {
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

    // =========================================================================
    // Creation (v1: binary — UMA or Pyth)
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

    /**
     * @notice Create a binary DPM market resolved by a Pyth price feed (Up/Down or explicit strike).
     *         Same pool mechanics as the UMA variant; only the resolution source differs — claim()
     *         reads the winner from the CTF payout numerators that the shared Pyth resolution path
     *         writes, exactly as for UMA.
     * @param venueId          Venue (existing, active).
     * @param pythFeedId       Pyth price feed id.
     * @param strikePrice      `0` => Up/Down (open price captured at openTime); `> 0` => strike market.
     * @param openTime         Dynamic pricing / open-price-window start; `0` => immediate (no intent).
     * @param closeTime        Trading ends / close-price window start (strictly after openTime).
     * @param outcomes         Outcome labels — must be length 2 (e.g. ["Up", "Down"]).
     * @param collateralToken  ERC20 collateral for the pool.
     * @param ancillaryData    Title + resolution description.
     * @param liveness         Stored UMA liveness (unused; price markets resolve via Pyth).
     * @param tags             Off-chain indexing tags.
     * @param resolutionWindow Pyth timestamp tolerance in seconds (0 => default 60s).
     * @return marketId        The allocated market identifier.
     */
    function createDpmPriceMarket(
        uint256 venueId,
        bytes32 pythFeedId,
        int64 strikePrice,
        uint256 openTime,
        uint256 closeTime,
        string[] calldata outcomes,
        address collateralToken,
        bytes calldata ancillaryData,
        uint64 liveness,
        bytes32[] calldata tags,
        uint256 resolutionWindow
    ) external nonReentrant returns (uint256 marketId) {
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);

        // Pyth + DPM lifecycle validation. openTime == 0 is the "immediate" sentinel (no intent phase).
        LibPriceMarketValidator.requirePythConfigured();
        if (strikePrice < 0) revert LibPriceMarketValidator.ZeroStrikePrice();
        LibDpmValidator.requireValidOpenTime(openTime);
        uint256 effectiveOpenTime = openTime == 0 ? block.timestamp : openTime;
        LibDpmValidator.requireValidCloseTime(effectiveOpenTime, closeTime);
        LibPriceMarketValidator.requireValidResolutionWindow(resolutionWindow);

        // Creation fee only — price markets do not escrow a UMA reward.
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);

        // Base market + Pyth overlay (nominal tick; outcomes length 2 enforced downstream).
        marketId = LibPriceMarketService.createPriceMarketBase(
            msg.sender,
            venueId,
            ancillaryData,
            outcomes,
            DPM_TICK_SIZE,
            collateralToken,
            liveness,
            tags,
            pythFeedId,
            strikePrice,
            effectiveOpenTime,
            closeTime,
            resolutionWindow
        );

        // DPM overlay: binary => outcomeCount 2. DPM open/close == the Pyth observation window.
        LibDpmService.initPool(marketId, 2, effectiveOpenTime, closeTime);

        emit DpmMarketCreated(marketId, venueId, msg.sender, 2, effectiveOpenTime, closeTime);
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
    /// @dev Advisory: uses the same fee rate as `enter` (0 when fees are disabled), simulates the
    ///      lazy intent seed (intent totals before the pool is initialized), and applies the
    ///      protocol-favorable share rounding. Actual fills differ if pool state changes first.
    function quoteEntryShares(uint256 marketId, uint256 outcome, uint256 amount) external view returns (uint256) {
        LibDpmValidator.requireValidOutcome(marketId, outcome);

        uint256 net = amount - (amount * LibDpmFeeService.feeBps(marketId)) / BPS_DENOMINATOR;

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
