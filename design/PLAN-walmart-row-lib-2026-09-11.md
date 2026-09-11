# Giving Walmart's row builder a provided interface

**Status: PLAN, written before the build on 2026-09-11.** Follow-on to backlog I82, which did the same
for the pricing math (`design/PLAN-compare-deals-interface-2026-09-09.md`). The exemplar is
`grocery/pricing-math-lib.ps1`; read its header first. Results are appended at the bottom once measured.

## The problem in one line

`grocery/import-walmart-batch.ps1` reads `grocery/build-walmart-deals.ps1` as TEXT, cuts seven functions
and `$script:UnitFamily` out of it by regex, and runs them with `Invoke-Expression`, off a hand-maintained
name list. That is the last live production lift in the estate, and it sits on the Walmart price path.

## Measured before the change (at 9eb32182d, 2026-09-11, from this worktree)

- `ops\count-source-lifters.ps1 -Script build-walmart-deals.ps1` over 596 files: NAMES 15, READS 3,
  **EXECUTES 1: `grocery\import-walmart-batch.ps1:58`**.
- `ops\audit-lift-completeness.ps1`: read 274 grocery scripts, **2 lifts checked** (import-instacart-batch
  lifts 1 function out of import-walmart-batch; import-walmart-batch lifts 7 out of build-walmart-deals),
  0 findings, exit 0.
- `build-walmart-deals.ps1 -SelfTest` exit 0, 42 output lines. `import-walmart-batch.ps1 -SelfTest` exit 0,
  26 output lines. Both kept as the case-name baseline.
- **What moves is one contiguous block** of the builder, from the `# unit token as Sam's prints it`
  comment to Build-Row's closing brace: Resolve-Unit, `$script:UnitFamily`, Get-NameQtyCandidates,
  Get-NamePackMultipliers, Get-SameFamilyNameQty, Get-NamePack, Format-Qty, Build-Row, and the comments
  between them. Nothing else lives in that range.
- **Closure.** Build-Row calls the six helpers and `Get-UnitPrice` (pricing-math-lib). It reads
  `$script:UnitFamily`, which moves with it, and `$script:CaptureDate`, which the caller sets. Nothing in
  the block calls `BW-IsMultipackReject` or anything else the builder defines. Re-checked by scan after
  the move.
- **Encoding.** The builder, the importer and pricing-math-lib are all 0 non-ASCII bytes, LF, no BOM. The
  library is written the same way.

## Why nobody just dot-sourced it

The same reason compare-deals had: `build-walmart-deals.ps1` does work on load. It reads `-In`, writes
`out\regular`, mutates the rollback ledger and advances the capture cursor. The functions themselves are
pure over their arguments plus one constant and one caller-set date. They just share a file with a
pipeline.

## The change

