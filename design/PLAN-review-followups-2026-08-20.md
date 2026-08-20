# PLAN — Review follow-ups: absorb the aliases, adjudicate the contested set, repair the gold seams

**Status: NOT STARTED. This document is the spec — build from it, not from memory of it.**
Written 2026-08-20, immediately after the confirm-match review lane shipped
(commit `bced1561`). Assumes that commit's state: 3,658 rows `llm_confirmed`,
missed-merge red at 0.5831, 116 alias proposals filed at `proposed`, 205
contested questions untouched, 18 deferrals queued with written reasons.

Six work items, ordered by dependency and payoff. Items 1–3 move gates; items
4–6 are seam repairs. They are separable — each item leaves the estate
consistent if the session stops after it — but the ORDER matters (§8).

---

## 0. Ground rules binding every item

- **Interpreter**: `C:\Codex\Python312\python.exe`. Bare `python` is the
  Windows Store shim and exits 49 without running anything.
- **Single writer**: never run any of this while a resolve run or another
  session writes `graph/sqlite/graph.db`. Check for live python processes and
  a growing `graph/provenance/run_resolve_*.jsonl` first.
- **The bias**: prefer a missed merge over a false one, in every judgement
  call below. A wrong include-alias or a wrong contested CONFIRM publishes a
  wrong price; a wrong reject costs one empty cell.
- **Nothing here bypasses a gate.** Every DB write goes through the existing
  provenanced paths (`record_provenance`, `log_event`, the stage-2 shadow
  apply). No new direct writes to `aliases`, `gold.jsonl` content rules, or
  `match_status` outside the two review lanes.
- **After ANY ingest that can create priceable rows, run
  `graph/pipeline/flag_outliers.py`** before reading parity (see item 6,
  which makes this structural).
- Re-run the gate chain (`score.py`, `verifier.py`, `board_parity.py`) after
  each item that touches row statuses or aliases; record the run with a
  distinct `--context`. Update the README gate table once at the end.
- Commit and push when the whole plan (or an agreed prefix of it) is done —
  standing rule, no asking.

---

## 1. Alias absorption — the lane that turns the missed-merge gate green on merit

**Problem.** 116 `add_alias` proposals sit at `proposed` (model =
`claude-fable-5`, in `learning_proposals`). Until they are applied, 517 gold
MATCH cases score as missed merges (rate 0.5831 vs gate ≤0.10). They must NOT
be bulk-applied: the shadow gate passes them circularly (each alias was derived
from the very gold case it would be scored against), and several are known
over-broad (`\bangel\s+hair\b` also matches "Angel Hair Coleslaw";
`\bfridge\s+pack\b.{0,15}cans` also matches beer fridge packs).

**Design: make the shadow gate non-circular by adding evidence it does not
currently have — a corpus blast-radius report — then review with that evidence
in hand, then apply through the EXISTING stage-2 machinery unchanged.**

### 1a. Blast-radius enrichment (new code)

New module `graph/learning/alias_blast_radius.py` with one public function and
a CLI:

```
python graph/learning/alias_blast_radius.py            # report for all proposed add_alias
python graph/learning/alias_blast_radius.py --proposal lp:xxxx
```

For each `add_alias` proposal (status `proposed`), compile the pattern
(IGNORECASE; a pattern that fails to compile is itself a finding) and sweep it
over **every DISTINCT `product_name` in `price_observations`** (~30k distinct
strings; this is seconds, not minutes). Classify each hit:

| bucket | meaning | signal |
|---|---|---|
| `already_matched` | name already resolves to this commodity (include_hit / llm_confirmed) | neutral — the alias is redundant for it |
| `intended_capture` | name currently `llm_rejected`/`no_include_hit`-class for THIS commodity... i.e. rows of this commodity the alias would newly settle | the point of the alias |
| `cross_commodity` | name currently priced (include_hit/llm_confirmed) under a DIFFERENT commodity | **danger** — the alias would let this commodity claim another cell's product |
| `known_wrong_hit` | name appears in any commodity's known-wrong set, or matches a gold NO_MATCH case (any commodity) | **kill** — the alias contradicts an adjudication |
| `rejected_hit` | name was reviewer-REJECTED or llm_rejected **for this commodity** | **kill** — the alias would resurrect a rejected candidate at layer 4, which OUTRANKS the model's rejection |

