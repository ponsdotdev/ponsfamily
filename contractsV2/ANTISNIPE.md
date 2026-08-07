# Opening-window protection for pons v2

Branch: `features/enhance-antisnip`

## Why

Every protection in v2 today works in the dimension of **quantity or structure** —
`reservedTokens` caps what the curve will ever sell, the whole supply mints to the
curve so there is no pool to snipe at block zero, `_beforeInitialize` stops anyone
pre-initializing the graduated PoolKey. None of them work in the dimension of
**time**. In the first second of a launch the curve cannot tell a listener reacting
to `TokenLaunched` from a human who opened the page.

Robinhood Chain sequences first-come-first-served behind a single sequencer with no
public mempool, so classical front-running is impossible — but latency racing is
wide open, and the contestable edge is milliseconds.

Note that v1's `restrictionEndBlock` approach does not transfer. At ~10 blocks per
second, v1's two-block window is roughly **200 milliseconds**. Any temporal
protection here has to be measured in wall-clock time.

## What this branch adds

### Layer 1 — decaying opening buy tax

`PonsV2BondingCurve` gains four immutables (`launchedAt`, `snipeTaxStartBps`,
`snipeTaxWindow`, `snipeTaxHalfLife`) and one view, `currentSnipeTaxBps(address)`.
The levy applies to buys only, halves every `halfLife` seconds, and reaches zero at
`window`. It is charged on the quote leg exactly like `feeBps`, before the input
reaches the pricing reserve.

`startBps == 0` disables it and reproduces the previous behaviour byte for byte,
so existing launch configs stay expressible.

**Resolution is whole seconds, deliberately.** `block.timestamp` is the only clock
available: on an Arbitrum Orbit chain `block.number` approximates the *L1* block
number and cannot measure L2 time. Every block inside the same second sees the same
tax. That is the intended behaviour rather than a limitation — a bot's advantage
over a human is sub-second, so a one-second floor removes it wholesale. Linear
interpolation between halvings is implemented and takes effect whenever
`halfLife > 1`.

Example, `startBps = 9800`, `halfLife = 1`, `window = 8`:

| t (s) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| bps | 9800 | 4900 | 2450 | 1225 | 612 | 306 | 153 | 76 | 0 |

Gentler, `startBps = 5000`, `halfLife = 3`, `window = 12`:

| t (s) | 0 | 1 | 2 | 3 | 6 | 9 | 12 |
|---|---|---|---|---|---|---|---|
| bps | 5000 | 4167 | 3334 | 2500 | 1250 | 625 | 0 |

Four things this had to get right:

1. **Keyed on `recipient`, not `msg.sender`.** Keying on the caller would let any
   router — including one a sniper deploys — be exempted once and then resell entry
   to the window.
2. **Excluded from `MAX_TOTAL_TRADE_FEE_BPS`.** That 20% ceiling protects traders
   from a creator's standing rake for the life of the launch. This levy is transient
   and expires by itself. Folding them together would either cap the opening tax
   where a bot would happily pay it, or raise the standing-rake ceiling to 99%.
   Separate risks, separate limits — `MAX_SNIPE_TAX_START_BPS`.
3. **Clamped-fill gross-up denominator.** `buy()` grosses a clamped fill back up by
   `BASIS_POINTS - feeBps - creatorTaxBps - snipeBps`. The curve's constructor
   enforces `MIN_BUYER_SHARE_BPS = 100`, so the denominator can never approach zero
   where the ceil-rounding would blow up, and a buyer always nets at least 1%.
4. **Routed through the existing fee split.** The levy joins the base fee in
   `_accrueFees`, so it flows through protocol / buyback / creator untouched. No new
   distribution path means no new surface for it to be diverted through. `CurveBuy.fee`
   reports the combined amount; `SnipeTaxCharged` lets an indexer decompose it without
   a second ABI for `CurveBuy`.

One behavioural change beyond the levy: `buy()` now reverts `ZeroAmount` when
`tokensOut == 0`. Reachable for dust inside the window, where the levy consumes the
whole input before it reaches the curve. Refusing is strictly safer than settling —
nobody is denied a fill they wanted, and the caller keeps their funds.

### Layer 2 — exemptions

`initialize` becomes `initialize(token, launcher, address[] snipeTaxExemptions)`,
still `onlyFactory`, still once. The launcher and the creator fee recipient are
excused unconditionally; the creator's own list is capped at
`MAX_SNIPE_TAX_EXEMPTIONS = 32`. Duplicates and the zero address are skipped rather
than rejected, since the list is assembled from three sources that do not know about
each other and a cosmetic overlap should not fail a valid launch.

