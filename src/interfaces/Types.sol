// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title Types
 * @notice Shared type definitions for the OddMaki Protocol.
 */

enum Side {
    BUY,
    SELL
}

struct Order {
    uint256 id;
    address owner;
    uint256 qty;
    uint256 originalQty;
    uint256 tick;
    Side side;
    uint256 outcomeId;
    uint256 marketId;
    uint256 expiry;
    uint256 salt;
    uint256 nextOrderId;
    uint256 prevOrderId;
}

// -----------------------------------------------------------------------------
// Order book (tick levels, top of book, active tick list)
// -----------------------------------------------------------------------------

struct TickLevel {
    uint256 headOrderId;
    uint256 tailOrderId;
    uint256 depth;
    uint256 totalQty;
}

struct TickList {
    uint256 head; // Best tick (highest for BUY, lowest for SELL)
    uint256 tail;
}

struct TickNode {
    uint256 nextTick;
    uint256 prevTick;
    bool active;
}

// -----------------------------------------------------------------------------
// Market: three-layer storage (Registry, Trading, Oracle)
// -----------------------------------------------------------------------------

enum MarketStatus {
    Draft,
    Active,
    Resolved
}

/// @notice Lifecycle / identity: venue, creator, status, link to oracle. Keyed by marketId.
struct MarketRegistryData {
    uint256 marketId;
    uint256 venueId;
    address creator;
    MarketStatus status;
    uint256 groupId;
    bytes32 questionId;
    address oracle;
    uint256 tickSize;
    uint256 venueFeeBps;    // Snapshotted at market creation (H-2 fix)
    uint256 creatorFeeBps;  // Snapshotted at market creation (H-2 fix)
}

/// @notice Oracle / CTF: condition, outcomes, UMA economics. Keyed by questionId.
struct MarketOracleData {
    bytes32 questionId;
    bytes32 conditionId;
    uint256 outcomeSlotCount;
    IERC20 currency;
    uint256 reward;
    uint256 requiredBond;
    uint64 liveness;
    bool initialized;
    bytes32 activeAssertionId;
    bytes ancillaryData;
    string[] outcomes;
}

/// @notice Exchange: positionIds, volume, lastTradeTick, active + immutable tickSize/collateral. Keyed by marketId.
struct MarketTradingData {
    uint256 marketId;
    uint256 tickSize;
    IERC20 collateralToken;
    uint256[2] positionIds;
    uint256[2] totalVolume;
    uint256[2] lastTradeTick;
    bool active;
}

// -----------------------------------------------------------------------------
// Venue
// -----------------------------------------------------------------------------

/// @notice Venue configuration: multi-tenant governance, fees, oracle economics. Keyed by venueId.
struct VenueData {
    uint256 venueId;
    address operator;
    string name;
    string metadata;
    address tradingAccessControl;
    address creationAccessControl;
    address feeRecipient;
    uint256 venueFeeBps; // 1-200 bps
    uint256 creatorFeeBps; // 0-venueFeeBps
    uint256 defaultTickSize;
    uint256 marketCreationFee; // min 5e6
    uint256 umaRewardAmount;
    uint256 umaMinBond;
    bool active;
}

// -----------------------------------------------------------------------------
// Fills (trade execution records)
// -----------------------------------------------------------------------------

enum SettlementPath {
    NORMAL, // Same outcome, opposite sides (BUY crosses SELL)
    MINT,   // Different outcomes, both buys (split collateral to mint)
    MERGE   // Different outcomes, both sells (merge tokens to collateral)
}

struct Fill {
    uint256 id;
    uint256 marketId;
    SettlementPath path;
    uint256 order1Id;  // NORMAL: buyOrderId;  MINT/MERGE: yesOrderId
    uint256 order2Id;  // NORMAL: sellOrderId;  MINT/MERGE: noOrderId
    uint256 qty;
    uint256 priceTick; // NORMAL: execution tick; MINT: yesBid; MERGE: yesAsk
    address operator;  // msg.sender who called matchOrders
}

// -----------------------------------------------------------------------------
// Fees (composed on-the-fly, not stored)
// -----------------------------------------------------------------------------

struct MarketFees {
    uint256 protocolFeeBps;   // Protocol fee: 20 bps (fixed)
    uint256 venueFeeBps;      // Venue fee: 1-200 bps (from venue config)
    uint256 creatorFeeBps;    // Creator fee: 0-venueFeeBps (from venue config)
    uint256 operatorFeeBps;   // Operator fee: 10 bps (fixed)
    address protocolTreasury; // Protocol treasury address
    address venueTreasury;    // Venue feeRecipient address
    address marketCreator;    // Market creator address
}