`rejected_hit` deserves emphasis: layer 4 (include) fires before layer 5 ever
ran, and a re-import + re-resolve would let an alias match a name the review
explicitly rejected. Any alias with ≥1 `known_wrong_hit` or `rejected_hit` is
an automatic REJECT in the packet; any with `cross_commodity` hits is
default-REJECT unless the reviewer writes why the collision is benign
(recipe-vs-staple namespace twins are the one expected benign class).

Output: `graph/learning/alias-blast-radius.json` (gitignored is fine — it is
derived), keyed by proposal id, listing bucket counts and up to 20 example
names per bucket. Also write one `decision_log` row (etype
`learning_proposal`, decision `blast_radius`) per run with the summary counts.

### 1b. Feed the report into the EXISTING stage-2 packet

Modify `graph/learning/stage2_review.py::emit_packet` only: when a proposal is
`add_alias` and a blast-radius file exists, attach its bucket summary + kill
flags to that proposal's packet entry. No other packet change. The stage-2
verdict vocabulary (accept/reject/modify/defer/hold_for_human) is unchanged;
`modify` is the expected verdict for patterns that need tightening (the
reviewer supplies the corrected payload).

### 1c. Review + apply (session work, not new code)

Run the normal chain: `--emit-packet` → review every one of the 116 with the
blast radius in view → `--ingest` → `--apply`. The shadow gate now means
something: the 378 gold NO_MATCH cases are a genuine (non-circular) false-merge
tripwire, the blast radius covers what gold cannot see, and gold-coverage
holds (`held_for_human` for commodities with no gold coverage) still apply.
Expect several `modify` verdicts and a handful of rejects.

**Expected gate movement:** missed-merge falls from 0.5831 toward the gate as
aliases land; it will NOT reach 0 because some confirmed matches are
deliberately not alias-able (truncated feed garbage like `Shredded Chees`
got narrow aliases; one-off titles may be left to the model). If, after all
appliable aliases land, the rate is still >0.10, record the residual honestly
in the README (per-source table, same as now) — do NOT loosen patterns to
chase the number.

**Done means:** zero `add_alias` proposals left at `proposed`; every verdict
has a rationale; `--apply` ran; score re-run recorded; no false-merge
regression (must stay 0.0000).

---

## 2. The contested-adjudication lane — 205 questions nobody can currently rule

**Problem.** 829 rows / 205 distinct questions sit at `match_status='escalated'`
(model said UNSURE or low-confidence). The confirm-match lane deliberately
cannot touch them: its `--emit-packet` filters `kind == 'confirm_match'` and
its `--ingest` updates only `llm_match_unverified` rows. These questions need
adjudication FROM SCRATCH, not confirmation of a lead.

**Design: extend `review_escalations.py` rather than build a sibling module.**
The machinery (enrichment, ingest invariants, gold write-through, queue
bookkeeping, provenance) is identical; only selection and the row-status
transition differ. A second module would duplicate all the invariants and
drift.

### Changes to `graph/pipeline/review_escalations.py`

1. `--emit-packet` gains `--kind {confirm_match,contested}` (default
   `confirm_match`, so existing behavior is untouched). With
   `--kind contested`:
   - queue entries with `kind == 'contested'` are selected;
   - the orphan sweep targets `match_status='escalated'` rows (same
     interrupted-run gap exists for them — verify by count before assuming);
   - each packet question carries the model's UNSURE/low-conf reason verbatim
     and is labelled `"adjudicate_from_scratch": true` so the reviewer knows
     there is no lead to confirm;
   - `PROMPT_VERSION` stays `review-v1` (the rubric is identical); record
     the kind in every decision-log detail instead.
2. `--ingest` verdict handling gains awareness of the source status: for each
   CONFIRM/REJECT, the UPDATE's status predicate becomes
   `match_status IN ('llm_match_unverified','escalated')` **scoped by what the
   verdict file declares** — concretely, each verdict object gains an optional
   `"from_status"` field written by the packet (default
   `llm_match_unverified` for back-compat). Refuse-don't-clobber semantics
   unchanged: 0 rows updated → refused.
   - CONFIRM → `llm_confirmed` (reviewer-confirmed is reviewer-confirmed,
     regardless of how the question arrived — schema.md already defines it so).
   - REJECT → `llm_rejected`.
   - DEFER → stays `escalated`, queue entry annotated, exactly as today.
3. Gold cases, alias proposals, known-wrong command emission, decision-log
   rows: identical code path, no changes.
4. `--status` reports the two kinds separately (it already counts them).

