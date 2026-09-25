# MEASURE: what a pattern-keyed known-wrong ruling would block (2026-09-25)

Brad's ruling on Q1-shape-scoped-rulings (`grocery/triage-plans/plan-2026-09-20-4.json`), 2026-09-25:
"Measure first, then decide (Recommended)". This is that measurement. It changes no ruling, no rule and no board.

**Harness and commit.** grocery/probe-known-wrong-patterns.ps1, run 2026-09-25 from a worktree based on origin/main at commit 39e16c00c (blobs under Harness and inputs below).

## Summary for Brad

- **The question.** A known-wrong ruling blocks one product name at one store for one commodity. Should it also
  carry a pattern, so the next size or flavour of an already-ruled product is blocked without a new ruling?
- **I tried three ways of turning each ruling into a pattern**: ignore size and pack count (D1), also ignore
  flavour and scent words (D2), or match on the first three words of the name (D3, the "shape" add-known-wrong
  already uses). I ran all three over every one of the 333 active rulings against every product we have captured
  (54,923 store and product pairs, from 428 capture files and 31 boards, 2026-07-05 to 2026-09-25).
- **How many rulings would block extra products:** 7 of 333 (D1), 9 of 333 (D2), 70 of 333 (D3).
- **How many extra products in total** (distinct, in the ruling's own commodity and store): 10 (D1), 12 (D2), 169 (D3).
- **How many of those anyone ever ruled wrong:** 0 of 10, 0 of 12, 10 of 169. Everything else is a product nobody
  judged wrong. Strictly **no record at all** of anyone looking: 1 of 10, 1 of 12, 14 of 169. The rest are only
  mentioned in a triage plan, often as the RIGHT product: the Great Value 12.5 oz can is named because the pack
  ruling beside it used it as the fair price, not because anyone judged it wrong.
- **It would take real prices off today's board:** 1 published cell (D1 and D2: the Great Value 12.5 oz canned
  chicken at Walmart) and 16 published cells (D3, among them Heritage Farm boneless skinless chicken breasts at
  Baker's, 93/7 ground beef at Walmart, Great Value tilapia and cod at Walmart).
- **The three 2026-09-20 re-pages:**
  - The two Ben's Original Ready Rice flavours (cilantro lime, roasted chicken) would have been one ruling under D2
    or D3; D1 keeps them apart. Today neither needs it: the flavoured-rice exclude on cooked-jasmine-rice (your
    ruling B, 2026-09-22) already keeps every flavoured Ben's pouch off that commodity, so the Ben's pattern blocks
    0 extra rows in scope.
  - The Stayfree SKU is not covered by any derivation, because it was never a wrong product: no ruling names Stayfree,
    and the triage lane judged the Stayfree Classic pads a real feminine-pads product the include was too narrow to
    see. A known-wrong pattern cannot fix a rule that is too narrow.
- **Verdict against the bars written before the run:** none of the three passes. All three block products nobody
  ruled wrong and take a published cell off the board. This supports the ruling already standing (B, 2026-09-22): a
  recurring wrong shape goes to the commodity's exclude, measured by apply-coverage-batch, and known-wrong stays one
  exact name.

## The bars, written before the first run

From the harness header, committed with it:

- **BAR-SAFE**: a derivation is fit to key a ruling only if, over all active rulings, it blocks 0 in-scope extra rows
  that no record shows anyone reviewed, AND 0 extra rows that are a published cell of the ruling's own commodity and
  store on the newest board and are not already ruled in that scope.
- **BAR-VALUE**: it covers at least 2 of the 3 motivating 2026-09-20 re-pages. A Ben's SKU is covered when the other
  Ben's ruling's pattern matches it; a Stayfree SKU when any active ruling at its store, in scope, matches it.

| Derivation | Rulings blocking extra (of 333) | Extra rows, distinct | Ruled wrong in scope | No record at all | Published on 2026-09-23 board, unruled | Motivating covered (of 3) | BAR-SAFE | BAR-VALUE |
|---|---|---|---|---|---|---|---|---|
| D1 size-count | 7 | 10 | 0 | 1 | 1 | 0 | fail | fail |
| D2 flavour | 9 | 12 | 0 | 1 | 1 | 2 | fail | pass |
| D3 shape | 70 | 169 | 10 | 14 | 16 | 2 | fail | pass |

Every number above is derived from the rows file (below), never typed. Sum of per-ruling extra rows before de-duplication:
10, 12 and 206. Store-wide name matches under any commodity (an upper bound, not listed): 20, 79 and 1,937.

**A caveat on BAR-VALUE**: "2 of 3" counts both Ben's SKUs because each ruling's pattern covers the other. Both
paged for the first time on the same day from one sweep, so a pattern could have saved at most one of those two pages.
The third Ben's flavour in the Baker's captures, Butter and Garlic Flavored, is on the same D2 key and would have been
pre-empted, but it is out of scope today for the same exclude reason.

## Method

- **Rulings**: `grocery/known-wrong.json`, 347 entries, 14 reversed, 333 active. Totals are over the active ones; the
  reversed ones are in the rows file with `active: false`.
- **Today's enforcement (D0)**: `Test-KnownWrong` in `grocery/known-wrong-lib.ps1`, which compare-deals runs on every
  build: the row's KwNorm form or its KwCore form (trailing size clause stripped) equals the norm or core of a ruled
  name. An extra row is one a derivation matches and D0 does not. So D0 already folds a new trailing size; the
  derivations measure what goes beyond it.
- **The three derivations** (full definition in the harness header):
  - D1: KwNorm tokens with every number run that is followed by a unit token removed with those units, joined size
    tokens ("32oz") removed, and a bare trailing number removed. Other numbers stay, so 73/27 and 93/7 beef differ.
  - D2: D1, then a 99-word flavour, scent and variant lexicon removed (in the summary file). The lexicon is a
    hard-coded list, and needing one is itself a cost of this design.
  - D3: the first three KwNorm tokens, the shape `Get-KwShape` in add-known-wrong.ps1 uses.
  A candidate matches when it is at the ruling's store and its key equals the key of one of the ruling's names.
- **In scope**: at the ruling's store, and either the current commodities.json rules (first-match-wins include, then
  exclude, the semantics audit-semantic-identity uses) send it to the ruling's commodity, or it sat in that
  commodity's cell at that store on any of the 31 dated boards.