**There is no setter.** An exemption granted after a launch is live would wave an
address through a window every other buyer paid to cross.

### Layer 3 — `PonsV2LaunchRouter`

Layer 1 makes a creator's own opening buy prohibitive if it lands as a separate
transaction, since nothing distinguishes it from a bot's. The router closes the
window for the one case that is provably not a race: the buy atomic with the launch,
which cannot have observed it.

A separate contract purely for bytecode budget (see below). It needs
`setTrustedRouter(router, true)` on the factory. That trust lets it attribute a
launch to its caller; it does **not** let it launch for someone who could not launch
themselves — `launchTokenFor` still gates the named launcher through `canLaunch`.
Without that, the whitelist would be defeated by routing through a whitelisted
contract.

The router exempts the *recipient*, not itself, which is what makes the exemption
non-transferable.

### Supporting changes

- `LaunchConfig` gains a `SnipeTaxTerms snipeTax` field, validated in
  `_validateLaunchConfig` and folded into `_economicsDigest`, so a creator's
  `expectedEconomics` pin now covers the window terms too. **This changes the
  digest preimage from ten values to thirteen** — any off-chain code computing it
  must be updated alongside.
- `canLaunch(address)` exposed as a view, closing a gap the docs already assumed.
- `trustedRouters` mapping plus `setTrustedRouter`, owner-gated.
- `launchToken(params, id, pairToken)` keeps its exact signature and behaviour.
  New work goes through `launchTokenFor(params, id, pairToken, launcher, exemptions)`,
  where `launcher == address(0)` means the caller.

## Bytecode budget

`PonsV2LaunchFactory` was the binding constraint throughout. Measured with
solc 0.8.28, `--via-ir --optimize --optimize-runs 200`:

| Contract | Before | After |
|---|---|---|
| PonsV2LaunchFactory | 22757 | **24267** / 24576 |
| PonsV2BondingCurve | — | 10448 |
| PonsV2LaunchRouter | — | 3247 |

309 bytes of headroom. The first draft carried three launch entry points and
assembled the exemption array in the factory, and came out at 24744 — over the
limit. Collapsing to two entry points (one full `TokenParams` calldata decode is
expensive) and moving exemption assembly into the curve recovered ~480 bytes.

**Anything further added to the factory needs a size check first.**

## Not done, deliberately

**Per-wallet cap during the window.** It is trivially defeated by splitting wallets
on a chain with no identity, and enforcing it means making `buy()` revert — which
destroys the "partial fill never fails" property that is currently v2's most elegant
anti-grief protection. A tax cannot be wallet-split because it is charged per unit of
capital, not per address.

**CREATE2 launch addresses.** Worth doing, but not here and not first. A predictable
curve address lets a sniper prepare calldata and approvals *before* the launch
transaction lands; today's unpredictable addresses are an accidental protection. Land
CREATE2 only after this window is live, or you weaken the position before replacing it.

## Tests still to write

- `currentSnipeTaxBps` monotonically decreasing; exactly zero at `launchedAt + window`
- levy never causes `buy()` to revert for any `quoteIn` that would otherwise fill
- worst case combined: clamped fill + max levy + max creator tax, checking gross-up rounding
- exempt address pays zero at t=0; non-exempt recipient behind an exempt caller does not
- fuzz `spent + refund == received` with the levy active
- **graduation invariant**: with the levy at maximum, `reservedTokens` and the seeded
  pool price are identical to a launch without it. The levy is taken off the input
  before pricing, so it never enters the pricing reserve — this asserts that
- fee split proportions unchanged; the levy only changes magnitude
- router: launch + buy atomic, recipient exempt, native and ERC-20 quote paths,
  clamped-fill refund forwarded to the caller, allowance cleared
- `launchTokenFor` from an untrusted caller reverts; from a trusted router with a
  non-whitelisted launcher reverts
- regression: `_beforeInitialize` still rejects non-factory callers

## Open questions for review

1. A 98% levy at t=0 means someone who buys accidentally at t=0.2s loses nearly
   everything. The mitigation is UI, not contract: show the live rate and gate the
   buy button during the window. If the UI is not ready, lower `startBps` — 95%
   with a shorter half-life deters almost as well with a far more forgiving tail.
2. `MAX_SNIPE_TAX_WINDOW` is set to 60 seconds. Past a minute this stops being
   anti-latency and becomes a standing tax on anyone without advance notice.
3. The levy flows through the buyback split, meaning a heavily sniped launch funds
   a larger PONS buyback. Intended, but worth stating out loud before mainnet.
