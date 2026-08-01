# The Master Plan, 2026-08-01

Written by Fable at Brad's direction, after a full verification pass over the day's eight commits.
ONE ranked backlog. It SUPERSEDES the open-item sections of:

- `grocery\BACKLOG-2026-07-30.md` (24 of 24 numbered items DONE; only 3b's capture strategy lives on, here)
- `grocery\AUDIT-2026-07-29-synthesis.md` (all bug groups addressed in the 07-30 batches; F3 verified
  CLOSED today: full Walmart pulls of 2,784-4,863 rows at 217 terms sit inside the union window)
- `grocery\PLAN-browser-rescue-2026-07-31.md` (still the procedure for capture sessions; folded in below)
- `design\STATUS-elite-layer-2026-07-31.md` (Wave 3 remainder folded in below)
- `sidecar\out\backtest-report.md` + `phase2-report.md` (next steps folded in below)

Those documents stay as history. Work gets picked from HERE.

---

## Section 0: the verified baseline (what the estate looks like right now)

Every check below was run against LIVE data this morning, not against claims.

| Surface | State |
|---|---|
| Homepage | one theme-color, touch icons, light-only, zero TikTok, interstitial v3 exactly once, both Ads conversions, Meta pixel intact |
| Board | 0 formatter defects, masthead/aisle/demo/ledger live, 1,144 rows, served board.json byte-identical to local at the hashed URL |
| Hub | 521 cards, 20 badges, 0 stale, Ads hero + AW-18314028055 intact |
| Rotation | state vs Ghost 20/20; public feed correct (the "malformed feed" was my own parser choking on a BOM browsers strip per spec) |
| Self-tests | fmt-lib 34, compare-deals, publish change-gate, consistency 5, basis-outlier 5, semantic 3: ALL PASS |
| Suites | test-auditors **336** green (282 when this was written, 296 after the day's batches, +40 across the plan run); guards GREEN, board published clean |

Mid-verification, guards went genuinely red: today's fresh ad pull moved three cells off their stored
links (a store-brand enchilada sauce displacing Old El Paso, a halved cumin shelf price, a tartar-sauce
repricing). That was REAL and FRESH, not a regression from the day's work, and it was healed through the
sanctioned path (`check-ad-cycles` auto-repair re-pointed the links headlessly, re-guarded, republished:
the live board now serves week 2026-08-01 clean). The lesson stands: a verification pass that finds a
red gate should reach for the estate's own orchestrator before reaching for hand surgery.

**AND IT HAPPENED AGAIN, LATER THE SAME DAY - now FIXED (see repair-multipack-sizes.ps1).** A
background Family Fare pull at 16:06 brought in `Heinz Tomato Ketchup, 2 Pack 50.5 Oz` with `size=[50.5 oz]`
- the name states a pack count and the size records ONE unit, so the true total is 101 oz and the per-unit
would publish at 2x. **Guard 5 caught it in the FEED: it is NOT on the board and no cell is mispriced.**
Confirmed data-side, not a regression from the F1 or recipe-identity work (nothing committed today touches
compare-deals or any board builder, and the offending row is in a store file written by a scheduled pull).
Heal it the sanctioned way - `check-ad-cycles` first, a `multipack-allowlist` entry only if the pack really
is one unit - and re-guard before anything publishes.

Verification also CAUGHT and FIXED, same morning:

1. **The hub went stale on every rotation flip.** Static FREE badges are baked at build time and nothing
   republished the hub when the rotation flipped; found live (kalua bowls badged hours after rotating
   out). Fixed structurally: the rotation now republishes the hub whenever the set changes, the public
   feed now publishes Ghost-CONFIRMED slugs rather than intent, and build-hub-grid is path-portable so
   the chain works from the cloud runner too.
2. **My url-worklist entry was written to a file nothing reads.** The machinery reads
   `out\url-worklist.json` (regenerated); my hand-made root-level file was dead weight, deleted. The
   cloves link gap it "recorded" had already self-healed via the FF headless resolver, which re-pointed
   the link to the correct $2.99 product. The withdrawal-then-heal loop works; my logging of it did not.
3. Hygiene: removed a 0-byte shadow `BACKLOG-2026-07-30.md` at the income root.

**Standing item for Brad: the freeze.** Nominally in force until ~08-07, but today shipped substantial
grocery code at your explicit direction (the board publish, the accuracy pass, the semantic wiring).
Either lift it formally or reaffirm it; the ambiguity is now the only thing it produces.

---

## Section 1: NOW (highest value, nothing blocking)

**1. DONE 2026-08-01 - the coverage backlog is worked.** 88 findings -> 27; NO-INCLUDE 74 -> 13, and
all 13 remaining are recorded judgments rather than open questions (laundry-detergent is brand-narrow
by design, cranberry-juice is a juice-drink basis call, walnuts is a truncated name nobody can
verify). Four gated batches, one commit each; 12 wrong-product rulings in `known-wrong.json`.

The procedure below survived contact, but the GATE it describes was wrong twice and is now rebuilt:
it judged rule edits by today's cells, when board effects are weekly, so it reverted correct work
that revealed real invisible products. It now measures VISIBILITY (rows revealed, after the
commodity's own excludes) and THEFT (verify-no-regression `-IgnoreIds`) instead. Full write-up in the
`coverage-backlog-worked` memory. One limit worth carrying forward: the gates protect OTHER
commodities and the links; **nothing automated can tell you a revealed row is wrong for the commodity
being widened** - `frozen\s+vegetables` passed every gate while matching an entire Kroger aisle.

**1b. STILL OPEN from this work:** 13 adjudicated-skip findings stay in the sweep output by design.
`walnuts` needs an untruncated catalogue name before anyone can rule on it.

THE ORIGINAL PROCEDURE, learned from the `cheese,\s+shredded` regression:

- Batches of ~8 commodities, ONE commit each.
- Per batch: edit `commodities.json` -> `compare-deals` -> **crown-diff AND tile-integrity AND
  audit-known-wrong** (the cheese lesson: crown-diff alone said "0 changed" and looked clean while
  tile-integrity caught the collision) -> guards -> publish only on all-green.
- A pattern that adds zero coverage gets REVERTED, not kept ("bought nothing, broke something").
- Re-run the semantic sweep after each batch; the findings list shrinks as rules widen, which is the
  progress meter.
- Skip anything ambiguous (a "Pumpkin Pie" under pie-pumpkins is a judgment call): leave it in the
  findings file with a note rather than forcing a rule.

**2. DONE 2026-08-01 - `grocery\aisle-test.ps1` ships.** F1 is unblocked.

It is NOT built on `/rank-commodity`, and that matters. The semantic build was measured and FAILED: across
all 2,825 shipped board pairs the score distributions interleave (a real hot dog, "Wimmer's Wieners",
scores BELOW three of the four founding failures), because a cross-encoder measures vocabulary overlap,
not membership. The peer-relative variant failed too. What works is the store's own taxonomy - Family
Fare's `canonical_url` is a shelf path on 99.7% of rows - gated on DEPARTMENT via an authored, reviewed
category->department allowlist. An earlier version that LEARNED the allowlist from rule-matched rows
allowed an Olay body wash into `watermelon`, because the polluted rule had already taught it that
health_beauty was normal: a gate cannot learn its baseline from the thing it audits.

Result: 7.8% of rule-matched FF rows blocked, ~8 in 10 true pollution. BLIND INVERTS here (no shelf
evidence = no flip). Known limit: department-level only, so it cannot separate coffee from creamer when
the store shelves both in `beverages`.

**2c. THE AISLE TEST PAID IMMEDIATELY, on a use it was not built for.** Pointed at the LIVE board rather
than at candidate flips, it read 406 Family Fare cells and found FIVE wrong products - **two holding the
cheapest-price crown**: Arm & Hammer Baking Soda Clumping **CAT LITTER** as `baking-soda` ($0.0375/oz) and
Pineapple Teriyaki **BRATS** as `pineapple` ($1.3725/ea). Neither is a pricing error - both prices are
real - which is exactly why no price guard could see them. Also caught `sun-dried-tomatoes` matching a
Gilbert's chicken sausage through the include I had added the SAME MORNING in coverage batch 3. Fixed with
9 excludes; crowns moved to real products; the three that reached a board are in `known-wrong.json`. It now
runs DAILY in check-ad-cycles (`-LiveBoard`, advisory, BLIND-not-block, signature-deduped).

**2b. FINDING that fell out of it, worth its own work:** `fruit` commodities are only 34% produce - 26%
pantry, 24% BEVERAGES, 7% HEALTH_BEAUTY. A quarter of everything the fruit rules match is a drink. Those
wrong matches lose on price today, which is precisely the accidental-relevance-filter effect. `snacks`
(47% beverages) and `oils` (69% pantry / 29% beverages) are similar. Also: `coffee` is filed under the
estate category `oils`, almost certainly a miscategorisation - recategorising moves it on the public
board's category filter, so it was left for a deliberate call.

**3. DONE 2026-08-01 - the sweep runs nightly** inside check-ad-cycles as an advisory step beside the
coverage-gap guard: BLIND-not-block (proven reachable by pointing `-Python` at a path that does not
exist, not asserted from the code), signature-deduped so a standing backlog is reported once and only
NEW products speak again. It is not redundant with audit-coverage-gaps, which is regex reasoning
about regex and structurally cannot see a product whose name shares no vocabulary with the rule.

## Section 2: UNBLOCKED 2026-08-01 (was freeze-gated; the freeze was lifted at Brad's word)

**F1. BUILT 2026-08-01 - `discover-hyvee.ps1` ships as a DOCKET producer.** Bounded rotating search pass
(persisted cursor), rule-filtered, keeping only net-new candidates that beat the held per-unit by a margin.

**The plan's premise was wrong on the safety story and this is the correction.** It said to "run the aisle
test over its candidate flips" - that is IMPOSSIBLE for Hy-Vee, and it was measured, not assumed:
Hy-Vee search results carry no category/department (`analytics` is empty); the response DOES expose a
CATEGORY facet (for "baking soda": BAKING_SODA 3, **CAT_LITTER 1**, FACE_WASHES_AND_SCRUBS) but passing it
back as a `searchFilters` constraint is **SILENTLY IGNORED** - three request shapes, all returned the
identical unfiltered results with the cat litter still in them. A filter that looks applied and is not is
worse than none. So Hy-Vee depth cannot be gated the way Family Fare's can, and discovery therefore stops
at a review docket instead of writing the feed.

**First live run validated both halves.** 6 terms, 281 products, 14 candidates. REAL: That's Smart! peanut
butter 40 oz **-33.4%**, ketchup **-29%**, Hy-Vee EVOO 68 fl oz **-14.2%**, Hy-Vee no-salt black beans
**-11.1%** - all unreachable by the refresh-only puller. WRONG: a Hendrickson's Sweet Vinegar & Olive Oil
DRESSING and Pasta Roni Garlic & Olive Oil VERMICELLI, both matching the include and both beating the held
price. ~14% wrong, matching the FF browse-test rate.

**F1(a) DONE 2026-08-01 - the ADJUDICATION PATH ships, and the arrivals desk is where it lives.** A prospect
is an arrival that has not happened yet, so `build-arrivals-docket.ps1` grew a PROSPECTS section scored by
the same cohort divergence, and `adjudicate-discovery.ps1` records the verdict. Built for a docket that is
1 in 7 wrong: nothing is bulk (one key, one named reviewer, one written reason); ACCEPT sets no price, it
appends to `hyvee-catalog-adds.json`, a third work-list source for `pull-regular-hyvee` - the store supplies
the price, the never-priced-before path derives the size, compare-deals decides whether it wins, and if it
takes a cell it returns to this same desk as a scored ARRIVAL; REJECT delegates to `add-known-wrong.ps1`, so
compare-deals refuses to price the row at all. A ruled candidate never comes back (keyed on the store's own
product id, so a re-titled product cannot walk back on).

**WHAT THE SCORE IS WORTH, MEASURED ON THE 11 LIVE CANDIDATES:** the two known-wrong products rank FIRST and
SECOND (div 0.50) above all nine real ones (0.33 and 0.00) - so the ORDER is informative - but **the 0.75
floor fired on NEITHER**. Recorded rather than retuned; fitting a threshold to 11 rows is the overfit the
aisle test walked into by writing its own positive examples. A second, independent detector does fire: the
Pasta Roni vermicelli "beats" olive oil by 21.8% only because 4.6 WEIGHT ounces were divided as fluid
ounces, and an ACCEPT on a basis-suspect candidate is refused unless overridden on the record.
Also worth knowing before anyone rules: **none of the 11 would take a crown** - every one loses to another
store's floor - so they move the Hy-Vee column, not the cheapest verdict.

**STILL OPEN on F1:** (b) cycle wiring - now unblocked, but it is a network-rotating search at ~598 ms/product
and that is a scheduling decision, deliberately not taken as a side effect of (a); (c) the
prime-batch-headless pageSize 40->90 bump, which is cheap but only helps terms with >40 results (measured:
"baking soda" returns 10 in total, so it is not the lever the plan assumed).
**F2. DONE 2026-08-01 - everyday-mismatch audits both boards.** 2,656 -> 2,971 cells checked; 95
previously-invisible mismatches surfaced on the recipe board; the main-board answer is unchanged at 6.
The stated reason ("16 of 19 pins outside its view") was STALE - pins collapsed 19 -> 1 once
generate-board-overrides stopped minting a pin a same-day pull confirms. The real reason: all 80
recipe-board rows are off the main board, all 80 carry a link, and they price recipe cards and the feed.
**Those 95 findings are now an open backlog** - they belong with F5.

**F3. HALF DONE, half re-scoped.**
- The **window contention** half is ALREADY SHIPPED (verified in source, not assumed): `Has-FeedCoverage`
  in `audit-ff-carry.ps1` applies the rule - a term whose commodity has a priced row in this same pull is
  not a victim - with the 24 -> 9 measurement recorded inline.
- The **freezer-pops term** is NOT a term edit. `commodity-search.json` holds ONE string per commodity and
  the FF puller flattens with `[string]$_.Value`, so an array value silently becomes a single joined
  search instead of two. **23 scripts read that file.** Multi-term support is a 23-consumer shape change
  that also spends FF budget slots every rotation, and the budget is the binding constraint (~85 of 526
  terms bought per run). It is the right fix for a systemic problem - 210 of 429 commodities have an FF
  product name that does not contain our search term at all - but it is a design change, not a one-liner.
**F4. Baseline tolerance narrowing** from the week's accumulated ledger data (the freeze week's whole
point was to let that ledger accumulate).
**F5. ROOT CAUSE FOUND, fix HALF landed. Backlog is 7 rows, not 9.** And `resolve-links-from-board.ps1`
does not exist - like `discover-hyvee.ps1`, the plan named a tool that was never built.

**Why the backlog never drains:** all 7 rows are RECIPE-BOARD cells, and the headless heal loop cannot
reach them. `resolve-worklist.ps1` reads `recipe-board.json`; `resolve-hyvee-links.ps1` read only
`comparison-*.json`. The two halves of the same loop disagreed about which cells exist, so a
recipe-board Hy-Vee cell was structurally unhealable. Proven, not theorised: withdrawing all 7 drifted
links (the documented withdraw-then-resolve loop, which works on main-board cells) brought back ZERO of
the four Hy-Vee ones.

**LANDED (both halves):** `resolve-hyvee-links` resolves against both boards (572 rows, was 492) AND now
takes a third candidate source - the consistency report's `mismatch` list, which is the only one of the
three that can see a cell whose link is PRESENT but WRONG. That is the queue the backlog was always meant
to drain into.

**RESULT, stated honestly: 1 of 4 drained.** parmesan-cheese re-pointed to the correct Hy-Vee Grated
Parmesan 3 oz. **The other three cannot be healed by this resolver at all**, and it is a data shape, not a
queue: `recipe-board.json` store rows carry only `{store, per_unit, type, bulk}` - **no `item`, no `size`**
- so the resolver logs `no size match (ours: / )` and correctly REFUSES rather than guess (that refusal is
the founding minced-garlic fix: board published 32 oz while the link opened 4.5 oz).

**IDENTITY DONE 2026-08-01, AND IT TURNS OUT NOT TO BE THE BINDING CONSTRAINT.** `derive-recipe-floors.ps1`
chose a product to price each cell from and threw its identity away; it now stamps `item` + `size` from the
same candidate it takes the price from, inside the same branch, so the name always describes the number
published beside it. A cell with no candidate keeps its prior identity exactly as it keeps its prior price -
filling in a name from another observation would be the wrong-basis class in a new costume. Measured on the
80 rows that reach the board: item 243 -> 318 of 404 (Hy-Vee 51 -> 64 of 78), size 225 -> 308, and 4 of
guard 3's 10 uncheckable pins gain a name.

**BUT THE THREE UNHEALED Hy-Vee CELLS ARE NOT IDENTITY BUGS, and this was checked cell by cell:**
- `boneless-skinless-chicken-thigh` - **the link is CORRECT** (Tyson 2.5 lb, $9.99 = $3.996/lb). The board's
  $1.99/lb is a frozen 2026-07-12 hand-browsed floor, it **holds the crown**, and it is publishing chicken
  thighs at HALF what Hy-Vee charges. Identity changes nothing here; the row needs a price refresh path.
- `apple` - the row is priced per EACH and the link opens Gala apples per LB. The two bases are not
  comparable, so the "151% off" is an artefact of measuring $/each against $/lb.
- `swiss-cheese` - it HAS a size, and the size is `8 oz (2/$5.00)`: a **promo baked into the size string**,
  which parses to 8 oz against a link that opens 5 oz. A polluted size, not a missing one.

**THE REAL REMAINING FIX, restated: identity is downstream of a REFRESH PATH.** 47 recipe-only ids have no
staples-board twin and no id-map entry, so nothing re-prices them and nothing can honestly name them. The
other candidate pool that covers those ids - the recipe rule set's own
`recipe-sales-candidates-<date>.json` - **is polluted on exactly them and must not be wired in**: measured
2026-08-01, its cheapest everyday `zero-sugar-soda` is **Oreo Zero Sugar COOKIES** at $0.579 and its
`apple` pool is mostly apple JUICE and baby food. Two more live wrong prices found while checking:
`fries` @ Sam's holds the crown at $0.0334/oz against the store's $0.067 (exactly 2x - the monthly -Apply
corrects this one), and `parmesan-cheese` @ Hy-Vee is $0.3744 against a link at $0.7633.
No id-map entries were added: `boneless-skinless-chicken-thigh` -> `chicken-thighs` ("Chicken Thighs /
Drumsticks") is a DIFFERENT FORM, and `zero-sugar-soda` (each) -> `soda` (floz) is a different product and
an unreconcilable unit. Never guess a mapping.

**SEPARATE ISSUE SPOTTED TWICE TODAY:** a full `resolve-hyvee-links` run re-introduces the
poultry-seasoning/Hy-Vee divergence (board 2.7667 vs link 4.7571) and grows the backlog. Its output was
discarded both times. The resolver has a quality problem on that row independent of the queue.

**FOLLOW-UP on that row, 2026-08-01 late: `product-urls.json` currently has NO Hy-Vee entry for
`poultry-seasoning` at all** (only Baker's, Family Fare and Walmart), and none of those three names is the
"Morton & Bassett Poultry Seasoning / 2.1 oz" the 15:59 consistency report attributes to Hy-Vee. So that
report row describes a link that is not in the file, i.e. **the mismatch backlog is probably 7, not 8**,
and the discarded-resolver-output story reads as the link having been withdrawn rather than restored.
Worth one look before anyone works the backlog off that count. `product-urls.json` was verified unchanged
against HEAD at the end of the session, so nothing today moved it.

The withdrawals were REVERTED and `product-urls.json` restored to its committed state: 7 cells with a
tracked drifted link beat 7 cells with no exact link plus a red coverage ratchet. Board verified green.

## Section 3: BLOCKED ON BRAD (decisions, not work)

**D1. DONE 2026-08-01 - the freeze was formally LIFTED** at Brad's direction. Section 2 is open work.
**D2. ~200 captured-but-unused verified Sam's prices** sitting idle (board-data-integrity memo).
**D6. DONE 2026-08-01 - the monthly recipe floor refresh is APPLIED and published.** The 88 deltas over
25% were read rather than waved through, and three were WRONG PRODUCTS: fresh Local Roots thyme priced as
`dried-thyme` at Family Fare (live on the main board at $5.98/oz), a Violi SUNFLOWER/olive blend as
`olive-oil` (second-cheapest on the main board at $0.2068), and canned TUNA packed in olive oil - 8 rows
including StarKist E.V.O.O. - which survived every exclude and was a latent wrong crown. All fixed through
the gated batch and filed in `known-wrong.json`. It also corrected `fries` @ Sam's from $0.0334/oz to the
store's real $0.067, a live wrong crown off by exactly 2x.
Two id-map entries were RETIRED for violating that file's own same-form rule (`golden-raisins` -> `raisins`
priced golden off dark seedless; `hot-italian-sausage` -> `italian-sausage` picked MILD and SWEET). The
right product at a stale price beats the wrong product at a fresh one.
**D3. Elite-layer decisions never answered**: sparkline tease depth, de-Ghost nav (wants a screenshot),
Portal accent pass, photo program cap. Defaults were stated in the design doc; silence = defaults, but
the de-Ghost frame and Portal pass genuinely need your eyes before build.
**D4. Google Ads hygiene**: negative keywords, sitelinks, demote the auto-created Page-views goal.
Fifteen minutes in the Ads UI, real Quality-Score money.
**D5. Half-cent rounding** (banker's vs half-up) - frozen in a fixture, documented, awaiting a call.

## Section 4: CAPTURE SESSIONS (browser work, not code - NOT blocked on Brad; Claude drives his Chrome)

**C1. Rescue worklists** from `out\rescue-terms-*.txt`: Walmart 21, Sam's 25, Fareway 28, Aldi 6 terms
(DEEP per term, per the file header). The Sam's list is what retires the 18-day orphan capture that
guard 9 keeps warning about (60 rows, ~22 live cells, no headless refresh path).
**C2. Aldi tile-reading capture**: the puller reads product pages, which do not carry multipack counts;
the tiles do. Until the capture changes, `audit-unit-basis-outlier` is the defense.
**C3. Aldi/Fareway out-of-band verification cells** (never yet measured).

## Section 5: LATER (valuable, not urgent)

**L1. Identity-lane fine-tune**: train on the ~6,000 adjudicated pairs, build a HARD negative set
(subtle wrongness, not bath soap), re-evaluate behind `-IncludeIdentity`. The lane stays off until it
beats the new eval.
**L2. TESTED AND FAILED 2026-08-01. Do not re-attempt without a better model.** The hypothesis was that a
VLM could read Fareway/Baker's flyer JPGs and give a HEADLESS path to the stores that need capture
sessions (C1-C3). `qwen2.5vl:7b` was run against a real Baker's ad page (`out\bakers\page-01.jpg`):
43 seconds, 12 rows, and **roughly half carried a merge or basis error** - `Powerade | $10` (a MULTI-BUY
flattened into a unit price), `Takis | $7 | ... or Kroger Purified Drinking Water, 24-Pack` (two tiles
merged), a size bled in from the next tile. It reads TEXT fine; it cannot reliably BIND price to product
to size across a dense tile layout, and the multi-buy flattening is the same arithmetic class as the FF
`N for $M` -> `$NM` parser bug. **Unusable as a price source** for a board that promises real numbers, and
"extract then verify by hand" defeats the reason for wanting it. Model removed to reclaim 6 GB; re-pull is
minutes if a better VLM appears. The narrower second-reading-DIFF idea (flag disagreement, never source a
price) survives being wrong half the time in principle, but must beat a simpler check before it is wired
in. Full write-up + the failure mode: the `vlm-flyer-extraction-failed` memory.
**L3. DuckDB cache** for the repeated multi-MB JSON parses; **PS7 consolidated runner** for the watcher
suite's process-spawn overhead. Pure speed, zero user-facing risk. NOT STARTED, and it is last on purpose:
this plan's own ranking puts speed behind accuracy, conversion and robustness, and the measured pipeline is
already fast enough that nobody but the machines notices.
**L4. Recipe cost redesign OPEN**: convert the 113 originals + switch site surfaces/rankings to the
cheapest basis (MUST ship together), specs/prose re-sync, #124 credit retrofit.
**L5. Elite-layer Wave 3 remainder**: OG images, unlock moment, capture after-state, formerly-free
gate + 404, receipt footer, Shop-This-Recipe board side + winning-store feed field.
**L6. R300 leftovers**: proxy item_ids, cassoulet title, canon-rule promotion.
**L7. DONE 2026-08-01.** `price-history.json`, `board.json` and `smp-feed.json` now write through
`[IO.File]::WriteAllText` with a BOM-less encoding and were regenerated; `free-dinners.json` is patched at
the writer and clears on its next daily rotation. Source-scanned in test-auditors rather than file-checked,
because the live files only lose their BOM on the next publish - a file check would fail for a day and then
start passing for the wrong reason.

---

## Where this stands after the 2026-08-01 plan run

**CLOSED: Section 1 (1b, 2b), all of Section 2 (F1 a/b/c, F2, F3, F4, F5), D6, L2, L7.**
Fourteen commits, test-auditors 296 -> 336, guards green, board published clean twice.

**STILL OPEN, and honestly why:**
- **L1 identity-lane fine-tune** - a real ML task (build a HARD negative set from ~6,000 adjudicated pairs,
  train, re-evaluate). It is not a session-tail item, and the lane correctly stays off until it beats the
  new eval. Nothing about it is blocked; it just needs its own run.
- **L4 recipe cost redesign** and **L5 elite-layer Wave 3** - both are large surface changes, and L5
  overlaps D3, which explicitly wants Brad's eyes on the de-Ghost frame and the Portal pass BEFORE build.
- **L6 R300 leftovers** - proxy item_ids, the cassoulet title call, canon-rule promotion.
- **L3** - deliberately last, see above.
- **Section 3 D2/D3/D4/D5** - these are decisions, not work. D4 in particular is Brad in the Ads UI.
- **Section 4 C1-C3 capture sessions** - browser work against walled stores. C1 is what finally retires
  the 18-day Sam's orphan capture that guard 9 warns about on every run.

## Ranking rationale

Shopper-facing accuracy first (S1 items), because the product's one promise is that the numbers are
real. Conversion second. Robustness third. Speed last, because the measured pipeline is already fast
enough that nobody but the machines notices.
