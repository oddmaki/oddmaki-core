// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPriceMarketStorage} from "../storage/LibPriceMarketStorage.sol";
import {LibPriceMarketValidator} from "../validators/LibPriceMarketValidator.sol";
import {LibPriceMarketService} from "../services/LibPriceMarketService.sol";
import {LibVenueValidator} from "../validators/LibVenueValidator.sol";
import {LibAccessControlValidator} from "../validators/LibAccessControlValidator.sol";
import {LibProtocolValidator} from "../validators/LibProtocolValidator.sol";
import {LibMarketCreationFeeService} from "../services/LibMarketCreationFeeService.sol";
import {LibMarketCreationService} from "../services/LibMarketCreationService.sol";
import {LibResolutionService} from "../services/LibResolutionService.sol";
import {LibMarketRegistryStorage} from "../storage/LibMarketRegistryStorage.sol";
import {LibMarketOracleStorage} from "../storage/LibMarketOracleStorage.sol";
import {MarketRegistryData, MarketOracleData, MarketStatus, PriceMarket, FeedProvider} from "../interfaces/Types.sol";

/**
 * @title PythResolutionFacet
 * @author OddMaki Protocol
 * @notice Pyth-specific admin, creation, and resolution for price markets.
 *
 *         Creation: captures an opening price from Pyth and creates a standard
 *         OddMaki market with caller-provided outcomes. UMA is configured as
 *         fallback — if Pyth resolution never happens, anyone can assert via UMA.
 *
 *         strikePrice is the unified reference price for resolution:
 *         - When caller passes strikePrice == 0: contract captures the current
 *           Pyth price and stores it as strikePrice (standard Up/Down market).
 *         - When caller passes strikePrice > 0: explicit target price is stored.
 *
 *         Resolution: fetches closing price from Pyth within a time window around
 *         closeTime. If finalPrice >= strikePrice → outcomes[0] wins, else
 *         outcomes[1] wins. Uses the same LibResolutionService.resolveMarket() as UMA
 *         resolution, ensuring double-resolution is prevented by the market status guard.
 */