- **Reviewed**: the product's normalised name, bounded by spaces, inside any normalised string of known-wrong.json
  (same scope, reversed same scope, elsewhere), match-verdicts.json, discovery-verdicts.json, verdict-suppressions.json,
  coverage-gap-allowlist.json, multipack-allowlist.json, the 79 triage-plans/*.json, or a snapshot of the gitignored
  triage queue. A mention counts as a look, which OVERSTATES review (see the summary); a review that used a shorter
  spelling is missed, which UNDERSTATES it.
- **Corpus**: every `deals[]` row of `grocery/out/regular/*-regular-*.json` (Aldi 35 files, Baker's 70, Family Fare 70,
  Fareway 45, Hy-Vee 72, Walmart 42, Sam's 2, and the seven 2026-08-16 hunter files), `ads-*.json` (17, 2026-08-26 to
  2026-09-23), `sams/sams-deals-*` (42, 2026-07-05 to 2026-09-25), `fareway/fareway-deals-*` (11), `bakers/bakers-deals-*`
  (10) and `out/*-deals-*` (5), plus every store cell of the 31 dated boards `comparison-2026-08-11.json` to
  `comparison-2026-09-23.json`. The worktree was seeded with `ops/seed-worktree.ps1 -Target <worktree>` first
  (exit 0: 38 seed paths, 37 already present, 1 copied, 0 refreshed); it was not blind. 0 capture files failed to parse.
  All 333 active rulings' stores have corpus rows; 303 of 333 rulings' own names are found in the corpus by D0.

## What the extra rows are

**D1 and D2 mostly hit PACK and BASIS rulings, where the product is right and one listing's arithmetic was wrong.**
D1's 7 rulings are 4 wrong-basis and 3 wrong-product; D2's 9 are 5 wrong-basis, 3 wrong-product and 1 out-of-scope
variant. Ignoring pack counts turns "the (8 pack) listing multiplied two counts" into "no Great Value chunk chicken
at Walmart", which blocks the correctly priced single 12.5 oz can that is the published canned-chicken cell. The same
shape: the Kleenex 32-pack rulings would block the 8-pack, and the Manischewitz 12-pack ruling would block the single
12 oz bag (the one extra with no record at all is its 2-pack). The one extra that is genuinely another wrong product
is a 4-pack of the Simply Asia five-spice stir-fry sauce.

**D3 hits product lines.** The 16 published cells it would remove, each blocked by a ruling on a different product
that shares three words with it:

| Commodity, store | Ruling's shape (verdict) | Published product it would block |
|---|---|---|
| ground-beef-8020, Baker's | kroger 80 20 (out-of-scope-variant) | Kroger 80/20 Ground Beef Roll 3 LB |
| cranberry-juice, Hy-Vee | old orchard healthy (wrong-product) | Old Orchard Healthy Balance Diet Cranberry Juice Cocktail |
| chicken-breast, Baker's | heritage farm boneless (out-of-scope-variant) | Heritage Farm Boneless Skinless Chicken Breasts |
| almond-milk, Baker's | simple truth dairy (out-of-scope-variant) | Simple Truth Dairy Free Unsweetened Vanilla Almond Milk Half Gallon |
| air-freshener, Sam's Club | febreze air mist (wrong-basis) | Febreze Air Mist, Fall Mixed Scent, 4ct., 32.4 oz. |
| breakfast-sandwiches, Family Fare | jimmy dean biscuit (wrong-product) | Jimmy Dean Biscuit Breakfast Sandwiches, 8 Ct |
| ground-beef-93-7, Walmart | 93 lean 7 (wrong-product) | 93% Lean / 7% Fat Lean Ground Beef, 3 lb Roll |
| ranch-seasoning-mix, Walmart | great value classic (wrong-product) | Great Value Classic Ranch Salad Dressing & Recipe Mix, 4 Count |
| tilapia, Walmart | great value frozen (wrong-product) | Great Value Frozen Tilapia Fillets, 4 lb |
| chicken-thighs, Baker's | heritage farm bone (wrong-product) | Heritage Farm Bone In Skin On Chicken Thighs |
| ground-beef-8020, Walmart | 80 lean 20 (wrong-product) | 80% Lean / 20% Fat Ground Beef Chuck, 10 lb Roll |
| cod, Walmart | great value wild (wrong-product) | Great Value Wild Caught Skinless Cod Fillets, 2 lb |
| hummus, Walmart | marketside gluten free (wrong-product) | Marketside Gluten-Free Classic Hummus 10 oz |
| pork-tenderloin, Walmart | prairie fresh natural (wrong-product) | Prairie Fresh Natural Pork Tenderloin |
| pork-shoulder, Walmart | prairie fresh natural (different-product) | Prairie Fresh Natural Pork Shoulder Butt Roast |
| ready-to-serve-long-grain-wild-rice-pouch, Walmart | great value ready (wrong-product) | Great Value Ready-to-Heat Long Grain & Wild Rice Pouch |

The 10 D3 extras a person already ruled wrong in the same scope are the pattern agreeing with a person: Savoritz
protein cracker flavours (Aldi), Kleenex and Great Value chicken pack listings and Knorr vegetable base spellings
(Walmart), a strawberry mixer (Fareway), and a bulk bay-leaf listing (Walmart). The 14 with no record at all include
more Bush's 6-pack chili bean cases, Frontier Co-op curry powder and oregano, two Not Your Mother's conditioners, and
Kroger 80/20 ground beef.

**Store scope is what keeps D3 from the Ben's crowns.** The Ben's D3 shape "bens original ready" is the first three
words of the published Ben's Jasmine cells at Family Fare and Sam's Club. The two Ben's rulings are Baker's-only, so
those cells are out of their scope; a Ben's flavour ruled at Family Fare would take the Family Fare jasmine cell off
the board under D3.

## What this does not measure

- A pattern exists to block SKUs that have not been listed yet. No corpus can count those, so every number here is a
  floor on what a pattern would block over time, never a ceiling.
- The in-scope test uses the regex engine semantics of audit-semantic-identity, not the full compare-deals matcher.
- "Reviewed" is a text match over ledgers and plans. The summary separates "ruled wrong" (a known-wrong row in the same
  scope, which is an adjudication) from "mentioned", which is not.
- Three runs: run 1 died at the totals (Measure-Object cannot read an ordered dictionary's keys) before writing
  anything; run 2 wrote the rows with every input blob empty (a PS 5.1 pipe put a BOM on the first path given to
  `git hash-object --stdin-paths`); run 3 is this file, with paths passed as arguments, and its totals are identical
  to run 2's. The derivations, the lexicon and the bars were not changed between runs, and no other variant was tried.

## Harness and inputs

- Harness: `grocery/probe-known-wrong-patterns.ps1`. The run was at working-copy blob `5a7eaa4344dd1565959fa7d2552b0036d530fced`; the committed blob `c9e1715dbc93e22771808cf2fa04b85257e7541c` differs only by one explicit dot-source of `lib/json-io.ps1`, which `known-wrong-lib.ps1` already loads (the pre-commit dependency check asked for it to be visible), and its `-SelfTest` passed again at that blob. Its `-SelfTest`
  (14 cases, exit 0) freezes the derivations and the review search. Run from a worktree based on origin/main at
  `39e16c00c`, in 1,461.6 s:
  `powershell -NoProfile -File grocery\probe-known-wrong-patterns.ps1 -TriageQueue <snapshot of grocery\triage-queue.json>`
  Last line: `PROBE-KNOWN-WRONG-PATTERNS-COMPLETE rulings=347 rows=1041 corpus=54923 boards=31 captures=428 inputs=546 unhashed=0 fingerprint=c2c6cd3427b3`.
- Normaliser: `grocery/known-wrong-lib.ps1`, blob `357a97050cb2ef749acf6a043fffe0c1ac50237e`.
- Tracked inputs: `grocery/known-wrong.json` `4542d96e5111f9ff22af6b58a443572874b6aa2c`, `grocery/commodities.json`
  `a0c290317a41306055a5701f7d81581f2aad5275`, `grocery/match-verdicts.json` `60c543413ee88f213216fe95900751343680dc57`,
  `grocery/discovery-verdicts.json` `bed50f737a45d855d84dd255c8ec10a617c3c669`, `grocery/verdict-suppressions.json`
  `740f752b459ced36172612510d1d2aae09346571`, `grocery/coverage-gap-allowlist.json` `31dd2c6990a3185ef31b11bdd93f36f97b823669`,
  `grocery/multipack-allowlist.json` `e95aa9640ab2692fca53688900981bc293874673`. Triage queue snapshot
  `c47349e0f08ff3b22755d38f5b875bb35e205826` (copied from the main checkout at 12:57; gitignored).
- Every one of the 546 files read, gitignored boards and captures included, is listed with its blob in
  `design/MEASURE-known-wrong-pattern-rulings-2026-09-25.summary.json`; the SHA-256 over that list is
  `c2c6cd3427b3b7dbcf9a19c6f97572be4ba199074c478777672b6e8284706863`.
- One row per ruling per derivation (347 x 3 = 1,041 rows), each extra row listed with its board and review evidence:
  `design/MEASURE-known-wrong-pattern-rulings-2026-09-25.rows.jsonl`.

## Knowledge consulted

- `.claude/rules/grocery.md`: "A wrong product is a SELLER SHAPE, not a brand" and "known-wrong.json is the MAIN-board
  corrector".
- `.claude/rules/measurement.md`: bar before the run, one row per case per arm, commit the harness, cite blobs.
- memory `ruling-recurring-shape-is-an-exclude`: Brad's ruling B of 2026-09-22 (queue 2026-09-21-7d64a6) on this
  same question id, implemented in `grocery/add-known-wrong.ps1` (Get-KwShape, second ruling of a shape refused) and the
  cooked-jasmine-rice `\bflavou?red\b` exclude (plan-2026-09-22-5.json). This measurement leaves both untouched.
