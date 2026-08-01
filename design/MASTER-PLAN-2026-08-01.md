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
| Suites | test-auditors 282 green; guards green on the 2026-08-01 board |

Mid-verification, guards went genuinely red: today's fresh ad pull moved three cells off their stored
links (a store-brand enchilada sauce displacing Old El Paso, a halved cumin shelf price, a tartar-sauce
repricing). That was REAL and FRESH, not a regression from the day's work, and it was healed through the
sanctioned path (`check-ad-cycles` auto-repair re-pointed the links headlessly, re-guarded, republished:
the live board now serves week 2026-08-01 clean). The lesson stands: a verification pass that finds a
red gate should reach for the estate's own orchestrator before reaching for hand surgery.

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

**F1. Discovery depth**: `discover-hyvee.ps1` + prime-batch-headless pageSize 40->90 + cycle wiring.
The dominant defect class is ABSENT catalogue (Hy-Vee misses 89.3%). **The aisle-test prerequisite is now
MET (item 2), so this is unblocked.** CORRECTION to the earlier note that it was "built and verified":
`discover-hyvee.ps1` does NOT exist in the repo - a file search on 2026-08-01 found no `discover-*.ps1`
at all. It needs building, not applying. Budget it as a real piece of work, and run the aisle test over
its candidate flips before any of them reach a board.
**F2. everyday-mismatch reads BOTH boards** (16 of 19 pins sit outside its view today).
**F3. ff-carry window contention + the freezer-pops term.**
**F4. Baseline tolerance narrowing** from the week's accumulated ledger data (the freeze week's whole
point was to let that ledger accumulate).
**F5. The 9-row consistency mismatch backlog** (stored links whose price drifted >30%): re-point or
refresh through resolve-links-from-board.

## Section 3: BLOCKED ON BRAD (decisions, not work)

**D1. DONE 2026-08-01 - the freeze was formally LIFTED** at Brad's direction. Section 2 is open work.
**D2. ~200 captured-but-unused verified Sam's prices** sitting idle (board-data-integrity memo).
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
**L2. VLM flyer extraction** (qwen2.5vl:7b is pulled and ready): Fareway/Baker's flyer JPGs as a
headless pipeline step behind the existing import gates; screenshot second-reading diff for walled
stores.
**L3. DuckDB cache** for the repeated multi-MB JSON parses; **PS7 consolidated runner** for the watcher
suite's process-spawn overhead. Pure speed, zero user-facing risk.
**L4. Recipe cost redesign OPEN**: convert the 113 originals + switch site surfaces/rankings to the
cheapest basis (MUST ship together), specs/prose re-sync, #124 credit retrofit.
**L5. Elite-layer Wave 3 remainder**: OG images, unlock moment, capture after-state, formerly-free
gate + 404, receipt footer, Shop-This-Recipe board side + winning-store feed field.
**L6. R300 leftovers**: proxy item_ids, cassoulet title, canon-rule promotion.
**L7. BOM hygiene on public feeds**: browsers strip it per spec so nothing is broken, but PS 5.1's own
ConvertFrom-Json chokes on our own files, which is how today's false alarm happened. Write public
feeds BOM-less when convenient.

## Ranking rationale

Shopper-facing accuracy first (S1 items), because the product's one promise is that the numbers are
real. Conversion second. Robustness third. Speed last, because the measured pipeline is already fast
enough that nobody but the machines notices.
