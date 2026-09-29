# PLAN: held-out gold, honest eval health, and a guarded hillclimb loop (2026-09-29)

Status: DRAFT for Brad to edit, then hand to a fresh session to build. Nothing here is built.
Source: Anthropic, "Automating eval design and hillclimbing" (claude.dev/blog/automating-eval-design-and-hillclimbing),
read 2026-09-29. Its numbers are the author's single-benchmark results, not measured here.

## Knowledge consulted

- skills: `model-finetuning-craft/training-and-evaluation.md` section 8, "Diagnosing overfitting": "Score the model
  on **both** splits and compare ... Then distrust the verdict. In the course's own demo, 49 rows produced train 1.0
  / test 1.0 and the label 'good generalization'; a re-run with no change gave test 0...." Use: a two-split verdict
  on a small set is itself noisy, so W4's noise floor comes before W2's accept rule means anything.
- skills: `software-craft/regression-testing-a-model.md` section 8: the sidecar "has a real ML test suite, and it
  has the hard half already" (`backtest.py`, `hardeval.py` with an adjudicated GOLD set). Use: do NOT rebuild the
  sidecar holdouts; this plan is about the graph learner and the prompt surfaces.
- rules `measurement.md`: ms-01 denominator, ms-02 abstention scored, ms-03 bar before the run and "a number that
  moved is not a number that improved", ms-04 one row per case per arm, ms-06 input fingerprint, ms-07 name the
  harness blob. Exemplar: `sidecar/matcher_eval.py` header.
- rules `graph.md`: "A graph.db that EXISTS may hold no nodes ... a no is BLIND"; exemplar `_index_blind` in
  `graph/bench/priors_ablation.py`. And "A commodity id is NAMESPACED".
- rules `ops-and-gates.md`: og-05 MUST FIRE / MUST NOT FIRE / CLEAN TWIN; og-06 at-bar and one-step-past cases;
  og-11 no gate red on day one, use a ratchet; og-22 `SCOPE OF A CLEAN REPORT:` line.
- memory `learning-must-be-per-batch-not-nightly`: the brain is TWO-SPEED. "Immediate = resolutions ledger +
  `ingredient-events.jsonl`; nightly = graph, gold, review packet." Use: W2 hardens only the nightly half; the
  immediate half never passes a gold gate at all, so W0 counts it and D5 asks what to do about it.
- skills `experiment-craft/analysis-preflight.md`, items 6 and 8: the circularity claim below is quoted from a
  2026-08-20 header, so it is an input, not a finding, until W0 measures it today.
- Search run: `knowledge-search --estate "held-out split shadow gate gold learning"`, exit 0, 19 hits over 5 legs;
  the three above were the ones that applied.
- CLAUDE.md "New machinery must pay for itself": extend before adding, state seconds per push in the commit.
- Prior art in git (read before building, do not duplicate):
  - `64e570c4a` `tools/local-llm/finetune-probe/split_holdout.py`: splits by whole COMMODITY, seeded, and REPORTS
    near-twin leakage (73 of 101 held-out commodities share a token with a training one, 42 containment pairs).
  - `6b64dc0f5` reranker: "refuses to chase a lead inside its own noise", margin = measured seed spread 0.0033.
  - `319bfbceb` `sidecar/hardeval_baseline.py`: OK / DRIFT / UNCOMPARABLE, UNCOMPARABLE first.
  - `meal-prep/pipeline/score_ingredient_mapper.py`: "THE CORPUS IS SUCCESS-DERIVED AND THAT IS STATED".

## What was found while writing this (the reason the plan exists)

1. **The learning loop's shadow gate is partly circular.** `graph/learning/stage2_review.py --apply` scores each
   accepted patch against the WHOLE gold set (`shadow_and_apply`, ~line 376) and drops regressions. Its own sibling
   `alias_blast_radius.py` says why that is weak: on 2026-08-20 "each alias was derived from the very gold case it
   would then be scored against ... Circular evidence is not evidence." Blast radius is advisory; the gate is not
   fixed.
2. **The learner can write its own exam.** Stage 1 may propose `add_gold` (`stage1_analyze.py` header). Nothing
   stops a learned case landing in the set that later judges learned patches.
