# DPM Pricing Math — DPM I (Pennock 2004 §4)

> Companion to [`dpm-markets-plan.md`](./dpm-markets-plan.md). Cites the
> canonical paper:
> **Pennock, D. M. (2004). "A Dynamic Pari-Mutuel Market for Hedging,
> Wagering, and Information Aggregation." *Proc. 5th ACM Conference on
> Electronic Commerce*, pp. 170–179.**
>
> All equation numbers below refer to that paper unless noted otherwise. We
> use the **DPM I** variant (§4, *losing money redistributed*) — DPM II (§5)
> is rejected because Pennock himself flags it can lose money on a correct
> prediction if prices swing wildly (§5.3 verbatim).

## Notation

For each outcome `i`:

- `M_i` — total collateral wagered on outcome `i` (post-`openTime`, with
  intent contributions transitioned in at par)
- `N_i` — total shares outstanding on outcome `i`
- `M_other` — total collateral on all *other* outcomes (binary: the opposite
  side; N-outcome group: the sum of all losing-side collateral)
- `N_other` — analogous shares-outstanding aggregate on the other side(s)
- `pool = Σ_i M_i`

Per user `u`:

- `userShares[u][i]` — shares of outcome `i` held by user `u`
- `userPaid[u][i]` — cumulative collateral spent acquiring shares on
  outcome `i` (the DPM I refund basis)

## Price function (Pennock eq. 7)

Buying shares of outcome `i` (denominator uses *other-side* shares):

```
p_i(n) = (M_i / N_other) · exp(n / N_other)
```

`p_i(n)` is the instantaneous price per share after `n` shares of `i` have
already been purchased in the current trade. `p_i` rises exponentially in
`n` → marginal cost increases as you buy more → **early-bird reward built in**.

At `n = 0`, `p_i(0) = M_i / N_other = P_other` (the current payoff per share
of the *opposite* outcome). This is exactly Pennock's design constraint
(§4.2.1): *"price of A equals payoff of B."*

## Cost integral (Pennock eq. 6, integrated form)

Total cost to buy `n` shares of `i` in one trade:

```
m(n) = ∫₀ⁿ p_i(x) dx
     = (M_i / N_other) · ∫₀ⁿ exp(x / N_other) dx
     = M_i · (exp(n / N_other) − 1)
```

Closed-form, single `exp` evaluation.

## Inverse (shares purchasable for `m` dollars)

Solving `m(n) = m` for `n`:

```
n(m) = N_other · ln(1 + m / M_i)
```

Single `ln` evaluation. This is the form `enter` calls: user submits `m`
collateral, contract computes `n`. After the trade, state updates:
- `M_i := M_i + m`
- `N_i := N_i + n`
- `userShares[u][i] += n`
- `userPaid[u][i] += m`

`M_other` and `N_other` are unchanged by a trade on `i` (they reflect the
other outcome(s) only).

## Payoff at resolution — DPM I (§4)

If outcome `w` wins, user `u`'s payout is:

```
payout(u) = userPaid[u][w]                        // refund of initial price paid
          + (M_other_at_resolution / N_w) · userShares[u][w]   // pro-rata losers' pool
```

Equivalently: each share of `w` redeems `userPaid_per_share + P_w` where
`P_w = M_other / N_w` is the share of the losers' pool per winning share
(Pennock eq. for DPM I payoffs).

Other outcomes (losers) redeem 0.

## Self-funding identity (proof)

Total payout if `w` wins:

```
Σ_u payout(u)
  = Σ_u userPaid[u][w] + (M_other / N_w) · Σ_u userShares[u][w]
  = M_w + (M_other / N_w) · N_w
  = M_w + M_other
  = pool
```

Total in = total out. **The operator never adds or loses a cent**, regardless
of trade order, par-vs-dynamic mix, or how wildly prices swing. This is the
load-bearing safety property.

## Par boundary — when `N_other == 0`

Pennock's eq. 7 is undefined when `N_other = 0`. He proposes a "seed wager"
subsidy to initialize both sides (§4.2.1 last paragraph). We don't seed
(self-funded property). Instead, we fall back to the classic-parimutuel base
case:

- **If `N_other == 0`:** sell shares on outcome `i` at par — `$1/share`.
  Deposit `m` → mint `n = m` shares → set `M_i := M_i + m`,
  `N_i := N_i + m`, `userShares[u][i] += m`, `userPaid[u][i] += m`.
- **Once `N_other > 0`:** dynamic Pennock pricing engages on subsequent
  trades.

This is a *boundary* decision we make (par as the limit when the dynamic
formula is undefined), not a new pricing formula. The self-funding identity
above holds par-or-dynamic, so it cannot cause insolvency.

## Intent → DPM transition at `openTime`

Lazy per-user. On a user's first post-`openTime` action (`enter` or
`claim`), if their `intentTransitioned[u]` flag is false:

For each outcome `i`:
- `userShares[u][i] += intentStake[u][i]` (par allocation: 1 share per
  intent dollar)
- `userPaid[u][i]   += intentStake[u][i]` (DPM I refund basis: $1/share)
- `intentStake[u][i] := 0`

Set `intentTransitioned[u] := true`.

Market totals are initialized once, on the *first ever* post-`openTime`
interaction (lazy per market):
- `M_i := intentTotals[i]`
- `N_i := intentTotals[i]`

Both lazy steps are O(outcomeCount) per user / per market, paid by whoever
triggers them.