contract PythResolutionFacet is ReentrancyGuard {
    // ---- Events ----

    event PythContractUpdated(address indexed pythContract);

    event OpenMaxStalenessUpdated(uint256 openMaxStaleness);

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

    event PriceMarketResolvedPyth(uint256 indexed marketId, int64 finalPrice, int64 strikePrice, string outcome);

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

    /// @notice Set the opening-price staleness window (seconds). Diamond owner only.
    ///         Pass 0 to fall back to the built-in default. Deliberately not venue-configurable —
    ///         a loose value would reintroduce the stale-VAA attack surface at market creation.
    function setOpenMaxStaleness(uint256 openMaxStaleness) external {
        LibDiamond.enforceIsContractOwner();
        LibPriceMarketStorage.getStorage().openMaxStaleness = openMaxStaleness;
        emit OpenMaxStalenessUpdated(openMaxStaleness);
    }

    /// @notice Get the effective opening-price staleness window in seconds.
    function getOpenMaxStaleness() external view returns (uint256) {
        return LibPriceMarketStorage.getOpenMaxStaleness();
    }

    // ---- Creation ----

    /// @notice Create a price market with Pyth as the opening-price oracle.
    ///         When strikePrice == 0, the current Pyth price is used as the
    ///         reference price (standard Up/Down). When strikePrice > 0, the
    ///         explicit target price is stored (strike market).
    /// @param venueId Venue this market belongs to.
    /// @param pythFeedId Pyth price feed ID (e.g., ETH/USD).
    /// @param strikePrice Target price for resolution (0 = use current Pyth price).
    /// @param closeTime Absolute close timestamp (must be 300..86400s from now).
    /// @param outcomes Market outcome labels (must be length 2, e.g. ["Up", "Down"]).
    /// @param tickSize Orderbook tick size.
    /// @param collateralToken ERC20 collateral for trading.
    /// @param ancillaryData Title + resolution description.
    /// @param liveness UMA liveness for fallback resolution (0 = venue default).
    /// @param tags Optional market tags.
    /// @param resolutionWindow Seconds tolerance for Pyth timestamp (0 = default 60s).
    /// @param pythUpdateData Signed Pyth price update from Hermes (required for Up/Down, ignored for strike markets).
    /// @return marketId The allocated market ID.
    function createPriceMarketPyth(
        uint256 venueId,
        bytes32 pythFeedId,
        int64 strikePrice,
        uint256 closeTime,
        string[] calldata outcomes,
        uint256 tickSize,
        address collateralToken,
        bytes calldata ancillaryData,
        uint64 liveness,
        bytes32[] calldata tags,
        uint256 resolutionWindow,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint256 marketId) {
        // 1. Validate price market params
        LibPriceMarketValidator.requirePythConfigured();
        LibPriceMarketValidator.requireValidCloseTime(closeTime);
        LibPriceMarketValidator.requireValidResolutionWindow(resolutionWindow);
        if (strikePrice < 0) revert LibPriceMarketValidator.ZeroStrikePrice();

        // 2. Standard market creation guards (same as MarketsFacet.createMarket)
        LibVenueValidator.requireActiveVenue(venueId);
        LibAccessControlValidator.validateCreationAccess(msg.sender, venueId);
        LibProtocolValidator.requireWhitelistedCollateral(collateralToken);

        // 3. Collect market creation fee
        LibMarketCreationFeeService.collectCreationFee(venueId, msg.sender, collateralToken);

        // 4. Get price data based on market type
        int64 effectiveStrike;
        int32 priceExpo;
        uint256 pythFee;
        uint256 openPriceTime;

        if (strikePrice > 0) {
            // Strike market: explicit target price, only need priceExpo from feed (no update, no fee)
            priceExpo = LibPriceMarketService.getFeedExponent(pythFeedId);
            effectiveStrike = strikePrice;
            pythFee = 0;
        } else {
            // Up/Down market: capture the opening price from the submitted VAA.
            int64 openPrice;
            (openPrice, priceExpo, pythFee, openPriceTime) =
                LibPriceMarketService.captureOpenPrice(pythFeedId, pythUpdateData, msg.value);
            effectiveStrike = openPrice;
        }

        // 5. Create standard market via shared service
        marketId = LibMarketCreationService.createMarket(
            msg.sender,
            venueId,
            ancillaryData,
            outcomes,
            tickSize,
            collateralToken,
            0, // additionalReward: 0 for price markets
            liveness,
            0, // groupId: standalone
            MarketStatus.Active,
            tags
        );

        // 6. Store price market overlay
        uint256 effectiveWindow =
            resolutionWindow > 0 ? resolutionWindow : LibPriceMarketStorage.DEFAULT_RESOLUTION_WINDOW;

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);
        pm.feedId = pythFeedId;
        pm.feedProvider = FeedProvider.PYTH;
        pm.openTime = block.timestamp;
        pm.closeTime = closeTime;
        pm.priceExpo = priceExpo;
        pm.resolutionWindow = effectiveWindow;
        pm.strikePrice = effectiveStrike;
        pm.openPriceTime = openPriceTime;

        // 7. Refund excess ETH (for Up/Down markets: refund beyond Pyth fee; for strike: refund all)
        LibPriceMarketService.refundExcess(pythFee, msg.value, msg.sender);

        emit PriceMarketCreatedPyth(
            marketId, venueId, pythFeedId, effectiveStrike, priceExpo, block.timestamp, closeTime, effectiveWindow
        );
    }

    // ---- Resolution ----

    /// @notice Resolve a price market using Pyth price data. Anyone can call.
    ///         If this is never called, the market falls back to UMA —
    ///         anyone can submit a UMA assertion through the existing flow.
    ///         finalPrice is compared against strikePrice (which holds the
    ///         captured open price for standard Up/Down markets).
    /// @param marketId The OddMaki market ID.
    /// @param pythUpdateData Signed Pyth price update from Hermes at closeTime.
    function resolvePriceMarketPyth(uint256 marketId, bytes[] calldata pythUpdateData) external payable nonReentrant {
        // 1. Validate
        LibPriceMarketValidator.requireIsPriceMarket(marketId);
        LibPriceMarketValidator.requireFeedProvider(marketId, FeedProvider.PYTH);
        LibPriceMarketValidator.requireNotResolved(marketId);
        LibPriceMarketValidator.requireCloseTimeReached(marketId);

        MarketRegistryData storage reg = LibMarketRegistryStorage.getMarketRegistryData(marketId);
        if (reg.status != MarketStatus.Active) revert LibPriceMarketValidator.MarketNotActive();

        PriceMarket storage pm = LibPriceMarketStorage.getPriceMarket(marketId);

        // 2. Get closing price from Pyth within the resolution window
        address pythContract = LibPriceMarketStorage.getPythContract();
        IPyth pyth = IPyth(pythContract);
        uint256 pythFee = pyth.getUpdateFee(pythUpdateData);
        if (msg.value < pythFee) revert LibPriceMarketValidator.InsufficientPythFee();

        // Defense-in-depth: cap the effective window at MAX_RESOLUTION_WINDOW even if
        // the market stored a larger value (e.g. a legacy market created before the
        // creation-time bound was enforced). Creator cannot widen the window here.
        uint256 maxWindow = LibPriceMarketStorage.MAX_RESOLUTION_WINDOW;
        uint256 effectiveWindow = pm.resolutionWindow > maxWindow ? maxWindow : pm.resolutionWindow;

        // Prefer the earliest in-range VAA rather than the caller's cherry-pick:
        // parse each submitted update individually and keep the one with the
        // smallest publishTime. The resolver still chooses which VAAs to submit,
        // but cannot reorder the array to bias which price is selected.
        int64 finalPrice = _pickEarliestPythPrice(pyth, pm.feedId, pythUpdateData, pm.closeTime, effectiveWindow);

        // 3. Compute outcome against strikePrice
        MarketOracleData storage oracle = LibMarketOracleStorage.getMarketOracleData(reg.questionId);
        bool firstOutcomeWins = finalPrice >= pm.strikePrice;
        uint256[] memory payouts = new uint256[](2);
        payouts[firstOutcomeWins ? 0 : 1] = 1;
        string memory outcome = firstOutcomeWins ? oracle.outcomes[0] : oracle.outcomes[1];

        // 4. Resolve via shared resolution path (emits MarketResolved)
        LibResolutionService.resolveMarket(marketId, payouts, outcome);

        // 5. Mark price market overlay as resolved
        pm.finalPrice = finalPrice;
        pm.resolved = true;

        // 6. Refund excess ETH
        LibPriceMarketService.refundExcess(pythFee, msg.value, msg.sender);

        emit PriceMarketResolvedPyth(marketId, finalPrice, pm.strikePrice, outcome);
    }

    /// @dev Parse each submitted VAA individually and return the price whose
    ///      publishTime is the smallest value in `[closeTime, closeTime + window]`.
    ///      Reverts if no submitted VAA falls in range (propagated from Pyth).
    function _pickEarliestPythPrice(
        IPyth pyth,
        bytes32 feedId,
        bytes[] calldata pythUpdateData,
        uint256 closeTime,
        uint256 window
    ) internal returns (int64 finalPrice) {
        if (pythUpdateData.length == 0) revert LibPriceMarketValidator.NoValidPriceUpdate();

        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = feedId;
        uint64 minPT = uint64(closeTime);
        uint64 maxPT = uint64(closeTime + window);

        uint64 earliestPublishTime = type(uint64).max;
        bytes[] memory single = new bytes[](1);

        for (uint256 i = 0; i < pythUpdateData.length; i++) {
            single[0] = pythUpdateData[i];
            uint256 singleFee = pyth.getUpdateFee(single);
            PythStructs.PriceFeed[] memory feeds =
                pyth.parsePriceFeedUpdates{value: singleFee}(single, feedIds, minPT, maxPT);
            uint64 pt = uint64(feeds[0].price.publishTime);
            if (pt < earliestPublishTime) {
                earliestPublishTime = pt;
                finalPrice = feeds[0].price.price;
            }
        }
    }
}
