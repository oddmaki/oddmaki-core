// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025-2026 Predictable Reality, Inc.
// Author: Carlos Revelo (Predictable Reality, Inc.)
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";
import {LibPriceMarketService} from "../services/LibPriceMarketService.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibMarketCreationFeeService} from "../services/LibMarketCreationFeeService.sol";
import {LibResolutionService} from "../services/LibResolutionService.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {MarketRegistryData, MarketOracleData, MarketStatus, PriceMarket, FeedProvider} from "../interfaces/Types.sol";

/**
 * @title PythResolutionFacet
 * @author OddMaki Protocol
 * @notice Pyth-specific admin, creation, and resolution for price markets.
 *
 *         Creation creates a standard OddMaki market and stores a price-market overlay.
 *         No Pyth interaction happens at creation — no VAA submission, no fee, no
 *         opening-price capture. The market's UMA reward is forced to zero because
 *         price markets are Pyth-only by design and do not escrow a UMA reward at
 *         creation. If Pyth resolution never fires (feed deprecation, prolonged
 *         outage), the market can be invalidated via {markPriceMarketInvalid} after
 *         a grace period and holders are refunded pro-rata via a 50/50 CTF payout.
 *
 *         Three creation shapes share a single function:
 *         - `strikePrice > 0`                    — explicit-strike market. `openTime`
 *                                                  is ignored and stored as `block.timestamp`.
 *                                                  Resolution compares the final price
 *                                                  against the stored strike.
 *         - `strikePrice == 0 && openTime == 0`  — immediate Up/Down market. Open
 *                                                  price is captured at resolution from
 *                                                  the earliest VAA in
 *                                                  `[creationTime, creationTime + window]`.
 *         - `strikePrice == 0 && openTime > 0`   — scheduled Up/Down market. Open
 *                                                  price is captured at resolution from
 *                                                  the earliest VAA in
 *                                                  `[openTime, openTime + window]`.
 *
 *         Resolution fetches the closing price from Pyth within a window around
 *         closeTime and, for deferred markets, also captures the open price from the
 *         open window. The resolver submits both windows' VAAs in a single
 *         `pythUpdateData` array — out-of-range entries are skipped per window.
 *         If finalPrice >= strikePrice → outcomes[0] wins, else outcomes[1] wins.
 *         Uses the same LibResolutionService.resolveMarket() as UMA resolution,
 *         ensuring double-resolution is prevented by the market status guard.
 */