**Why par at the transition:** every intent participant deposited dollar-for-
dollar with no pricing math; allocating them shares at par at `openTime`
makes their position equivalent to "wagered `$X`, got `X` shares at $1 each."
The DPM I dynamics (early-bird reward) then kick in for *new* post-`openTime`
buyers, who pay rising Pennock prices that reward those who entered earliest
relative to *them*.

## No-contest at resolution

If the winning outcome has `N_w == 0` (nobody backed it — possible in
N-outcome groups, or in binary if intent on the winning side was withdrawn
and nobody entered post-`openTime`), the payoff formula divides by zero.
Standard parimutuel handling:

- Refund every participant their net deposits (`userPaid[u][i]` for every
  `i`, plus any un-transitioned intent stake).
- Market void.

Refunds ≤ deposits → self-funded still holds.

## Fixed-point implementation notes

The math requires `exp` and `ln`. Recommended library: **PRBMath UD60x18**
(unsigned 18-decimal fixed point) or equivalent vetted lib. Notes:

- **Rounding direction must be protocol-favorable per call site:**
  - In `enter(amount = m)`: round `n(m) = N_other · ln(1 + m/M_i)` **down**
    (mint fewer shares for the same collateral — favors solvency).
  - In `claim` payout: round the loser-pool slice
    `(M_other / N_w) · userShares[u][w]` **down**.
- **Overflow safety:** Pennock's exponential price function is unbounded
  above. Implementation must cap or guard `n / N_other` to keep `exp(·)`
  inside the lib's safe domain; reverting on overflow is acceptable (a
  whale-sized single trade beyond the lib's range can be split client-side).
- **Domain checks:** `ln(1 + m/M_i)` requires `M_i > 0`. Caller path
  guarantees this (the par boundary handles `M_i == 0`; once we're in the
  dynamic branch, both sides are non-zero by construction).
- **Identity assertion:** in test, after every `enter`/`claim`, assert
  `pool == Σ M_i` exactly (no drift). The math says it must hold; the
  fixed-point implementation must respect it.

## What we explicitly do **not** do

- **No in-pool exit / sell-back.** Pennock §3.1: *"there is no
  corresponding market maker to accept sell orders."* Our v1 matches
  exactly. A future P2P aftermarket (CLOB-style ask queue) is a separate
  project.
- **No LMSR cost function.** Earlier drafts of this design grafted an LMSR
  cost function onto the redistribution payout — that hybrid is not
  battle-tested and was retracted.
- **No DPM II (`T / N_winner` payout).** Rejected per Pennock §5.3
  ("a wager on the correct outcome might actually lose money").
- **No operator seed.** Par-until-contested replaces Pennock's "seed wager"
  recommendation, keeping the protocol's never-loses-capital property.

## Quick sanity walkthrough (binary, post-`openTime`, no intent)

Starting state: `M_yes = 0, N_yes = 0, M_no = 0, N_no = 0`. Both sides
empty → par.

1. Alice deposits **$10 on YES**. `N_no == 0` → par. Mint 10 YES shares.
   `M_yes=10, N_yes=10`, `userShares[A][yes]=10`, `userPaid[A][yes]=10`.

2. Bob deposits **$20 on YES**. `N_no` still 0 → par. Mint 20 YES.
   `M_yes=30, N_yes=30`, `userShares[B][yes]=20`, `userPaid[B][yes]=20`.

3. Carol deposits **$10 on NO**. `N_yes > 0` so dynamic applies on the NO
   side, but `N_other_for_no = N_yes = 30`. Pennock eq.: 
   `n_no = N_yes · ln(1 + 10/M_no)`. But `M_no = 0` here, so the dynamic
   branch is undefined — **NO is also still at par** (one-sided market).
   Mint 10 NO at $1. `M_no=10, N_no=10`, Carol owns 10 NO shares at $1
   paid.
   
   Generalized boundary rule: par fires whenever *either* `N_other == 0` or
   `M_i == 0` on the buying side (i.e., until both sides are live).

4. Dave deposits **$10 on YES**. **Both sides now live.** Dynamic engages:
   - `M_yes = 30, N_no = 10` (other side state)
   - `n = N_no · ln(1 + m / M_yes) = 10 · ln(1 + 10/30) ≈ 10 · 0.288 = 2.88`
   - Dave gets ~2.88 shares for his $10 — a far worse deal than Alice/Bob
     got at par. **That's the early-bird reward working as intended.**
   - State: `M_yes = 40, N_yes = 32.88, M_no = 10, N_no = 10`.
   - `userShares[D][yes] = 2.88`, `userPaid[D][yes] = 10`.

5. **Resolution: YES wins.** Payouts:
   - Alice: `10 + (10/32.88) · 10 = 10 + 3.04 = $13.04`
   - Bob:   `20 + (10/32.88) · 20 = 20 + 6.08 = $26.08`
   - Dave:  `10 + (10/32.88) · 2.88 = 10 + 0.88 = $10.88`
   - Carol: $0 (lost her bet)
   - **Sum:** `13.04 + 26.08 + 10.88 = $50.00 = pool` ✓

Note: Alice and Bob each got their initial $X back plus a profit slice; Dave
got back his $10 but barely any profit (he paid more per share, owns fewer
shares). The early-bird reward is the *profit multiplier*, while the refund
floor (DPM I) guarantees all winners at least break even.