1. **`grocery/walmart-row-lib.ps1`.** Header modelled on pricing-math-lib's. The block is cut by line
   range out of the committed builder by a script, so its bytes are the builder's bytes. **One deliberate
   exception:** the comment inside Get-SameFamilyNameQty explains its local variables by the lift this
   change retires, and is rewritten rather than left describing a mechanism that no longer exists. No
   `param()` block (capture-lib's `-SelfTest` collision), no self-test in the library, no work on load:
   it defines eight functions and assigns one constant.
2. **`build-walmart-deals.ps1`.** The block is replaced by `. (Join-Path $root 'walmart-row-lib.ps1')` at
   the same position, after pricing-math-lib and before multipack-lib, so definition order is unchanged.
   `$script:CaptureDate` is still set above it.
   **Its self-test greps its OWN source** for `seller = [string]$raw.sel` (the shelf-signal case). After
   the move that line lives in the library and the grep would fail. It is replaced by a behavioural
   assertion on Build-Row's output for the same 9-column and 7-column rows, under the same case label.
   That is stronger as well as necessary: it fails when Build-Row stops carrying the fields, not when a
   line is reformatted.
3. **`import-walmart-batch.ps1`.** The Get-Content, the foreach and both Invoke-Expressions are replaced by
   the dot-source, after pricing-math-lib.
   **Contract note, kept exactly:** the importer does NOT set `$script:CaptureDate` today, so Build-Row
   stamps `as_of` as `$null` and the main path overwrites `as_of` with the run date. Setting it here would
   be a behaviour change, so it is not done.
4. **`grocery/test-auditors.ps1` unit u022.** The pin on the literal lift list becomes: both callers
   dot-source `walmart-row-lib.ps1`, neither reads `build-walmart-deals.ps1` as text, the builder no longer
   defines `function Build-Row`, and the library does. The unit names all three files as literals, so
   `ops\prepush-test-auditors.ps1` selects it when any of them changes.
5. **Comments that name this lift:** build-walmart-deals (beside the pricing-math-lib dot-source),
   import-walmart-batch (header and lift block), `.claude/rules/grocery.md` (compare-deals lifters
   bullet), and `ops/audit-lift-completeness.ps1`'s header, which names this move as the fix not yet done.

## Acceptance bars, written before the run

1. **The move is verbatim.** Parser tokens with comments removed are identical for 8 of 8 items against
   the builder at 9eb32182d, and the raw text the old lift regex cuts is identical for 7 of 8 (the
   eighth is the one rewritten comment).
2. **Both self-tests** exit 0 with an EMPTY case-name diff against the baseline, run in the shape
   `guards.ps1` launches its Walmart kids (`-NoProfile -File <script> -SelfTest`). `guards.ps1` as a whole
   is data-dependent and blind in a worktree; its two Walmart kids are exactly these two runs.
3. `compare-deals.ps1 -SelfTest` still passes (section 30: both callers still dot-source pricing-math-lib).
4. `test-auditors.ps1` unit u022 passes, and `ops\prepush-test-auditors.ps1 -SelfTest` passes (it fails a
   unit whose declared reads match nothing).
5. **Byte identity on real input.** Each arm is extracted with `git archive` at its commit, so both are
   byte-exact, into its own tree per case. Cases: the builder on `walmart-capture-2026-09-10.csv` (newest)
   and `walmart-capture-2026-08-31.csv` (largest, 4.3 MB); the importer on the three batches in
   `out\staples500` (walmart-batch1, 400 products, 4-field, with `-TrustNoSeller`; stale22, 22 products,
   6-field; markdown4, 4 products, 7-field, the rollback path), each with its own `-OutRoot`.
   Every `walmart-regular`, rejects, needs-seller and itemids file must be **SHA256-identical** across arms.
   Ledger files are compared too and may differ only in a wall-clock `generated` or `updated` stamp. Exit
   codes identical, stdout identical once the tree path is masked. Inputs are fingerprinted by SHA256.
   `ops\consistency-oracle.ps1` is not the harness for this one: it cannot drive the importer (it passes
   `-In`), and its old arm rewrites blobs through `Set-Content`, so its arms are not byte-exact.
6. `ops\audit-lift-completeness.ps1` reports **1 lift checked** (import-instacart-batch out of
   import-walmart-batch), 0 findings, exit 0. `count-source-lifters -Script build-walmart-deals.ps1`
   reports EXECUTES 0, and `-Script walmart-row-lib.ps1` reports READS 0 and EXECUTES 0.
7. `ops\run-gates.ps1` exits 0, read as the exit code before the tally.

Any bar that fails stops the push.

## Rollback

One commit, `git revert`. No data format changes and nothing migrates.

## Ruling: can build-sams-deals.ps1 share the library?

Asked as a ruling, not built here. Measured 2026-09-11 at 9eb32182d by parser tokens with comments
removed (the scratch comparer behind acceptance bar 1):

| item | Walmart builder vs `build-sams-deals.ps1` |
|---|---|
| Resolve-Unit | identical, text too |
| `$script:UnitFamily` | identical, text too |
| Get-NamePack | identical, text too |
| Format-Qty | identical, text too |
| Get-NameQtyCandidates | code identical, comments differ |
| Get-NamePackMultipliers | Walmart only |
| Get-SameFamilyNameQty | Walmart only |
| Build-Row | **diverged**: 1,418 tokens against 926 |

**The helpers can be shared. Build-Row cannot, and the divergence is policy rather than drift.** Walmart's
Build-Row reads cent-denominated and per-N unit prices (`24.9 c/oz`, `$5.58/100 ct`), refuses a printed
weight or volume that no pack count explains but trusts lp/up for a disputed COUNT (its frozen case 8),
proves a `/ea` denominator by the name's arithmetic, and stamps seller, fulfillment and the caller's
`$script:CaptureDate`. Sam's reads dollars only, refuses ANY name quantity that disagrees including counts
(the Sazon rule), declares the name's volume through Get-NameVolumeFloz, and stamps `$Date` and its own
`sams_*` fields. Merging the two is a pricing ruling about which store's refusal is right, not a refactor.

**And not by dot-sourcing `walmart-row-lib.ps1` into the Sam's builder.** That would load a Walmart
Build-Row which the Sam's file then redefines under the same name. PowerShell allows it (the later
definition wins) and it is exactly the silent shadowing that lets a reader trust the wrong function.
The shape that would work is a store-neutral `capture-row-lib.ps1` holding the five shared items, which
both stores' row libraries dot-source, with each store's Build-Row in its own file. It would need the
same byte-identity proof on a Sam's capture, and the two copies of Get-NameQtyCandidates' comments
reconciled first.

## Results (2026-09-11)

Measured from the worktree on branch `refactor/walmart-row-lib`. The byte-identity arms ran at 9eb32182d
(before) and 00ec9dcfc (after, the change as first committed). The branch was then rebased onto
04727f04c: `git diff --name-only 00ec9dcfc` against the rebased commit names 6 files, and none of them is
loaded by the builder or the importer.

1. **Verbatim move: met.** Parser tokens with comments removed are identical for 8 of 8 items against the
   builder blob at 9eb32182d. The text the old lift regex cuts is identical for 7 of 8; the eighth,
   Get-SameFamilyNameQty, differs only by the planned comment rewrite. (Scratch comparer, PowerShell's own
   parser.)