contract PythResolutionFacet is ReentrancyGuard {
    // ---- Events ----

    event PythContractUpdated(address indexed pythContract);

    event PriceMarketCreatedPyth(
        uint256 indexed marketId,
        uint256 indexed venueId,
        bytes32 indexed pythFeedId,
        int64 strikePrice,
        int32 priceExpo,
        uint256 openTime,
        uint256 closeTime,
        uint256 resolutionWindow
    );

    event PriceMarketResolvedPyth(
        uint256 indexed marketId,
        int64 finalPrice,
        int64 strikePrice,
        uint256 openPriceTime,
        string outcome
    );

    event PriceMarketInvalidated(uint256 indexed marketId, address indexed caller);

    // ---- Errors ----

    error GracePeriodNotElapsed();
    error AssertionInProgress();

    // ---- Constants ----

    /// @notice Time after closeTime that must elapse before a price market can be invalidated.
    ///         Gives Pyth resolution a wide window to fire before holders may force a 50/50 refund.
    uint256 internal constant INVALIDATION_GRACE = 7 days;

    // ---- Admin ----

    /// @notice Set the Pyth oracle contract address. Diamond owner only.
    function setPythContract(address pythContract) external {
        LibDiamond.enforceIsContractOwner();
        if (pythContract == address(0)) revert LibPriceMarketValidator.ZeroAddress();
        LibPriceMarketStorage.getStorage().pythContract = pythContract;
        emit PythContractUpdated(pythContract);
    }

    /// @notice Get the configured Pyth oracle contract address.
    function getPythContract() external view returns (address) {
        return LibPriceMarketStorage.getPythContract();
    }

    // ---- Creation ----

    /// @notice Create a price market resolved by Pyth.
    /// @param venueId Venue this market belongs to.
    /// @param pythFeedId Pyth price feed ID (e.g., ETH/USD).
    /// @param strikePrice Target price for resolution. 0 = capture open price at resolution
    ///                    from Hermes VAAs in the open window (Up/Down). > 0 = explicit
    ///                    strike (Above/Below).
    /// @param openTime When the market opens. 0 = immediate (set to block.timestamp).
    ///                 > 0 = scheduled, must be strictly in the future. For explicit-strike
    ///                 markets this is ignored and stored as block.timestamp.
    /// @param closeTime Absolute close timestamp. Must be strictly after the
    ///                  effective open time. No protocol-imposed min/max duration.
    /// @param outcomes Market outcome labels (must be length 2, e.g. ["Up", "Down"]).
    /// @param tickSize Orderbook tick size.
    /// @param collateralToken ERC20 collateral for trading.
    /// @param ancillaryData Title + resolution description.
    /// @param liveness UMA liveness stored on the oracle (unused under normal operation;
    ///                 price markets resolve via Pyth and do not escrow a UMA reward).
    /// @param tags Optional market tags.
    /// @param resolutionWindow Seconds tolerance for Pyth timestamp (0 = default 60s).
    /// @return marketId The allocated market ID.
    function createPriceMarketPyth(
        uint256 venueId,
        bytes32 pythFeedId,
        int64 strikePrice,
        uint256 openTime,
        uint256 closeTime,
        string[] calldata outcomes,
        uint256 tickSize,
        address collateralToken,
        bytes calldata ancillaryData,
        uint64 liveness,
        bytes32[] calldata tags,
        uint256 resolutionWindow
    ) external nonReentrant returns (uint256 marketId) {
        // 1. Validate price market params
        LibPriceMarketValidator.requirePythConfigured();
        if (strikePrice < 0) revert LibPriceMarketValidator.ZeroStrikePrice();
        LibPriceMarketValidator.requireValidOpenTime(openTime);
        uint256 effectiveOpenTime = openTime == 0 ? block.timestamp : openTime;
        // Strike markets ignore openTime — resolution only ever reads strikePrice and
        // the close window. Pin effectiveOpenTime to block.timestamp so the stored
        // value matches the documented semantics for that branch.
        if (strikePrice > 0) {
            effectiveOpenTime = block.timestamp;
        }
        LibPriceMarketValidator.requireValidCloseTime(effectiveOpenTime, closeTime);
        LibPriceMarketValidator.requireValidResolutionWindow(resolutionWindow);

        // 2. Standard market creation guards (same as MarketsFacet.createMarket)
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);

        // 3. Collect market creation fee
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);

        // 4-6. Read the feed exponent, create the standard market (no UMA reward escrowed), and
        //      store the Pyth price overlay — shared with the DPM price-market path so the
        //      reward-zeroing footgun lives in exactly one place.
        marketId = LibPriceMarketService.createPriceMarketBase(
            msg.sender,
            venueId,
            ancillaryData,
            outcomes,
            tickSize,
            collateralToken,
            liveness,
            tags,
            pythFeedId,
            strikePrice,
            effectiveOpenTime,
            closeTime,
            resolutionWindow
        );

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        emit PriceMarketCreatedPyth(
            marketId, venueId, pythFeedId, strikePrice, pm.priceExpo, effectiveOpenTime, closeTime, pm.resolutionWindow
        );
    }

    // ---- Resolution ----

    /// @notice Resolve a price market using Pyth price data. Anyone can call.
    ///         For deferred Up/Down markets (`strikePrice == 0`), the resolver submits
    ///         VAAs for both the open window `[openTime, openTime + window]` and the
    ///         close window `[closeTime, closeTime + window]` in a single
    ///         `pythUpdateData` array. The facet selects the FIRST in-range VAA per
    ///         window via Pyth's `parsePriceFeedUpdatesUnique`, which rejects any VAA
    ///         whose encoded `prevPublishTime` falls inside the window — so the chosen
    ///         price is deterministic regardless of which VAAs the caller submits or
    ///         omits. For explicit-strike markets, only close-window VAAs are needed.
    ///         If Pyth resolution becomes permanently impossible (feed deprecation,
    ///         prolonged outage), holders can fall back to {markPriceMarketInvalid}
    ///         after a grace period.
    /// @param marketId The OddMaki market ID.
    /// @param pythUpdateData Signed Pyth price updates from Hermes covering the
    ///                       open and/or close windows as appropriate.
    function resolvePriceMarketPyth(uint256 marketId, bytes[] calldata pythUpdateData) external payable nonReentrant {
        // 1. Validate
        LibPriceMarketValidator.requireIsPriceMarket(marketId);
        LibPriceMarketValidator.requireFeedProvider(marketId, FeedProvider.PYTH);
        LibPriceMarketValidator.requireNotResolved(marketId);
        LibPriceMarketValidator.requireCloseTimeReached(marketId);

        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (reg.status != MarketStatus.Active) revert LibPriceMarketValidator.MarketNotActive();

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);

        // Defense-in-depth: cap the effective window at MAX_RESOLUTION_WINDOW even if
        // the market stored a larger value (legacy markets created before the bound
        // was enforced). Creator cannot widen the window at resolution time.
        uint256 maxWindow = LibPriceMarketStorage.MAX_RESOLUTION_WINDOW;
        uint256 effectiveWindow = pm.resolutionWindow > maxWindow ? maxWindow : pm.resolutionWindow;

        uint256 totalFee;

        // 2. Deferred markets: capture the open price now. If no in-range open VAA
        //    is available, resolution reverts with `NoOpenPriceInWindow` and the
        //    market eventually routes through `markPriceMarketInvalid` after the
        //    standard grace period past closeTime.
        if (pm.strikePrice == 0) {
            (int64 openPrice, uint64 openPubTime, bool openFound, uint256 openFee) = LibPriceMarketService
                .pickFirstInWindow(pm.feedId, pythUpdateData, pm.openTime, effectiveWindow);
            if (!openFound) revert LibPriceMarketValidator.NoOpenPriceInWindow();

            pm.strikePrice = openPrice;
            pm.openPriceTime = openPubTime;
            totalFee += openFee;
        }

        // 3. Capture the close price from the same submitted array.
        (int64 finalPrice,, bool closeFound, uint256 closeFee) =
            LibPriceMarketService.pickFirstInWindow(pm.feedId, pythUpdateData, pm.closeTime, effectiveWindow);
        if (!closeFound) revert LibPriceMarketValidator.NoClosePriceInWindow();
        totalFee += closeFee;

        if (msg.value < totalFee) revert LibPriceMarketValidator.InsufficientPythFee();

        // 4. Compute outcome against strikePrice (now populated either way)
        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(reg.questionId);
        bool firstOutcomeWins = finalPrice >= pm.strikePrice;
        uint256[] memory payouts = new uint256[](2);
        payouts[firstOutcomeWins ? 0 : 1] = 1;
        string memory outcome = firstOutcomeWins ? oracle.outcomes[0] : oracle.outcomes[1];

        // 5. Resolve via shared resolution path (emits MarketResolved)
        LibResolutionService.resolveMarket(marketId, payouts, outcome);

        // 6. Mark price market overlay as resolved
        pm.finalPrice = finalPrice;
        pm.resolved = true;

        // 7. Refund excess ETH
        LibPriceMarketService.refundExcess(totalFee, msg.value, msg.sender);

        emit PriceMarketResolvedPyth(marketId, finalPrice, pm.strikePrice, pm.openPriceTime, outcome);
    }

    // ---- Invalidation ----

    /// @notice Mark a price market as Invalid and refund holders 50/50 via the CTF.
    ///         Permissionless escape hatch for price markets that never resolve via Pyth
    ///         (e.g. the feed was deprecated by the publisher, or Hermes was unable to serve
    ///         a VAA in the resolution window for a sustained period). Callable by anyone
    ///         once {INVALIDATION_GRACE} has elapsed past closeTime.
    ///
    ///         For deferred Up/Down markets, a missing open-window VAA also routes through
    ///         here: resolution would revert with `NoOpenPriceInWindow` indefinitely, and
    ///         once `closeTime + INVALIDATION_GRACE` elapses, anyone can invalidate.
    ///
    ///         Reports payouts = [1, 1] to Gnosis CTF: every YES position and every NO
    ///         position redeems for half of the underlying collateral, so traders recover
    ///         their cost basis pro-rata regardless of which side they were on.
    /// @param marketId The price market to invalidate.
    function markPriceMarketInvalid(uint256 marketId) external nonReentrant {
        LibPriceMarketValidator.requireIsPriceMarket(marketId);
        LibPriceMarketValidator.requireNotResolved(marketId);

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        if (block.timestamp < pm.closeTime + INVALIDATION_GRACE) revert GracePeriodNotElapsed();

        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (reg.status != MarketStatus.Active) revert LibPriceMarketValidator.MarketNotActive();

        // Refuse to race a live UMA assertion on legacy markets. Once an assertion is
        // outstanding the question is locked at the UMA layer; the asserter (or anyone)
        // should settle it normally — with reward forced to 0 above, that path is safe and
        // resolves the market through the standard route.
        if (LibMarketOracleStorage.getMarketOracleData(reg.questionId).activeAssertionId != bytes32(0)) {
            revert AssertionInProgress();
        }

        // 50/50 invalid payout. CTF.reportPayouts normalises [1, 1] into half-and-half
        // redeem rates so every outcome token redeems for `collateral / 2`.
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;
        LibResolutionService.resolveMarket(marketId, payouts, "INVALID");

        pm.resolved = true;

        emit PriceMarketInvalidated(marketId, msg.sender);
    }
}
