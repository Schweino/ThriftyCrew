# PLAN: the carriage gate - "if it gets on the page, Omaha has it"

Status: PLAN ONLY (2026-08-22). Nothing here is built. Brad implements on Opus from this document.

## 0. What happened, precisely

On 2026-08-22 four live paid recipes were found whose defining ingredient no Omaha store is known to carry
(doubanjiang x3, Korean rice cakes x1), and one more (`musakhan-sumac-chicken`) priced from a hard-coded
label because its board commodity has no feed price. All four were unpublished to draft (reversible).

The rule already exists in code. `grocery\ingredient-queue.ps1` implements Rule B (CARRIED once ONE store
has it; NOT-CARRIED only when all seven were CHECKED), with per-store evidence and a self-test, and
`hunt-run.ps1` reads its verdicts (`Get-TermVerdictMap`, hunt-run.ps1:234) to derive `priced` /
`parked` / `rejected-not-carried` (`Get-DerivedPricingState`, :121). That machinery worked for every
term it was shown.

It was never shown these. Four layers, each defensible alone, together let a not-carried ingredient reach
a paid page:

| Layer | File | What it does today | Why it let this through |
|---|---|---|---|
| 1. Mapper | `.claude\agents\recipe-ingredient-mapper.md` | Maps each ingredient to a commodity id; reports only **id-less** ingredients as "absent terms" for the queue | `doubanjiang`, `rice-cakes`, `ground-sumac` all HAD ids. Resolved, never queued. **Existence of an id was treated as carriage.** |
| 2. Hunt state | `hunt-run.ps1:700` | `-Advance -To pricing -Terms <list>` - the list comes from the mapper; zero terms derives `priced` instantly | Fail-OPEN: an under-reported term list means the recipe is priced. Nothing in hunt-run checks the mapped bids themselves. |
| 3. Cost engine | `meal-prep\engine\cost-recipes.ps1:156-173` | board -> feed -> no-board-price allowlist -> **advisory flag** -> **label fallback prices it anyway** -> NO PRICE BASIS | The `MAPPED BID NOT ON ANY BOARD` flag is a text line nothing blocks on; the next statement prices the line from a hard-coded label. That is the route sumac took. |
| 4. Publish gate | `feed-covers-published.ps1` + `db\no-board-price-ok.json` | Every card bid must be priceable in the feed, EXCEPT allowlisted bids | The allowlist held `dried-guajillo-chiles`, `aji-amarillo-paste` (both genuinely carried) **and `doubanjiang`** (never found). It answers "may this skip board pricing?" and was silently also answering "is it carried?". The self-test at :186-198 uses doubanjiang as the exemplar of correct behaviour. |

Two independent facts were being read as one:

* **CARRIAGE** - does any Omaha store stock this food? A store-evidence fact. Brad's rule is about this.
* **PRICING** - does our board have a matched price for it? A matcher fact. A register estimate is fine here.

A bid can be carried-but-unpriced (sumac: Baker's has it, the matcher gap keeps it out of the feed - one of
the 13 recoverable) and that is legitimate. A bid can be unpriced-because-not-carried and that must reject
the recipe. Today nothing distinguishes them.

## 1. The principle

**Carriage is a fact about a commodity id, proven by evidence, never by existence.** Agents produce
evidence; code produces verdicts; the publish gate reads verdicts and refuses on anything less than CARRIED.

Three consequences:

1. The verdict lives in **data keyed by commodity id** (what costed lines carry and what the gate can check),
   not in an agent's memory and not in a term-keyed per-run queue.