**Review guidance for the session that runs it** (put in the packet
instructions): these are the questions the model could NOT lean either way on,
so expect a higher DEFER rate than the confirm lane's 3%; that is correct
behavior, not failure. Batch ~50, biggest `rows_live` first, external
verification for anything brand/format-ambiguous (the K-Cup lesson).

**Done means:** zero `contested` entries without a verdict or a written
deferred_reason; `flag_outliers.py` re-run; gates re-run; README's "contested
set" paragraph updated with the outcome.

---

## 3. Deferral resolution — the store-page evidence pass

**Problem.** 18 deferred questions (175 rows) wait on evidence a title cannot
give: the `1 Lb / 2 Lb` bean listings (can vs dry bag), Welch's Fruit 'N
Yogurt shelf category, Johnson's 25-ct wipes, Gourmet Garden "lightly dried"
herbs, `Great Value Sweet Peas 26 oz` (frozen vs canned), the ALDI brioche
buns, Clancy's Spicy Margarita chips, Planters items, etc. Item 2 will add
more.

**Design: no new lane — one emit filter plus a browser session protocol.**

1. `--emit-packet` gains `--deferred-only`: emits ONLY entries carrying a
   `deferred_reason`, and for each includes the store (from the observation),
   the deferred_reason verbatim, and a `store_page_hint` — the estate already
   has per-store product-URL conventions in `grocery/product-urls.json`; if a
   URL exists for the commodity+store, include it. This composes with
   `--kind`.
2. Session protocol (document in the module docstring, since the design docs
   are the spec of record): a session WITH browser access fetches each store
   page (Family Fare/Aldi product pages are client-rendered — use the browser,
   not WebFetch; see the Fareway capture-defects memory for the lazy-load
   trap), records what the page shows (aisle, unit, ingredient panel) INTO the
   verdict's evidence field, and ingests through the normal `--ingest`. A
   DEFER may be re-deferred only with a NEW reason stating what was tried.
3. No schema change. The deferral's lifecycle already round-trips.

**Done means:** every current deferral either ruled with page-cited evidence
or re-deferred with a reason naming what the page failed to show. Queue's
deferred count reported in the final summary.

---

## 4. Gold seam repair — the 27 silently-skipped cases

**Problem.** 27 gold cases (all `product-urls.json`, all legacy recipe-flavored
slugs: `penne-pasta`, `jasmine-rice`, `93-7-ground-beef`, `cheddar-cheese`,
`beef-chuck-roast`, ...) resolve to no commodity node in either namespace.
`score.py` counts them `missing_node` and silently skips — the gold set is ~2%
smaller than it claims, and nobody is alerted.

**Design: resolve at SEED time, not score time, and fail loudly.**

1. In `seed_gold.py`, add a resolution step mirroring
   `stage2_review.resolve_target`'s ladder, extended one rung: exact node id →
   `commodity:staple:<slug>` → `commodity:recipe:<slug>` → **IngredientMapping
   traversal** (the graph has 308 IngredientMapping nodes with `maps_to`
   edges — if the legacy slug is an ingredient-mapping id or label, follow
   `maps_to` to the commodity) → case-insensitive canonical-label match.
   Resolution requires the DB, so seeding gets an optional `--db` mode; when
   the DB is absent (rebuild drill), seed exactly as today and skip the check.
2. Cases that still fail resolve are written to the seeder's stdout as a
   BLOCK-CAPITALS warning with a count, and stamped `"unresolved": true` in
   gold.jsonl. `score.py` continues to skip them but prints the count with the
   same warning tone (it already reports `missing_node`; make the number
   impossible to miss rather than changing semantics).
3. Do NOT auto-rename `commodity` slugs in product-urls.json — that file is
   legacy-estate-owned. The mapping lives in the seeder only.
4. Whatever remains unresolved after the IngredientMapping rung is a REAL
   catalog question (is `hot-honey` a commodity this board prices?). Emit the
   residual list into the final report for a human/commodity-registrar
   decision — minting new commodity ids is the commodity-registrar agent's
   jurisdiction, not this plan's.

**Done means:** `missing_node` at score time drops to only genuinely
unmapped items, each of which appears in a human-facing residual list.

---

## 5. The four stuck patches — re-review, never silently apply