2. **Self-tests: met.** `build-walmart-deals.ps1 -SelfTest` exit 0, 42 lines, and its full output diffs
   0 lines against the baseline. `import-walmart-batch.ps1 -SelfTest` exit 0, 26 lines, 0-line diff. The
   rewritten shelf-signal case was **mutation-probed** from a temp mirror: the unmutated control passes;
   dropping `seller` from Build-Row's row and hard-coding `fulfillment` are each killed by exactly that
   case (1 FAIL line each). The worktree library was md5-identical afterwards. **The first probe proved
   nothing:** its mirror lacked `lib\`, both mutants died on a missing `Read-JsonFile` before any case
   ran, and it was re-run rather than counted.
3. **compare-deals -SelfTest: met.** Exit 0, section 30 prints ok for all three builders and for the
   library's closure.
4. **test-auditors: met for u022, and the full run has one environment failure.** Unit u022 alone:
   4 of 4 cases pass, exit 0 (a selective run of 1 of 138 units, not a full pass).
   `ops\prepush-test-auditors.ps1 -SelfTest`: 69 of 69. The pre-push check against this push does a FULL
   run (test-auditors.ps1 is in the push): 704 cases, 2 failing. One is the Hy-Vee identity fixture, which
   the known-failures record already holds. The other is `feed-covers-published -SelfTest`, which needs
   `meal-prep\db\built`; that directory is gitignored and absent from the worktree, and run-gates fails the
   same self-test for the same reason. The final push runs from a checkout seeded with it.
5. **Byte identity on real input: met, 11 of 11 strict files identical.** Each arm was extracted with
   `git archive` at its commit into its own tree per case. Exit codes and stdout (tree path masked) were
   identical in every case.

   | case | input | bytes | input sha256 | strict files identical | ledger files, clock stamp only |
   |---|---|---|---|---|---|
   | builder | walmart-capture-2026-09-10.csv | 52,444 | FF004B15A5FB3C03 | 2 of 2 | 0 |
   | builder | walmart-capture-2026-08-31.csv | 4,326,263 | B9AA3ECABFB126B6 | 2 of 2 | 1 |
   | importer, -TrustNoSeller | walmart-batch1-raw.txt (400 products, 4-field) | 33,808 | C78DE8BC781FE0B4 | 3 of 3 | 1 |
   | importer | walmart-stale22-2026-09-05-raw.txt (22, 6-field) | 2,187 | B481DFF074BA1C8D | 2 of 2 | 1 |
   | importer | walmart-markdown4-2026-09-05-raw.txt (4, 7-field) | 349 | 433BD3F6B54009EB | 2 of 2 | 2 |

   The walmart-regular outputs hash 001C966D93BED6B6 and 31EADF44D4CF04CD for the two builder cases, and
   750AFC68892C4D0A, C5E0F809D251921E and D7A326737C34B66E for the three importer cases, identically in both
   arms. The batch1 import verified 352 rows (48 rejected); the full pull is the case with real breadth. Wall times differ
   (36.0s before, 52.2s after on the full pull) but the after arm ran beside run-gates, once, so that is not
   a performance measurement and is not claimed as one.
   **The first harness run failed on its own pathspec** (`grocery/*.json` crosses directories in git, so it
   archived 980 MB). No arm ran. It was fixed with `:(glob)` and re-run.
6. **Lift counts: met.** `ops\audit-lift-completeness.ps1`: 275 grocery scripts read, **1 lift checked**
   (import-instacart-batch out of import-walmart-batch), 0 findings, exit 0; its self-test passes.
   `count-source-lifters` over 597 files: `-Script build-walmart-deals.ps1` EXECUTES 0 (NAMES 16,
   READS 3); `-Script walmart-row-lib.ps1` EXECUTES 0 (NAMES 4, READS 1, which is test-auditors u022
   matching its text); `-Script import-walmart-batch.ps1` EXECUTES 1, `import-instacart-batch.ps1:68`.
7. **run-gates: one real failure found and fixed; the rest is the worktree.** From the worktree: exit 1,
   266 passed, 18 failed. **One was this change and the plan had missed it:** `ops\audit-twin-drift.ps1`
   declares the twin `deal-builder-size-token` (the name-quantity pattern shared with the Sam's builder)
   with its Walmart side anchored in `build-walmart-deals.ps1`, so the move left it UNWATCHED.
   `ops\twin-rules.json` now points that side at `walmart-row-lib.ps1`: 12 twins, 0 drifted, self-test
   passes. The other 17 are the worktree itself: audits that exclude `\.claude\worktrees\` by full path and
   report discovering nothing, two meal-prep self-tests missing `meal-prep\db\built`, the sidecar self-test
   missing `sidecar\.venv`, and the prompt-backup audit, which compares against the main checkout's agent
   prompts. The gate that decides the push runs from a seeded checkout outside `.claude\worktrees`, and the
   pre-push hook runs it again on the pushed tree.

**Found in passing, not fixed here:** `import-walmart-batch.ps1 -Reheal` writes healed rows with `as_of`
null. Build-Row emits `as_of` from the unset `$script:CaptureDate`, and the reheal carry-forward only copies
fields the new row LACKS. Reproduced in-process, present at 9eb32182d, and left alone because this change
must not alter behaviour. It is queued as its own task.