2. Every enforcement point is **fail-closed**: an agent that forgets leaves a recipe parked, never priced.
3. **UNKNOWN is not NOT-CARRIED.** The doubanjiang "absence" was a wrong search term ("chili bean sauce"
   returned 237 rows of Bush's chili beans). Refuse to CREATE on UNKNOWN; take DOWN only on NOT-CARRIED
   with all-seven-checked evidence. That asymmetry is what stops the gate flapping on a capture hiccup.

## 2. The carriage verdict - one derivation, used everywhere

Derived per bid, by ONE library function every gate calls (put it next to `guard-lib.ps1`; nothing
re-implements it):

```
CARRIED      if  smp-feed.json ingredients[bid].stores has >= 1 real price        (automatic, no human)
         or  carriage ledger has a CARRIED entry with store + product + price + date (adjudicated)
NOT-CARRIED  if  carriage ledger has NOT-CARRIED with all 7 stores CHECKED (not blocked/errored)
                 and the terms tried at each store recorded
UNKNOWN      otherwise
```

* The feed tier covers 273 of the 275 bids in use today with no work. It is trustworthy because feed
  rows have passed the matcher's include/exclude rules - unlike raw capture rows, where `found_by_term`
  proves only that a search returned *something* (exactly the doubanjiang failure). Raw captures are
  hints for the pricer, never verdicts.
* The ledger is a small new file, `grocery\carriage.json`, keyed by bid. It stores only adjudicated
  verdicts (today: `ground-sumac`, `keto-buns`; `doubanjiang` and `korean-rice-cakes` as UNKNOWN with
  history). Keep it separate from `commodities.json`: that file is *how to search*, this one is *what
  was found*; different authors (registrar vs pricer vs daily capture), different change cadence.
* Every NOT-CARRIED entry carries `terms_tried` per store and a `recheck` trigger, mirroring the
  `coverage-gap-allowlist.json` DELETE-TRIGGER pattern. A NOT-CARRIED verdict that only ever tried one
  term is visibly weak.
* `found_by_term` matching (if any raw-capture logic is ever used) MUST accept both conventions:
  Baker's (kroger-api) writes the commodity id, every other store writes the search string. This
  produced a false zero on sumac in the 2026-08-22 audit.

## 3. Where it is enforced

### 3a. Cost engine - `meal-prep\engine\cost-recipes.ps1` (the fact gets recorded)
* Each costed line gains `carriage: CARRIED|UNKNOWN|NOT-CARRIED`; each recipe record gains
  `lines_uncarried` next to the existing `lines_priced` / `lines_unpriced`. Same shape, same readers.
* The label fallback (:169-170) fires ONLY when carriage is CARRIED. An UNKNOWN/NOT-CARRIED bid falls
  through to NO PRICE BASIS and counts as uncarried. No more "flag it, then price it anyway".
* `no-board-price-ok.json` is validated at load: an allowlisted bid whose carriage is not CARRIED is a
  **hard error**, not a silent `registerEst++`. The allowlist keeps its meaning ("we accept a register
  estimate for this") but can no longer exist without carriage evidence.
* Drained-basis suffixes (`cannellini-beans+drained`) strip to the base bid before lookup - a false
  "not in feed" in the audit came from exactly this.

### 3b. Publish gate - `feed-covers-published.ps1` (already names slugs that come down; wave-publish.ps1:191)
* New finding class: any published recipe with a non-optional line at NOT-CARRIED ->
  `X <slug> [NOT-CARRIED: <bid>]` -> comes down, same path as today's feed-coverage failures.
* UNKNOWN on a LIVE recipe -> reported + alert + worklist, NOT a takedown (see 1.3). Brad decides.
* `publish.ps1 -AllowCreate` additionally refuses to CREATE any recipe with `lines_uncarried > 0`
  (UNKNOWN or NOT-CARRIED). Creating a paid post is the irreversible act; nothing unknown crosses it.
* Self-test changes: the doubanjiang fixture at :186-198 re-points to `aji-amarillo-paste` (genuinely
  carried). New MUST FIRE: an allowlisted bid with no carriage evidence fails the gate.

### 3c. Hunt pipeline - `hunt-run.ps1` (the fact gets checked before work is spent)
* At `-Advance -To pricing`, hunt-run DERIVES the absent-term list itself: every mapped bid whose
  carriage is not CARRIED, unioned with the mapper's id-less terms. The mapper can no longer under-report;
  `-Terms` becomes a supplement, not the source of truth.
* Consequence: a recipe whose bids are all CARRIED still derives `priced` with zero queue work (fast
  path preserved). One UNKNOWN bid -> `parked` until the pricer answers. Fail-closed.
* `ingredient-queue.ps1` entries gain a `bid` field (the mapper knows it at enqueue time); `-Verdict`
  promotes the adjudicated result into `carriage.json` keyed by bid, so the durable fact outlives the run.

### 3d. Re-check cadence (the revival path)
* A weekly pass (hang it on the existing daily chain or `check-ad-cycles.ps1`) re-derives carriage for
  every bid in use. A feed price appearing for a NOT-CARRIED/UNKNOWN bid flips it to CARRIED with the
  evidence, and lists any DRAFT recipes that bid had parked. Reviving a draft is Brad's call from that
  list. This is why the four came down as drafts, not deletions.
* The same pass lists live recipes riding on exactly ONE store (10 bids, 30 recipes today: achiote-paste
  and dried-ancho-chiles carry 8 each). Not a failure - the early warning for the next one.

### 3e. Capture-side term sanity (optional, last)
* A cheap audit over `commodity-search.json`: for each term, do the returned item names EVER contain the
  commodity's own head noun? `doubanjiang` -> "chili bean sauce" -> 237 rows, zero containing
  doubanjiang/toban. `rice-cakes` -> 650 Quaker snack rows, zero tteok. Zero-over-N = suspect term,
  into the coverage-gap worklist. This is what makes a NOT-CARRIED verdict honest.

## 4. Residual risk, named with its owner

A bid can be CARRIED by the feed and still be the WRONG FOOD: `rice-cakes` is priced (Sam's Club, a
Quaker snack). A Korean rice cake recipe mapped to `rice-cakes` would pass this gate with a snack price.
That is a MAPPING defect, not a carriage one, and it already has an owner: the commodity-registrar
(variant-vs-duplicate) and the batch auditor's mapping-soundness check. This plan does not solve it and
must not pretend to; it closes the carriage door only.

## 5. Backfill and acceptance

1. Build `carriage.json` with the evidence already in hand:
   * `ground-sumac`: CARRIED - Baker's, Morton & Bassett All Natural Sumac 2 oz, $12.79, 2026-08-22,
     product_id 0001629144192 (kroger-api). Note: the proper fix is the matcher gap so it enters the feed
     and the `label:` line disappears on the next recost - one of the 13 recoverable, out of scope here.
   * `keto-buns`: CARRIED - Walmart, bettergoods Keto Friendly Hamburger Buns 14 oz 8 ct, $4.78,
     captured 2026-08-01/06/11. Needs the id minted through the registrar first.
   * `doubanjiang`, `korean-rice-cakes`: UNKNOWN, with the wrong-term history recorded.
2. Remove `doubanjiang` from `no-board-price-ok.json`. With 3a it would hard-error anyway; remove it on
   purpose, not by crash.
3. Acceptance: recost -> `lines_uncarried = 0` across all 570; FEEDCOV clean over 560 published with
   zero NOT-CARRIED and zero UNKNOWN; every touched script's `-SelfTest` green, including the new
   MUST FIRE cases:
   * recipe with one non-optional UNKNOWN bid -> refused to create, parked in hunt
   * one non-optional NOT-CARRIED bid -> `rejected-not-carried` / comes down if live
   * label-priced line whose bid is CARRIED -> passes (musakhan stays)
   * allowlisted bid with no carriage evidence -> hard error
   * optional (garnish) line NOT-CARRIED -> passes
   * NOT-CARRIED with one store `blocked` -> stays UNKNOWN, never NOT-CARRIED (existing queue test, now
     asserted at the ledger level too)
   * the four drafts, re-costed from their spec files in a scratch dir, produce `lines_uncarried > 0`
     - the gate must reject the very recipes that got through.

## 6. Sequencing - one phase per fresh session, check the meter before each (80% rule)

| Phase | Closes | Touches |
|---|---|---|
| 1 | **The publish door.** Carriage library + 3a + 3b + allowlist fix + backfill + acceptance | guard-lib, cost-recipes, feed-covers-published, publish, no-board-price-ok.json, carriage.json |
| 2 | **The hunt door.** 3c - hunt-run derives absent terms from carriage; queue promotes to ledger | hunt-run, ingredient-queue, mapper + pricer agent prose (one line each: "existence is not carriage") |
| 3 | **The revival path.** 3d weekly re-check, draft revival list, single-store watch | check-ad-cycles or daily chain |
| 4 | **Honest NOT-CARRIED.** 3e term sanity (optional) | grocery audits |

Phase 1 alone makes a repeat impossible at the only point that is irreversible. Phases 2-4 make it cheap.

## 7. One decision for Brad before Phase 1

UNKNOWN on a live recipe: alert-and-worklist (recommended, per 1.3) or automatic takedown? The standing
rule says one uncarried ingredient skips the recipe - but UNKNOWN means "we have not proven it either
way", and the only UNKNOWNs that have ever existed were wrong search terms. Taking down on UNKNOWN
would have pulled musakhan for a matcher bug. Recommendation: refuse-create on UNKNOWN, take down on
NOT-CARRIED only.
