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
| Suites | guards + test-auditors (282) green as of this pass |

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

**1. Work the 45-commodity coverage backlog** from `grocery\out\semantic-findings.json`, using the
procedure below. This is shopper-facing accuracy: 89 real products invisible to the rules, including
Libby's canned pumpkin. THE PROCEDURE, learned from the `cheese,\s+shredded` regression:

- Batches of ~8 commodities, ONE commit each.
- Per batch: edit `commodities.json` -> `compare-deals` -> **crown-diff AND tile-integrity AND
  audit-known-wrong** (the cheese lesson: crown-diff alone said "0 changed" and looked clean while
  tile-integrity caught the collision) -> guards -> publish only on all-green.
- A pattern that adds zero coverage gets REVERTED, not kept ("bought nothing, broke something").
- Re-run the semantic sweep after each batch; the findings list shrinks as rules widen, which is the
  progress meter.
- Skip anything ambiguous (a "Pumpkin Pie" under pie-pumpkins is a judgment call): leave it in the
  findings file with a note rather than forcing a rule.

**2. The Family Fare aisle test, built on `/rank-commodity`.** Resume-list item 2, and the sidecar was
built partly to unblock it: score every FF catalogue product against its would-be commodity BEFORE
letting depth flip crowns (the browse test flipped 26, two-thirds wrongly). Deliverable: a gate script
that takes a candidate crown flip and returns match confidence. This is the prerequisite for item F1.

**3. Schedule the semantic sweep nightly** once the backlog from item 1 is worked, so it reports only
what is NEW. Wire as an advisory line in check-ad-cycles, BLIND-not-block (the plumbing already
behaves that way; this is one call-site addition).

## Section 2: FREEZE-GATED (grocery code, ~08-07 or Brad's word)

**F1. Discovery depth**: `discover-hyvee.ps1` + prime-batch-headless pageSize 40->90 + cycle wiring.
Built and verified per the resume list; the dominant defect class is ABSENT catalogue (Hy-Vee misses
89.3%). Ships only behind the aisle test (item 2 above).
**F2. everyday-mismatch reads BOTH boards** (16 of 19 pins sit outside its view today).
**F3. ff-carry window contention + the freezer-pops term.**
**F4. Baseline tolerance narrowing** from the week's accumulated ledger data (the freeze week's whole
point was to let that ledger accumulate).
**F5. The 9-row consistency mismatch backlog** (stored links whose price drifted >30%): re-point or
refresh through resolve-links-from-board.

## Section 3: BLOCKED ON BRAD (decisions, not work)

**D1. The freeze itself** (see Section 0).
**D2. ~200 captured-but-unused verified Sam's prices** sitting idle (board-data-integrity memo).
**D3. Elite-layer decisions never answered**: sparkline tease depth, de-Ghost nav (wants a screenshot),
Portal accent pass, photo program cap. Defaults were stated in the design doc; silence = defaults, but
the de-Ghost frame and Portal pass genuinely need your eyes before build.
**D4. Google Ads hygiene**: negative keywords, sitelinks, demote the auto-created Page-views goal.
Fifteen minutes in the Ads UI, real Quality-Score money.
**D5. Half-cent rounding** (banker's vs half-up) - frozen in a fixture, documented, awaiting a call.

## Section 4: BLOCKED ON CAPTURE SESSIONS (browser work, not code)

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
