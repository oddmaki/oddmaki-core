# DPM Market Mode — Implementation Plan (v1)

> Status: **planning / on hold.** Held until the incoming MarketOrders PR (CLOB
> refactor) merges, to avoid script/test crossover. Develop on branch
> `cr/dpm-markets`.

## Goal

A parallel, **self-funded** trading mode alongside the existing CLOB. The
operator never loses (pure redistribution + an outcome-independent fee). No-tech
UX: pick a side, deposit collateral. Price moves with flow (DPM-shares;
early-and-right is rewarded). Supports **Binary**, **Market-group (N-outcome)**,
and **Price (Pyth)** markets.

Why DPM instead of an LMSR/curve market maker: an operator-funded market maker is
a *subsidy* and can lose. DPM is funded by the participants (losers fund winners),
so the house never loses and earns only a transaction fee. This is the property
that decided the design.

## Lifecycle (`openTime`, `closeTime`)

- **Lobby** (`t < openTime`): enter **and** exit — a tradeable pre-game.
- **Locked** (`openTime <= t < closeTime`): enter only (price still moves on entries).
- **Closed** (`t >= closeTime`): resolve via the existing oracle paths.
- **Resolved**: `claim()` pays pro-rata.

Exits lock at `openTime` (before the outcome is knowable), so the late-information
withdrawal attack is structurally impossible.

## Economic model

- **DPM-shares:** buy shares at the current price (rises with flow); earlier =
  cheaper = more shares per unit collateral.
- **Payout:** each winning share redeems `pool / winningShares`.
- **Fee — charged at ENTRY (transaction fee), not on the claim.** Reuses the
  existing fee snapshot (protocol / venue / creator / operator bps) and the CLOB
  fee-calc + distribution flow, applied on `enter` to the deposited collateral.
  Rationale:
  - Neutral/infra optics: a fee to use the rails, not a cut of winnings.
  - Outcome-decoupled: revenue realized at transaction time; the protocol never
    waits for or depends on resolution. Maximally "away from the bet."
  - Consistent with the CLOB, which already charges per trade, not on redemptions.
  - Symmetric: everyone who transacts pays, win or lose.
  - Preserves never-lose: the protocol only ever collects, never pays out.
  - Mechanics: `enter($X)` -> `fee = X * feeBps` routed via
    `LibFeeDistributionService`; net `X - fee` enters the pool and buys shares.
  - Optional: a tiny lobby exit fee to deter churn (not required for v1).

## Architecture — separate, almost entirely additive

New files (mirror the price-market module layout):

- `src/storage/LibDpmStorage.sol` — namespace `oddmaki.storage.dpm`
- `src/facets/DpmFacet.sol` — `createDpmMarket*`, `enter`, `exit`, `claim`, views
- `src/services/LibDpmService.sol` — `initPool` + enter/exit/claim sagas
- `src/services/LibDpmPricingService.sol` — share math (**the deep-dive item**)
- `src/aggregates/LibDpmAggregate.sol` — storage mutations
- `src/validators/LibDpmValidator.sol` — lifecycle + input guards
- `src/interfaces/Types.sol` — `+= DpmMarket`

Small refactor (agreed):

- Extract PriceMarket creation out of `PythResolutionFacet` into a **service**
  (including the one-line UMA-reward-zero), so `createDpmMarket` (price type) can
  reuse it instead of porting.

Reused unchanged:

- `LibMarketCreationService.createMarket` (base; called with a **nominal
  `tickSize`** — DPM does not tick-trade).
- `LibMarketTradingStorage`/`Aggregate` — `recordTotalVolume`,
  `recordLastTradeTick`, `setActive`/`setPaused`, `active`/`paused` gating,
  `collateralToken`.
- Registry + fee snapshot (`setFeeSnapshot`); venue/access (`LibVenueStorage`,
  `LibAccessControlValidator`, `LibMarketTradingValidator`).
- UMA + Pyth + group resolution paths (DPM only **reads** the outcome).
- `LibFeeDistributionService` (fee routing, now at entry).

Single additive touch to existing code:

- **Cross-mode guard** — `require(!isDpmMarket)` in CLOB trading entry points;
  `require(isDpmMarket)` in `DpmFacet`. Prevents two trading systems on one market.

## Creation flow (`DpmFacet.createDpmMarket*`, separate entry)

Decision: a **separate** `createDpmMarket*` entry in `DpmFacet` (not a flag on the
existing entries), because DPM's creation params differ (openTime / closeTime /
outcomeCount; no real tickSize), it leaves existing APIs + the 423-test CLOB
untouched, and it keeps DPM modular. The reuse happens at the **service** layer.