3. **No held-out split exists for graph gold.** `graph/gold/gold.jsonl` is 2,157 rows (2,137 match, 20
   do_not_merge; sources: escalation-review 1,386, product-urls 386, known-wrong 365, allowlist 20).
   `hunter-gold.jsonl` is 281 rows and deliberately separate.
4. **Most gold is failure-derived.** known-wrong and escalation-review (1,751 of 2,157, 81%) exist because the
   system got them wrong or was unsure. That measures THIS resolver's failure fingerprint (the article's
   "adversarial sampling" warning) and is weaker for judging a different resolver or prompt.
5. **Saturation is already visible.** `eval-runs.json` shows `false_merge_rate 0.0` on the deterministic arm. A
   metric pinned at 0 can catch a regression but cannot show an improvement, and should say so.

6. **The immediate half of the brain has no gold gate.** Mapper rulings land in
   `meal-prep/db/ingredient-resolutions.json` within seconds (memory `learning-must-be-per-batch-not-nightly`),
   and only an audit refusal can undo one. Nothing in this plan scores that ledger against held-out cases; W0.f
   measures how often it is later corrected, and D5 asks whether it should be scored.

Counts above are from `graph/gold/gold.jsonl` in the working tree on 2026-09-29 (it is modified daily); W0 re-counts
at a named blob.

## Out of scope