struct FeeBreakdown {
    uint256 protocolFee;  // Protocol fee amount (floored)
    uint256 venueNetFee;  // Venue's net fee: (venueFeeBps - creatorFeeBps)
    uint256 creatorFee;   // Creator fee amount (floored)
    uint256 operatorFee;  // Operator fee amount (floored)
    uint256 totalFee;     // Sum of all fees
    uint256 remainder;    // Rounding dust -> added to protocolFee during distribution
}

// -----------------------------------------------------------------------------
// Market Groups (Multi-Outcome / NegRisk)
// -----------------------------------------------------------------------------

/// @notice Market group metadata: lifecycle, member markets, shared creation params. Keyed by groupId.
struct MarketGroupData {
    uint256 groupId;
    uint256[] marketIds;       // ALL market IDs in group (active + placeholders)
    uint256 totalMarkets;      // Locked at activation (immutable for conversion math)
    string question;           // Group-level question (e.g. "Where will Giannis be traded?")
    string description;        // Resolution criteria (reused across markets in addMarket)
    MarketStatus status;       // Draft -> Active -> Resolved
    uint256 createdAt;
    uint256 resolvedMarketId;  // Which market won (0 = not resolved)
    address creator;
    uint256 venueId;
    IERC20 collateralToken;
    uint256 tickSize;
    uint256 additionalReward;
    uint64 liveness;
    uint256 reward;            // Total UMA reward (venue base + additionalReward), collected at group creation
}

/// @notice Per-market item data for grouped markets. Keyed by marketId.
struct MarketGroupItem {
    bool isPlaceholder;
    string marketName;         // Short name for display: "Warriors", "$78k-$80k"
}

// -----------------------------------------------------------------------------
// Market Orders (immediate execution against resting liquidity)
// -----------------------------------------------------------------------------

enum MarketOrderType {
    FOK, // Fill-Or-Kill: entire order must fill or transaction reverts
    FAK  // Fill-And-Kill: fill as much as possible, return remainder
}

struct MarketBuyResult {
    uint256 tokensReceived;   // Total outcome tokens acquired
    uint256 avgPrice;         // Average price paid (1e18-scaled)
    uint256 collateralSpent;  // Actual collateral used
    uint256 unusedCollateral; // Returned to buyer (FAK only)
}

struct MarketSellResult {
    uint256 tokensSold;         // Outcome tokens actually sold
    uint256 avgPrice;           // Average execution price (1e18-scaled, gross before fees)
    uint256 collateralReceived; // Net collateral received by seller (after fees)
    uint256 unsoldTokens;       // Returned to seller (FAK only)
}

// -----------------------------------------------------------------------------
// Matching Preview (read-only matchability check)
// -----------------------------------------------------------------------------

struct MatchPreview {
    bool normalYesCross;     // bestBid(YES) >= bestAsk(YES)
    bool normalNoCross;      // bestBid(NO) >= bestAsk(NO)
    bool mintFeasible;       // YES+NO bids cover 1.0 + fees
    bool mergeFeasible;      // YES+NO asks within 1.0 - fees
    bool anyMatchable;       // OR of all above
    uint256 yesBestBid;      // top-of-book snapshot
    uint256 yesBestAsk;
    uint256 noBestBid;
    uint256 noBestAsk;
    bool yesBidHeadExpired;  // head order at YES BUY top tick is expired
    bool yesAskHeadExpired;  // head order at YES SELL top tick is expired
    bool noBidHeadExpired;   // head order at NO BUY top tick is expired
    bool noAskHeadExpired;   // head order at NO SELL top tick is expired
}

// -----------------------------------------------------------------------------
// Resolution (UMA assertion tracking)
// -----------------------------------------------------------------------------

/// @notice UMA assertion data: tracks assertionId -> questionId + outcome + settled.
struct AssertionData {
    bytes32 assertionId;
    bytes32 questionId;
    string outcome;
    bool settled;
    address asserter;
}

// -----------------------------------------------------------------------------
// Price Markets (oracle-powered Up/Down markets)
// -----------------------------------------------------------------------------

enum FeedProvider {
    PYTH,
    CHAINLINK
}

/// @notice Price market overlay: stores oracle-specific data on top of a standard market.
struct PriceMarket {
    bytes32 feedId; // Oracle price feed ID (e.g., Pyth ETH/USD feed)
    FeedProvider feedProvider; // Which oracle provided the feed
    uint256 openTime; // block.timestamp at creation
    uint256 closeTime; // Absolute close timestamp
    int32 priceExpo; // Price exponent (e.g., -8)
    int64 finalPrice; // Price at close (filled on resolution)
    uint256 resolutionWindow; // Seconds tolerance for oracle timestamp
    bool resolved;
    int64 strikePrice; // Reference price for resolution (openPrice for Up/Down, explicit for strike markets)
}