1. Call `LibMarketCreationService.createMarket(...)` (base: registry + oracle/
   condition + trading + fee snapshot), with a nominal `tickSize`.
2. **Price type only:** call the newly-extracted price-creation service (feed,
   window, zero UMA reward).
3. Call `LibDpmService.initPool(marketId, openTime, closeTime, outcomeCount)` —
   writes the DPM overlay storage and sets `isDpmMarket` (`outcomeCount != 0`).

Base vault/order-book state exists but is unused for trading (harmless).

## Storage (`DpmMarket`, slimmed)

```solidity
struct DpmMarket {
  uint8     outcomeCount;
  uint64    openTime;
  uint64    closeTime;
  uint256   pool;
  uint256[] outcomeShares;      // shares outstanding per outcome
  uint256[] outcomeCollateral;  // collateral in per outcome (pricing)
}
// mapping(marketId => mapping(user => uint256[])) shareBalance
// mapping(marketId => mapping(user => bool))      claimed
```

No `resolved` / `winningOutcome` / `collateralToken` / `rakeBps` — all read from
existing storage. `isDpmMarket` is **write-once at creation, read-many**.

## Facet surface

- `createDpmMarket*(...)` per type
- `enter(marketId, outcome, amount)` — lifecycle + access + pause gates; charge
  entry fee; pricing; aggregate; `recordTotalVolume` + `recordLastTradeTick`;
  `nonReentrant`
- `exit(marketId, outcome, shares)` — **lobby-only**; pricing buy-back; aggregate
- `claim(marketId)` — reads the resolved outcome from existing storage (CTF
  payouts / `PriceMarket`); pays `shares * pool / winningShares`
- views: `getDpmMarket`, `getShares`, `getPrice`, `quoteEnter/Exit`, `getPayout`,
  `isDpmMarket`

## Resolution — no DPM resolve function

The existing UMA / Pyth / group resolution marks resolved and writes the outcome
(unchanged). `claim()` reads the winner from existing shared storage per type.
No `resolveDpmMarket`, no finalize step, no resolution-facet hooks — because the
fee is taken at entry and the winner is read lazily at claim, nothing
DPM-specific needs to be written at resolution.

## Market types

- **Binary:** 2-outcome pool, UMA.
- **Group:** single **N-outcome pool**, UMA (reads the winning member from the
  existing group resolution; resolution unchanged). Collapses the CLOB neg-risk
  machinery into one N-way pool.
- **Price:** 2-outcome pool, Pyth (reuses the extracted price-creation service;
  `openTime`/`closeTime` double as the Pyth observation window).

## Open items (the only real unknowns)

1. **`LibDpmPricingService` math** — exact DPM-shares cost/price function +
   **lobby buy-back solvency proof** (path-dependence, fixed-point rounding).
   Validate against Pennock's DPM and the 9Lives implementation. This is the one
   substantive deep-dive; everything else is stable around it.
2. **Price-creation extraction boundary** — confirm how much to wrap out of
   `PythResolutionFacet` into a service.
3. **Nominal `tickSize`** value, and whether DPM share prices are tick-quantized
   for display.
4. **Group N-outcome pool <-> existing group resolution** mapping (read winning
   member).

## Build order (when unblocked)

1. `Types` + `LibDpmStorage` + `LibDpmValidator`.
2. `LibDpmPricingService` (provisional math + tests; swap finalized math in later).
3. `LibDpmAggregate` + `LibDpmService` (`initPool`, enter/exit/claim).
4. `DpmFacet` + diamond cut + `createDpmMarket` (binary first) + cross-mode guard.
5. Price-creation service extraction + price-DPM path.
6. Group (N-outcome) path.
7. Fee routing at entry + venue config + views.
8. Full `forge build` + `forge test` (synchronously) before any PR.

## Sequencing / hold

Hold until the incoming MarketOrders PR (CLOB refactor) merges. Then rebase
`cr/dpm-markets` and start with the **binary, no-exit vertical slice**
(`createDpmMarket -> enter -> claim`) behind the cross-mode guard.

## Regulatory note

The protocol stays neutral: it is not a counterparty, takes an
**outcome-independent transaction fee at entry**, and never pays out. Parimutuel
pools are nonetheless a regulated (gambling-flavored) activity in many
jurisdictions; the venue/creator operates the market and owns that posture, with
the protocol as neutral permissionless infrastructure. Get jurisdiction-specific
counsel before launch.