- The sidecar reranker / fine-tune holdouts (exist; see Knowledge consulted).
- Changing any matcher, alias, or prompt in the same commit that builds its measurement ("IT SCORES. IT DOES NOT
  TUNE", matcher_eval.py). W5 and W6 tune only after W1 to W4 have landed.
- Any change to what serves the live board. The graph is NON-AUTHORITATIVE (graph/README.md).

## Work items

Order matters: W0, then W1, then W2 / W3 / W4 in any order, then W5, then W6 only if Brad rules D4 yes.

### W0. Baseline audit (read-only, no code landed except the script)

A script `graph/eval/audit_gold_circularity.py` (Python, pinned interpreter) that prints, with denominators:

- a. gold rows by `source`, and the failure-derived share (known-wrong + escalation-review over total).
- b. applied learning patches (`approved_patches`) whose shadow evidence is ONLY their own source case. First
  VERIFY whether `approved_patches` records the gold case a patch was derived from. If it does not, report
  "provenance absent, circularity not measurable for N patches": a counted BLIND, never zero.
- c. gold rows that arrived via Stage 1 `add_gold`, if recorded; same BLIND rule if not.
- d. an input fingerprint (sha256 of gold.jsonl and the graph.db node count) and the blob of each file read.
- e. graph.db with no `Commodity` nodes = BLIND exit 3 (copy `_index_blind`).
- f. the immediate lane: of the resolutions written to `ingredient-resolutions.json`, how many were later
  invalidated by an `audit_finding` (`rejects_mapping`) in `ingredient-events.jsonl`, with the denominator and
  the date range. VERIFY those file and event names first; the memory citing them is 32 days old.

Self-test: MUST FIRE on a fixture patch whose only gold coverage is its source case; MUST NOT FIRE on one with an
independent case; CLEAN TWIN: a patch with no provenance reports BLIND, not clean.
Deliverable: the numbers written into this plan under a `## W0 result` heading before W2 is designed in detail,
because W2's hold rule depends on how many patches it would hold.

### W1. A frozen, key-based held-out split of graph gold

- New `graph/gold/gold_split.py` exposing `split_of(row) -> "train" | "holdout"`, keyed on the COMMODITY NODE
  (namespaced `commodity:staple:<id>`; the recipe twin maps to the same key), by salted hash, 20% holdout.
  Keyed, never random (ms-08: sample by KEY). Split by commodity for the reason `split_holdout.py` gives: a
  row-level split leaves the held-out side warm.
- **Reuse before writing.** If `split_holdout.py`'s split rule can be lifted into a shared function, import it
  from both places rather than forking a taxonomy. If not, say why in the header.
- Stable under growth: a new row for a held-out commodity is held out automatically; no manifest of rows to keep
  in sync. A small tracked `graph/gold/holdout-manifest.json` records salt, percent, the resulting commodity list,
  and the near-twin report (held-out commodities sharing a token with a train one, and containment pairs), exactly
  as `split_holdout.py` reports them. The manifest is written ONCE; a plain run verifies against it and never
  rewrites it (og-11 shape: `-Rewrite` flag, spoken).
- `score.py` gains `--split train|holdout|all` (default `all`, so nothing downstream changes), and every
  `eval_runs` row records the split and the manifest hash.
- **The holdout is closed to the learner**: Stage 1 `add_gold` for a held-out commodity is refused with a spoken
  reason (MUST FIRE case), and any hand-added gold row for a held-out commodity is fine (humans may add; the
  learner may not).

Acceptance: `score.py --split train` + `--split holdout` counts sum to `--split all` exactly, over a named gold
blob. Self-test covers the namespaced key (a bare id must not silently land in train), and recipe/staple twins
landing on the same side.

### W2. Stage 2 shadow gate scores both arms and ignores a patch's own source cases

Change `shadow_and_apply`:
- score `before`/`after` on train and holdout separately; the result row carries both deltas.
- **exclude from the shadow score the gold cases the patch was derived from** (needs W0.b provenance; if absent,
  add a `derived_from` field to approved_patches first, pointed-to object written first per og-51).
- Decision rule (proposed, D1):
  - regression on EITHER arm beyond the noise floor (W4): reject, as today.
  - false-merge rises on either arm by any amount: reject (the asymmetry score.py already encodes).
  - no independent gold case touches the target after exclusion: `not_run` hold with why="only circular
    evidence", the same road the existing "no gold-set coverage" hold uses (~line 444).
- Report the circular-hold count on every `--apply` run: `held circular=N of M accepted`.

Self-test: MUST FIRE a patch that fixes its source case and breaks one independent holdout case; MUST NOT FIRE a
patch that fixes its source and touches nothing else, which must be HELD, not applied (CLEAN TWIN: an independent
train case improves, holdout flat, applied).

### W3. Label where each gold row came from, and seed a small expert-hard set

- Add a derived `selection` class at load time in `seed_gold.load_gold` (not a new stored field): `failure`
  (known-wrong), `uncertain` (escalation-review), `success` (product-urls), `designed` (allowlist, expert-hard).
- `score.py` prints every metric per selection class beside the total, with denominators.
- New `graph/gold/expert-hard.jsonl`: 40 to 60 cases chosen by a HUMAN for being intrinsically hard (near twins,
  form splits like gruyere shredded vs block, pack-basis traps), written BEFORE looking at the resolver's output
  on them. Same schema and id recipe as gold.jsonl; `source: expert-hard`. D3 decides who writes them.

### W4. Eval health checks (the article's build-eval diagnostics)

Extend `graph/eval/score.py` with `--health` rather than a new tool:
- **Noise floor**: the LLM arm run N=3 on the same gold blob; print per-metric spread. The deterministic arm
  must show zero spread; any spread there is a harness defect, exit 1.
- **Capability ordering**: recall must be deterministic <= +llm <= +bank (system). A flat or inverted ordering
  prints `ORDERING-SUSPECT` naming the arms; it is a finding, not a gate.
- **Headroom**: any metric at exactly 0 or 1 on every arm prints `SATURATED <metric>` so no one reads a
  non-regression there as an improvement.
- Last line `SCORE-HEALTH-COMPLETE runs=N arms=K` (og-02). Cost: LLM arm needs llama-server
  (`tools/local-llm/serve.ps1`, start it, never wait on it, `-Slots 1`); state wall-clock in the commit. Not a
  push gate (data-dependent, needs a model).

### W5. A guarded hillclimb loop for ONE text surface: the graph resolver's local-LLM prompt

Why this target first: free (local model), programmatic grader (gold), large corpus, and Stage 1 already has a
`tighten_prompt` kind, so the surface is sanctioned. First VERIFY where the prompt lives (`graph/lib/llm.py`,
`prompt_version resolve.v1`) and that `score.py --llm` exercises it.

`graph/bench/hillclimb_prompt.py`:
- Bar written in the file BEFORE the first run (ms-03), in metric units, e.g. "keep a round only if holdout
  missed-merge falls by more than the W4 noise floor AND false-merge does not rise on either arm". Brad sets the
  numbers (D2).
- One targeted patch per round, proposed from the TRAIN failures only; scored on train then holdout.
- Keep only if both arms meet the bar; otherwise revert. Stop after 3 consecutive flat rounds and write a failure
  analysis instead of forcing more.
- **Transcription ban, enforced mechanically**: refuse any candidate prompt containing a gold `product` string or
  a commodity slug from holdout (MUST FIRE fixture). This is the article's "never copy failing outputs into the
  prompt", made checkable.
- One row per case per arm per round in `graph/bench/out/hillclimb-<date>.jsonl` (ms-04), totals derived; the
  round count and variants tried printed with the final result (og-14).
- The loop NEVER promotes. Output is a candidate prompt plus its evidence; promotion is a separate, reviewed
  commit that bumps `prompt_version`.

### W6 (only if D4 = yes). Cheaper-model trial for two Claude agents

Brad pinned every agent to Opus 5.5 medium on 2026-09-29 (`f6197448d`). The article's example is the reverse
question: does a cheaper model/effort with a tuned prompt hold on held-out cases? Evidence only; changing a pin
stays Brad's.
- Targets: `recipe-hunter-extractor` (transcription only) and `recipe-source-qa` (verdict only). Both have
  programmatic-ish graders from past Recipe Hunter runs (extracted JSON that later passed source-QA). VERIFY a
  corpus of at least 100 cases exists before spending anything; under 100, refuse to score (the
  `eval_holdout.py` rule).
- Arms: Opus 5.5 medium (baseline), Sonnet 5.5 medium, Sonnet 5.5 low, Haiku 4.5. N=3 per case per arm.
- Hard bars: zero invented ingredients or steps (any is a fail for that arm); holdout accuracy within the noise
  floor of the baseline. Report cost per case per arm.
- Budget: state the API spend estimate in the plan before running and get D4's yes on that number.

## Decisions for Brad

- **D1. Circular-only patches: hold or apply?** W2 would hold a learning patch whose only gold evidence is the case
  it was written from. Recommendation: HOLD (it is "no evidence", the same as the existing no-coverage hold). Cost:
  some aliases wait for a human; W0.b says how many.
- **D2. The hillclimb bar.** Recommendation: false-merge may not rise at all; holdout missed-merge must fall by more
  than the measured noise floor.
- **D3. Who writes the expert-hard set.** Recommendation: Brad, 40 cases, about an hour, because a model picking
  "hard" cases reintroduces the bias the set exists to remove. Fallback: the commodity-registrar agent drafts from
  the commodity list alone (never resolver output), Brad strikes the ones he disagrees with.
- **D4. Run the cheaper-model trial (W6)?** Recommendation: yes for the extractor only, after W1 to W5, capped at a
  stated spend.

- **D5. Score the immediate learning lane too?** Recommendation: decide after W0.f. If more than a handful of
  fast-lane resolutions are later reversed, a small held-out check of `score_ingredient_mapper.py`'s corpus
  (661 rows, success-derived by its own header) is the natural next plan. Otherwise leave it.

## Build rules for the implementing session

- Branch `eval/heldout-hillclimb`; commit each W separately with a pathspec (`git commit -F <file> -- <paths>`),
  a `Store:` line, and the seconds-per-push cost of any new self-test.
- Land through `ops\push-main.ps1`, never `git push origin HEAD:main`.
- Every new script: `SCOPE OF A CLEAN REPORT:` line, `-COMPLETE` last line, self-test with MUST FIRE / MUST NOT
  FIRE / CLEAN TWIN, and at-bar plus one-step-past cases for any threshold.
- Run `ops\run-gates.ps1`, read the exit code first; in a worktree, seed with `ops\seed-worktree.ps1` first.
- Write results into this file (`## W0 result`, etc.) and file backlog progress under
  `design\backlog-inbox\updates\`.

## Paste-ready kickoff for a new session

> Build `design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md` in ThriftyCrew. Read the whole plan and its
> Knowledge consulted section first, then `graph/learning/stage2_review.py`, `graph/eval/score.py`,
> `graph/gold/seed_gold.py` and `tools/local-llm/finetune-probe/split_holdout.py`. Do W0, write its result into
> the plan, then W1 to W4. Stop before W5 if Brad has not filled in D1 and D2 in the plan, and never start W6
> without D4 = yes. Completion condition: W0 to W4 landed on origin/main through push-main, each with a green
> self-test and run-gates exit 0 read by you. Report open items and blockers by W number.
