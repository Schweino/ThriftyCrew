**First, the analysis preflight:** [experiment-craft/analysis-preflight.md](C:/Users/Owner/.claude/skills/experiment-craft/analysis-preflight.md), the ten checks to run before any analysis verdict, each naming where its depth lives.

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Measuring anything here

Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3). It holds for anything that
scores, compares two versions, or prints a rate. **The exemplar is `sidecar/matcher_eval.py`**: read its
header before writing a new scorer.

**HOW THIS FILE IS WRITTEN** (design/PLAN-rules-trim-2026-09-25.md). Each rule holds its OPERATIVE text only; the
measurements and incidents behind it live in `docs/rules-history/measurement.md` at the anchor its tag names
(`full: ms-NN`), word for word. `ops/audit-rule-format.ps1` refuses a push that breaks the shape.

- **A rate is printed with its DENOMINATOR, always**: `examined 15 of 17 (88%)`, never `88%`. Guards print
  `scanned=N findings=M` (`Write-GuardComplete`). (channel: judgement; full: ms-01)
- **A matcher that ABSTAINS is scored on what it skipped.** Report coverage beside every accuracy figure, or count a
  decline as a miss. (channel: judgement; full: ms-02)
- **Write the ACCEPTANCE BAR before the run**, in the metric's own units, in the source above the run. **A number
  that moved is not a number that improved**: say how far, over how many cases, and how many variants were tried.
  [[pick-the-best-run-is-selection-on-noise]] (channel: judgement; full: ms-03)
- **Write ONE ROW PER CASE PER ARM, and derive the totals from that file**, never a pair of totals.
  `meal-prep/db/dedup-headtohead-cases.jsonl` is the shape. (channel: judgement; full: ms-04)
- **RECORD THE CASE AT THE MOMENT IT FAILS**, including ones fixed by hand, and give every corpus row a `source`. A
  corpus with no negative cases cannot measure over-firing. `ops/audit_corpus_provenance.py` prints the mix.
  (channel: gate ops/audit_corpus_provenance.py; full: ms-05)
- **Record an INPUT FINGERPRINT** with the result. (channel: judgement; full: ms-06)
- **NAME THE HARNESS AND THE BLOB IT RAN AT.** A measurement anyone may repeat COMMITS its harness; a one-off keeps
  the description. Cite the BLOB of each file the run read (`git rev-parse <commit>:<path>`), because a rebase cannot
  move a blob; **never cite your own unlanded commit hash, anywhere**. A moved harness makes a verdict UNQUALIFIED
  (`ops/audit-conclusion-currency.ps1`); re-qualify it with a ledger row,
  `powershell -NoProfile -File ops\add-reread.ps1 -Doc <design\MEASURE-...md> -Harness <path> -Note "<what still holds>"`,
  never on anyone's behalf (the doc-line form `Re-read at harness blob <id> (<path>): <what still holds>` still works).
  Take a re-read back by appending a `withdrawn` row; never edit or delete one.
  (channel: gate ops/audit-reread-ledger.ps1, ops/audit-conclusion-currency.ps1; full: ms-07)
- **A hash-based change detector compares SETS keyed by primary key, and samples by KEY, never at random.** A design
  doc proposing a board-level change or drift detector cites
  `~/.claude/skills/data-quality-craft/checks-and-thresholds.md` section 5c and fixtures both halves: silent on an
  unchanged board, loud on one changed value at a constant row count. (channel: judgement; full: ms-08)
- **Three score spaces do not share a scale** (bi-encoder cosine, cross-encoder sigmoid, BM25).
  `sidecar/THRESHOLDS.md` is the register. (channel: gate ops/audit-threshold-register.ps1; full: ms-09)
- **A fixture's 50% base rate overstates precision enormously.** Live precision comes from
  `grocery/audit-alert-precision.ps1`, off the dispositions `grocery/triage-close.ps1` records.
  (channel: judgement; full: ms-10)

Regime: this holds for scoring, comparison and reporting code. Detector and gate mechanics are
`ops-and-gates.md`.
