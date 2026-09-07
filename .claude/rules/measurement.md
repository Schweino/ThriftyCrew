---
description: Rules for anything that scores, compares two versions, or reports a rate - denominators, acceptance bars, per-case evidence.
globs: "sidecar/**, **/*eval*.py, **/*probe*.py, **/audit-*.ps1, **/*_eval.py"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Measuring anything here

Loaded when you touch something that scores, compares two versions, or prints a rate. These four
rules were each learned from a number that was wrong in a way nobody could see, and every one of them
is cheap at the moment the code is written and impossible to add afterwards.

**The exemplar is `sidecar/matcher_eval.py`.** Read its header before writing a new scorer - it
carries all four rules in one file, and copying it is faster than re-deriving them.

- **A rate is printed with its DENOMINATOR, always** (backlog E20). `88%` is a mood; `examined 15 of
  17 (88%)` is a measurement. This is not pedantry: the dedup head-to-head reported recall over 31
  pairs while the ledger held 168, so the real coverage was **18%**, and nothing on the page said so.
  Worse, the 82% that dropped out were not random - a twin leaves the candidate pool when its recipe
  is accepted and built, so the surviving evidence was weighted toward the cases the pipeline already
  handles. Swept 2026-09-07: 45 percentage computations across 25 files, 42 already compliant.
  `Write-GuardComplete` states the same rule for guards - `scanned=3164 findings=3`, never
  `findings=3`.
- **A matcher that ABSTAINS is scored on what it skipped** (also E20). A component returning
  `UNUSABLE`, `PENDING` or nothing on the rows it finds hard, then scored only on the rows it
  answered, outscores one that attempts everything - and neither number looks wrong. Report coverage
  beside every accuracy figure, or count a decline as a miss.
- **Write the ACCEPTANCE BAR before the run** (backlog E21), in the metric's own units. A threshold
  chosen after seeing the number is not a threshold; it is a description of a decision already taken.
  `meal-prep/pipeline/bm25_dedup_probe.py:309` states its bar in the source above the run. And **a
  number that moved is not a number that improved**: say how far, over how many cases, and how many
  variants were tried, or the delta is unqualified. [[pick-the-best-run-is-selection-on-noise]]
- **Write ONE ROW PER CASE PER ARM, and derive the totals from that file** (backlog E24). A pair of
  totals - `old: 50 wrong, new: 38 wrong` - cannot be un-aggregated, so the paired comparison that
  would have been free is gone forever. Cheap to adopt, impossible to backfill.
  `meal-prep/db/dedup-headtohead-cases.jsonl` is what this looks like.
- **RECORD THE CASE AT THE MOMENT IT FAILS**, including the ones you fix by hand and move on from,
  and give every corpus row a `source` (backlog E23). Fixtures here are assembled from bugs we found
  and cases we already handle, so the ones that failed silently are absent - and **their absence is
  invisible in the score**. Measured 2026-09-07: **189 of 6,476 gold rows** come from a recorded
  failure, and `graph/gold/hunter-gold.jsonl` is **281 rows, every one a SUCCESS, every label MATCH**
  - a corpus with no negative cases cannot measure over-firing at all, which is a fixture with no
  clean twin wearing a bigger coat. `ops/audit_corpus_provenance.py` prints the mix and ratchets
  corpora that carry no `source` at all.
- **Record an INPUT FINGERPRINT** with the result. The dedup probe disagreed with itself across two
  runs because its inputs moved underneath it and it recorded nothing about what it had read.

Two more that live elsewhere and bite here:

- **Three score spaces do not share a scale** - bi-encoder cosine, cross-encoder sigmoid and BM25.
  `sidecar/THRESHOLDS.md` is the register and `ops/audit-threshold-register.ps1` gates it.
- **A fixture's 50% base rate overstates precision enormously.** Live precision comes from
  `grocery/audit-alert-precision.ps1`, off the dispositions `grocery/triage-close.ps1` records.

Regime: this holds for scoring, comparison and reporting code. Detector and gate mechanics are
`ops-and-gates.md`.