**Problem.** Four `approved_patches` (verdict accept, `applied_at IS NULL`,
`shadow_verdict='not_run'`) carry unresolvable legacy targets
(`black-pepper-ground`, `brown-gravy-mix-dry-packet`, `dish-soap-liquid`,
`canned-diced-tomatoes`). They loop forever in `--apply` as "left retryable".
One payload is outright wrong: the literal string
`Dawn Heavy Duty Dish Spray 16 Fl Oz` as a dish-soap include alias (that
product is a spray cleaner, and a literal product title is not a pattern).
Danger: item 1's or item 4's target-resolution improvements could make these
suddenly resolvable — and then they APPLY, pre-approved, with no fresh eyes.

**Design: a maintenance verb that demotes, not promotes.**

1. `stage2_review.py` gains `--requeue-stuck`: select exactly this state
   (accepted/modified, never applied, shadow not_run, target unresolvable at
   the CURRENT resolution ladder), flip the proposal back to `status='proposed'`,
   mark the patch row `shadow_verdict='requeued'` (new enum value — document in
   schema.md's decision-log/learning section), and log one decision_log row per
   patch (etype `learning_approval`, decision `requeued_stuck`, detail naming
   the old verdict and why).
2. **Ordering constraint (hard):** run `--requeue-stuck` BEFORE any change
   that improves `resolve_target` (item 4's seeder ladder is separate code,
   but if `resolve_target` itself is touched for item 1's tooling, requeue
   first). The invariant to preserve: *a patch approved under one resolution
   regime never applies under a different one without re-review.*
3. The four requeued proposals then flow through item 1's blast-radius +
   stage-2 review like everything else. Expected outcome: the Dawn literal is
   rejected there; the other three get proper targets/payloads via `modify`.

**Done means:** zero patches in the stuck state; the four visible in the next
stage-2 packet; invariant above stated in stage2_review.py's docstring.

---

## 6. Make the basis guard structural, not procedural

**Problem.** After the paper-towels sheet-count incident, the ingest PRINTS
"run flag_outliers next" — advice, not enforcement. The failure mode returns
the moment someone scripts an ingest and drops the manual step.

**Design:** at the end of `review_escalations.py::ingest`, when
`len(confirmed) > 0`, import and invoke the flagging routine from
`graph/pipeline/flag_outliers.py` in-process (same connection, same
single-writer transaction discipline; refactor its main body into a callable
`flag(db, factor=5.0) -> dict` if it is currently CLI-only — keep the CLI).
Fold the flag counts into the ingest's returned summary and its decision-log
row. Keep the printed NEXT-step advice for the parity re-read (that part is
legitimately a separate, read-only step). Item 2's contested ingests then
inherit the guard automatically.

**Done means:** an ingest with ≥1 CONFIRM cannot complete without the basis
sweep having run against the post-ingest state; the README quick-start note
changes from "MANDATORY manual step" to "runs automatically inside ingest;
shown here for the mental model."

---

## 7. Explicitly out of scope

- Applying any alias without the stage-2 review of item 1 — no matter how
  obviously safe it looks.
- Minting new commodity ids for item 4's residuals (commodity-registrar's
  jurisdiction).
- The `Test Id 1` capture-pollution investigation (already running as its own
  spawned task).
- Lane importers, per-lane unit prices, and everything else in the README's
  "What Phase 2 still needs" §1–2.
- Changing the 5.0 outlier factor, any gate threshold, or the resolver.
- The price-state plan (PLAN-price-state-2026-08-20.md) — it is queued behind
  this work, not part of it.

## 8. Sequencing

```
5 (--requeue-stuck)                # must precede any resolution-ladder change
6 (basis guard in ingest)          # so items 2-3's ingests inherit it
1a-1b (blast radius + packet)      # tooling before judgement
1c (alias review + apply)          # moves missed-merge; re-run gates
2 (contested lane + adjudication)  # moves coverage; re-run gates
3 (deferred evidence pass)         # needs a browser session; re-run gates
4 (gold seam repair)               # independent; anytime after 5
README gate table + final commit/push
```

Items 1c, 2 and 3 each end with: `flag_outliers` (automatic after item 6) →
`score.py --context <named>` → `verifier.py` → `board_parity.py`, recorded.

## 9. Done means (whole plan)

- [ ] Missed-merge measured after alias absorption, README table updated with
      the honest number and the per-source residual breakdown.
- [ ] False-merge still 0.0000 at every checkpoint (this is the tripwire; any
      movement halts the plan).
- [ ] Zero contested entries unruled; zero deferrals without a current,
      page-informed reason.
- [ ] Zero stuck patches; zero silently-skipped gold cases.
- [ ] Every ingest path runs the basis guard structurally.
- [ ] Gates re-run and recorded per item; committed and pushed.
