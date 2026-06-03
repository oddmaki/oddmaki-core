# DPM Market Mode — Implementation Plan (v1)

> Status: **planning / ready to start.** Branch `cr/dpm-markets`, rebased on
> `main` after the MarketOrders multi-path PRs (#21, #22) landed. Pricing math
> in [`dpm-pricing-math.md`](./dpm-pricing-math.md).

## Goal

A parallel, **self-funded** trading mode alongside the existing CLOB. The
operator never loses (pure redistribution + an outcome-independent entry fee).
No-tech UX: pick a side, deposit collateral. Price moves with flow (dynamic
share pricing; early-and-right is rewarded). Supports **Binary**,
**Market-group (N-outcome)**, and **Price (Pyth)** markets.

We use **DPM I** as defined in Pennock (2004), *"A Dynamic Pari-Mutuel Market
for Hedging, Wagering, and Information Aggregation,"* §4 — the *"losing money
redistributed"* variant. Winners are refunded their initial price paid **plus**
a share of the losers' pool. **DPM II (§5) is rejected** for v1 because
Pennock himself notes it can lose money on a correctly-predicted outcome if
prices swing (§5.3). No invented hybrids; the price function and payoff are
Pennock's exact equations.

Why DPM (not an LMSR/curve market maker): an operator-funded market maker is a
subsidy and can lose. DPM is funded by the participants (losers fund winners),
so the house never loses and earns only a transaction fee.

## Lifecycle (`openTime`, `closeTime`)

- **Intent (`t < openTime`) — optional pre-game phase:** participants can
  `enterIntent` and `exitIntent` freely. **1:1 refundable stake. No pricing
  math, no shares minted.** The displayed implied probability during this
  phase is simply `intentTotals[i] / Σ intentTotals` — classic parimutuel.
  Exits are safe because they close at `openTime`, before the outcome is
  knowable.
- **Open (`openTime ≤ t < closeTime`):** intent pool snapshots into the DPM
  pool at par ($1/share allocation — see "Transition" below). New entries use
  the dynamic DPM I pricing. **No exits at all from this point on**, matching
  Pennock §3.1: *"there is no corresponding market maker to accept sell orders."*
- **Closed (`t ≥ closeTime`):** resolve via the existing oracle paths
  (unchanged).
- **Resolved:** `claim()` pays each holder per the DPM I rule.

The intent pool is **optional flavor**, not a structural requirement. A market
can be created with `openTime == createdAt`, skipping the intent phase
entirely.

## Pricing — DPM I (Pennock §4)

Notation: `M_i` = collateral wagered on outcome `i`; `N_i` = shares
outstanding on outcome `i`. Per-user we track `userShares[u][i]` and
`userPaid[u][i]` (cumulative collateral spent on outcome `i`, needed for the
DPM I refund).

- **Price function** (Pennock eq. 7): `p_i(n) = (M_i / N_other) · e^(n / N_other)`
- **Cost integral** (Pennock eq. 6, integrated): `m(n) = M_i · (e^(n / N_other) − 1)`
- **Inverse (shares for `m` dollars):** `n(m) = N_other · ln(1 + m / M_i)`
- **Payoff per share if outcome `i` wins:** `userPaid[u][i] + (M_other / N_i) · userShares[u][i]`
  Each winning share earns its **initial price refund + a pro-rata slice of
  the losers' pool**. Aggregate payout = `M_i + M_other = total pool` → fully
  self-funded.

### Boundary: par-until-contested

Pennock notes (§4.2.1 closing paragraph) that the dynamic price function is
undefined when a side has `N = 0` and proposes a "seed wager" to bootstrap. We
prefer not to seed (it requires operator capital and breaks the self-funded
property), so:

- **If `N_other == 0`:** the side prices at **par — $1/share**, deposit `X`
  yields `X` shares, sets `M_i := X`, `N_i := X`. Trivially well-defined.
- **Once both sides have non-zero `N`:** dynamic Pennock pricing engages.

This is **our** boundary decision, not a verbatim Pennock prescription, but it
is just specifying the classic-parimutuel base case of the "hybrid of
parimutuel and CDA" Pennock describes. Safety is unconditional from the
self-funding identity below.

### Self-funding identity

At all times, `pool = Σ M_i = total collateral deposited`. DPM I payout if
outcome `i` wins:

```
Σ_u (userPaid[u][i] + (M_other / N_i) · userShares[u][i])
  = M_i + (M_other / N_i) · N_i
  = M_i + M_other
  = pool
```

The operator never adds a cent and never touches the pool. Insolvency is not
possible regardless of how dynamic and par entries interleave.

### Resolution edge case: no-contest

If the winning outcome has `N = 0` (nobody backed it), refund every
participant their deposits. Market void. Same as classic parimutuel and
totalizator practice. Refunds ≤ deposits, so self-funded still.

## Intent → DPM transition (at `openTime`)

Lazy, no transaction required. At the first post-`openTime` interaction, the
DPM state is derived as:

- `M_i := intentTotals[i]`, `N_i := intentTotals[i]` (par allocation —
  every intent participant effectively bought at $1/share)
- For each user: `userShares[u][i] := intentStake[u][i]`,
  `userPaid[u][i] := intentStake[u][i]`

Storage-wise this can be implemented lazily per user (on their first
post-`openTime` action — `enter` or `claim`) or eagerly per market (at any
first post-`openTime` action). Lazy is cheaper and equivalent — pick lazy.

**Consequence:** intent participants effectively form a classic-parimutuel
crowd (no early-bird *within* the intent phase — fair to everyone who
deposited before `openTime`). Post-`openTime` entrants face the dynamic
Pennock prices, and *they* compete on early-bird reward against each other.

## Fee — at entry (transaction fee)

Reuses the existing fee snapshot (protocol / venue / creator / operator bps)
and the CLOB fee-calc + distribution flow, applied on `enter` and
`enterIntent` to the deposited collateral:

- `enter($X)` → `fee = X · feeBps` routed via `LibFeeDistributionService`;
  net `X − fee` enters the pool and buys shares.

Properties: neutral/infra optics (a fee to use the rails, not a cut of
winnings); outcome-decoupled (revenue realized at transaction time); preserves
never-lose; consistent with the CLOB which already charges per trade, not on
redemptions.

Note: fees on `enterIntent` need to be **refunded** on `exitIntent` (since
exit is 1:1 and refundable, the fee can't be skimmed yet) — OR fees are only
charged on the *net* portion that survives into `openTime`. Decision: charge
the fee **only at the intent→DPM transition** for intent-funded shares, and
charge normally on post-`openTime` `enter`. Keeps the 1:1 refund property of
intent without losing fee revenue.

## Architecture — separate, almost entirely additive

New files (mirror the price-market module layout):

- `src/storage/LibDpmStorage.sol` — namespace `oddmaki.storage.dpm`
- `src/facets/DpmFacet.sol` — `createDpmMarket*`, `enterIntent`, `exitIntent`,
  `enter`, `claim`, views
- `src/services/LibDpmService.sol` — `initPool` + intent + enter + claim sagas
- `src/services/LibDpmPricingService.sol` — Pennock eq. 6/7 with fixed-point
  `exp`/`ln`
- `src/aggregates/LibDpmAggregate.sol` — storage mutations
- `src/validators/LibDpmValidator.sol` — lifecycle + input guards
- `src/interfaces/Types.sol` — `+= DpmMarket`

Small refactor (agreed):

- Extract PriceMarket creation out of `PythResolutionFacet` into a **service**
  (including the one-line UMA-reward-zero), so `createDpmMarket` (price type)
  can reuse it instead of porting.

Reused unchanged:

- `LibMarketCreationService.createMarket` (base; nominal `tickSize`).
- `LibMarketTradingStorage`/`Aggregate` — `recordTotalVolume`,
  `recordLastTradeTick`, `setActive`/`setPaused`, `active`/`paused` gating,
  `collateralToken`.
- Registry + fee snapshot (`setFeeSnapshot`); venue/access (`LibVenueStorage`,
  `LibAccessControlValidator`, `LibMarketTradingValidator`).
- UMA + Pyth + group resolution paths (DPM only **reads** the outcome).
- `LibFeeDistributionService` (fee routing).

Single additive touch to existing code:

- **Cross-mode guard** — `require(!isDpmMarket)` in CLOB trading entry points
  (`MarketOrdersFacet`, `LimitOrdersFacet`, etc.); `require(isDpmMarket)` in
  `DpmFacet`. Prevents two trading systems on one market.

## Creation flow (`DpmFacet.createDpmMarket*`, separate entry)

A separate `createDpmMarket*` entry in `DpmFacet` (not a flag on the existing
entries), because DPM's creation params differ (`openTime`/`closeTime`/
`outcomeCount`; no real `tickSize`) and we don't touch existing APIs.

1. Call `LibMarketCreationService.createMarket(...)` (base: registry + oracle/
   condition + trading + fee snapshot), with a nominal `tickSize`.
2. **Price type only:** call the newly-extracted price-creation service (feed,
   window, zero UMA reward).
3. Call `LibDpmService.initPool(marketId, openTime, closeTime, outcomeCount)`
   — writes the DPM overlay storage and sets `isDpmMarket`
   (`outcomeCount != 0`).

Base vault/order-book state exists but is unused for trading (harmless).

## Storage (`DpmMarket`)

```solidity
struct DpmMarket {
  uint8     outcomeCount;
  uint64    openTime;
  uint64    closeTime;
  uint256[] M;                  // outcomeCollateral: total collateral wagered per outcome
  uint256[] N;                  // outcomeShares: total shares outstanding per outcome
  uint256[] intentTotals;       // pre-openTime intent totals per outcome
}
// mapping(marketId => mapping(user => uint256[])) intentStake;   // refundable, pre-openTime
// mapping(marketId => mapping(user => uint256[])) userShares;    // shares held per outcome
// mapping(marketId => mapping(user => uint256[])) userPaid;      // collateral spent per outcome (DPM I refund)
// mapping(marketId => mapping(user => bool))      claimed;
// mapping(marketId => mapping(user => bool))      intentTransitioned;  // lazy intent→DPM flag
```

No `resolved` / `winningOutcome` / `collateralToken` — read from existing
storage. `isDpmMarket` derived from `outcomeCount != 0`.

## Facet surface

- `createDpmMarket*(...)` per type (binary / group / price)
- `enterIntent(marketId, outcome, amount)` — `t < openTime`; 1:1 stake, no
  pricing; lifecycle + access + pause gates; `nonReentrant`
- `exitIntent(marketId, outcome, amount)` — `t < openTime`; 1:1 refund
- `enter(marketId, outcome, amount)` — `openTime ≤ t < closeTime`; transition
  caller's intent (if any) into DPM at par + charge accumulated intent fees;
  then dynamic Pennock pricing for the new amount; `recordTotalVolume` +
  `recordLastTradeTick`; `nonReentrant`
- `claim(marketId)` — `t ≥ closeTime` and resolved; reads winner from existing
  oracle storage; transitions caller's intent if not yet (at par); pays per
  DPM I rule (refund + losers'-pool slice); handles no-contest refund
- views: `getDpmMarket`, `getShares`, `getPrice(outcome)`, `quoteEnter`,
  `getPayout(user)`, `isDpmMarket`, `getIntentStake`

**No `exit` function post-`openTime`.** Matches Pennock §3.1 exactly. A
future P2P aftermarket (CLOB-style sell-orders queue) is a separate project,
not v1.

## Resolution — no DPM resolve function

Existing UMA / Pyth / group resolution marks resolved and writes the outcome
(unchanged). `claim()` reads the winner from existing shared storage per
type. No `resolveDpmMarket`, no finalize step, no resolution-facet hooks.

## Market types

- **Binary:** 2-outcome pool, UMA.
- **Group:** single N-outcome pool, UMA (reads the winning member from the
  existing group resolution; resolution unchanged). Collapses the CLOB
  neg-risk machinery into one N-way pool.
- **Price:** 2-outcome pool, Pyth (reuses the extracted price-creation
  service; `openTime`/`closeTime` double as the Pyth observation window).

## Open items

1. **Fixed-point `exp`/`ln` lib choice** for `LibDpmPricingService` (e.g.,
   PRBMath UD60x18 / SD59x18). Must cover the Pennock eq. 7 / eq. 6 / inverse
   forms with the protocol-favorable rounding direction documented per
   call-site.
2. **Price-creation extraction boundary** — confirm what to wrap out of
   `PythResolutionFacet` into a service.
3. **Nominal `tickSize`** value for the base-market call (DPM doesn't
   tick-quantize).
4. **Group N-outcome pool ↔ existing group resolution** mapping (read winning
   member).
5. **Fee mechanics for intent:** charge at transition, *not* at
   `enterIntent`, to preserve the 1:1 refund property of `exitIntent`.

## Build order

1. `Types` + `LibDpmStorage` + `LibDpmValidator` + cross-mode guard.
2. `LibDpmPricingService` with Pennock eq. 6/7 + par boundary + unit tests
   (including round-trip and identity `M_i + M_other == pool`).
3. `LibDpmAggregate` + `LibDpmService` (`initPool`, `enterIntent`,
   `exitIntent`, intent transition, `enter`, `claim`, no-contest refund).
4. `DpmFacet` + diamond cut + `createDpmMarket` (binary first).
5. Price-creation service extraction + price-DPM path.
6. Group (N-outcome) path.
7. Fee routing at entry / transition + venue config + views.
8. Full `forge build` + `forge test` (synchronously) before any PR.

## Regulatory note

The protocol stays neutral: it is not a counterparty, takes an
outcome-independent transaction fee at entry, and never pays out.
Parimutuel-style pools are nonetheless a regulated (gambling-flavored)
activity in many jurisdictions; the venue/creator operates the market and
owns that posture, with the protocol as neutral permissionless infrastructure.
Get jurisdiction-specific counsel before launch.
