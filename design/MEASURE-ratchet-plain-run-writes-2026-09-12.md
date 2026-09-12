# Which ratchets still write their tracked mark on a plain run?

**Harness.** `ops/audit-fixed-temp-names.ps1`, `ops/audit-bare-replace.ps1` and
`ops/audit_corpus_provenance.py` - the three scripts converted here. Every figure below came from running
one of them directly: its self-test, its live path over a seeded fall, and the single-mutant probes.

**Commit it ran at:** `9098caaa4`, the commit that converts those three. The defect reproductions were
taken with this checkout at `740c82af6`, which was main's tip at the time; `9098caaa4` was rebased onto
`500b42169` before it landed, so it is no longer that commit's child, and the conversions were verified
at `9098caaa4` itself.

**Re-read at commit `c74644b18`: every figure below still holds.** `ops\audit-fixed-temp-names.ps1` and
`ops\audit-bare-replace.ps1` moved only in how they list the tree: each now walks through `lib\tree-walk.ps1`'s
`Get-TcTreeFiles`, which never enters a directory the audit's own exclusion drops. No baseline write, record flag or
rise branch changed. Both self-tests still pass (35 and 22 cases), and each audit's plain-run output over a worktree
matched its output from before the change line for line, except that fixed-temp-names now also counts the walk
helper's own per-run temp path (built 308 to 309; fixed names still 7).

This document is in its own commit for the reason `design\MEASURE-gate-slot-admission-2026-09-11.md`
gives: a document cannot carry the hash of the commit that adds it, and here the harness IS what moved,
so the scripts land first and this cites them. The gate suite that ran over the whole tree is named in
"The full suite" below, deliberately away from the line above, because it is a verification step and not
an instrument any number here rests on - and every session on this box edits it, so naming it as a
harness would make this document stale within the hour.

## The rule being audited

`740c82af6` established it and `.claude\rules\ops-and-gates.md` states it: **a plain run of a ratchet
never writes its mark.** `run-gates` runs every static audit with NO arguments on every pre-push, so a
tighten there rewrites a TRACKED baseline inside the checkout being pushed, the push does not carry it,
and a count taken over uncommitted edits is not a baseline anyway. A fall is SPOKEN and the committed
mark KEPT; `-Tighten` records it through `Test-RatchetMove` and `lib\lf-write.ps1`.

That commit converted seven. It did not convert `ops\audit-fixed-temp-names.ps1`, which is what this
census started from.

## The defect, reproduced rather than quoted

`ops\audit-fixed-temp-names.ps1` at `740c82af6`, mark set to 11 in the working tree so the count of 10
reads as a fall, run with **no arguments**:

```
EXIT=0
PASSED and TIGHTENED - fixed-temp-names: 10 finding(s), down from 11. Baseline lowered; it can never rise again.
git status --short  ->   M ops/fixed-temp-names-baseline.json
```

Exit 0, a tracked baseline modified, and no `-Tighten` parameter existed to ask for it. The bytes were
already LF here, so the defect is the write itself and not a line-ending flip on top of it.

## The census

**Population.** Every `.ps1` or `.py` that reads a high-water mark and can write it: found as the 21
files matching `Test-RatchetMove|ratchet\.ps1` under `ops lib grocery meal-prep graph`, crossed with the
47 tracked files whose name carries `baseline`/`high-water`/`-mark`, then narrowed to the 17 mark-owning
scripts `ops\run-gates.ps1` names in its own entry lists (those run with no arguments, which is the
condition that makes the defect bite) plus `grocery\audit-json-readers.ps1`, which the daily
`grocery\guards.ps1` chain registers with `@()`.

**Test.** For each, read the enclosing condition of every write to its own mark. For the three that had
none, force a fall and run the script with no arguments, then compare the file's bytes.

| Script | Record flag | Writes on a plain run? |
|---|---|---|
| `ops\audit-fixed-temp-names.ps1` | none (added `-Tighten`) | **YES - measured.** Fixed here |
| `ops\audit-bare-replace.ps1` | none (added `-Tighten`) | **YES - measured.** Fixed here |
| `ops\audit_corpus_provenance.py` | `--update` only (added `--tighten`) | **YES - the `if fixed:` branch.** Fixed here |
| `grocery\audit-json-readers.ps1` | `-Baseline`, `-AcceptDrop` | **Shape present, cannot fire.** See below |
| `ops\audit-write-only-reports.ps1` | `-Tighten`, `-Accept` | no |
| `ops\audit-write-seam.ps1` | `-Tighten`, `-AcceptDrop` | no |
| `ops\audit-full-path-excludes.ps1` | `-Tighten`, `-AcceptDrop` | no |
| `ops\audit-ruling-drift.ps1` | `-Tighten`, `-AcceptDrop` | no |
| `ops\audit-typed-param-shadow.ps1` | `-Tighten`, `-AcceptDrop` | no |
| `ops\audit-arg-binding.ps1` | `-Tighten`, `-Accept` | no |
| `ops\audit-source-comment-strip.ps1` | `-Tighten`, `-Accept` | no |
| `ops\audit-conclusion-currency.ps1` | `-Tighten`, `-Accept` | no |
| `meal-prep\pipeline\audit-fact-claims.ps1` | `-Tighten`, `-AcceptDrop` | no |
| `grocery\test-native-stderr-eap.ps1` | `-Tighten`, `-Accept` | no |
| `ops\audit-mustfire-census.ps1` | `-Update` | no - the write is inside `if ($Update)` |
| `ops\audit-fixture-inputs.ps1` | `-Update` | no - the write is inside `if ($Update)` |
| `ops\audit-cross-module-reach.ps1` | `-UpdateBaseline` | no - the whole record block is inside `if ($runUpdate)` |
| `ops\audit-measurement-provenance.ps1` | `-UpdateBaseline` | no - the write is inside `if ($UpdateBaseline)` |

The brief named `audit-mustfire-census` and `audit-cross-module-reach` as worth reading for the same
defect. **Both are clean.** Their flags are spelled `-Update` / `-UpdateBaseline` rather than `-Tighten`,
which is why they look like the suspects from outside, but in each case the record is the ONLY thing
inside that branch and the plain path never reaches it. `audit-cross-module-reach` goes further and
exits 3 with "run -UpdateBaseline once" when no baseline exists, rather than seeding one.

## The one left standing, and why it is not urgent

`grocery\audit-json-readers.ps1` lowers its mark unconditionally in the `tighten` branch, and its
baseline `grocery\out\json-readers-baseline.json` is tracked with a BOM. **But its committed mark is 0**,
and `Get-RatchetVerdict 0 0` is `hold`: a fall needs `count < base`, so with `base` at 0 that branch is
unreachable. The defect is latent, not live, and it is in the daily guards chain rather than at push
time - where the ~07:00 bot commits the whole tree anyway. It is outside the scope this census was asked
for (`ops\`), so it is REPORTED and not changed. When it is fixed, two things move together: the write
goes behind a `-Tighten`, and it writes through `lib\lf-write.ps1` keeping the BOM, because
`Set-Content -Encoding UTF8` under PS 5.1 writes CRLF over an `eol=lf` blob.

## Sensitivity: the new cases were mutation-probed, not just run green

Three cases were added to each converted script - a fall with no flag leaves the mark byte-identical,
the flag records it in the bytes git stores, and a CLEAN TWIN that a rise still exits 2. A green fixture
is not coverage, so each was driven by single compiling mutants from a temp mirror, with the originals
verified md5-identical afterwards and the mirror removed:

- `ops\audit-fixed-temp-names.ps1` - control 35 of 35 pass, exit 0. **4 of 4 mutants died in their own
  named case**, no other case moving: the guard removed (`if ($true)`), the `-NoBom` dropped, the rise
  branch's `-Code 2` turned to `-Code 0`, and the kept note replaced by the default.
- `ops\audit-bare-replace.ps1` - control 22 of 22, exit 0. **4 of 4**, the same four edits. Probed
  separately rather than credited to the file above: the two sets are the same shape, and a shape is
  exactly what a mutation probe stops being evidence for when one copy is assumed from the other.
- `ops\audit_corpus_provenance.py` - control 17 of 17, exit 0. **4 of 4**: the guard removed,
  `newline="\n"` turned to `"\r\n"`, the rise branch's `EXIT_FINDING` turned to `EXIT_CLEAN`, and the
  kept note replaced with a shorter one.

The BOM mutant is worth keeping in mind: with a BOM in front of the JSON, `ConvertFrom-Json` on the
decoded string fails, so the case reported `sites= note=` rather than a wrong number. That is the same
"read the blob's BOM with `git cat-file`" note the exemplar carries.

## After the change, measured on the live tree

`ops\audit-fixed-temp-names.ps1`, mark seeded to 11, no arguments:

```
PLAIN RUN EXIT=0
fixed-temp-names: PASSED, and the ratchet CAN tighten - fixed-temp-names: 10 finding(s), down from 11. NOT written.
baseline md5 unchanged
```

then `-Tighten` on the same content: exit 0, `"sites": 10`, 0 CR bytes, no BOM, one trailing LF.
`ops\audit-bare-replace.ps1`, mark seeded to 21 against a live count of 20: same two results, `20` recorded
under `-Tighten`, 0 CR. Both tracked baselines were restored with `git checkout --` afterwards.

## The full suite

`ops\run-gates.ps1` over the whole tree at `740c82af6` plus these changes: **exit 0, 383 gate(s) passed, 0
failed, 0 could not evaluate**, and `git status --short` empty of any baseline afterwards. It also said
*"this pass is recorded for reuse"*, which is the other half of the defect gone: while a gate run rewrote a
baseline mid-run, the checkout changed under it and no verdict could be recorded, so the next push paid for
every gate again.

That suite is NOT named as a harness above, on purpose. It verified the change; it produced no figure this
document rests on, and every session on this box edits it - it moved twice on the day this was written - so
citing it as an instrument would make this document UNQUALIFIED within the hour for a reason that says
nothing about whether the measurements hold. `ops\audit-conclusion-currency.ps1` reads a harness line and
the line after it, which is why the separation has to be physical and not merely stated.

## What was deliberately NOT done

**No new gate over this class.** A detector for "a write to a tracked baseline reachable without a flag"
would have to follow a path expression to a write through the AST and then prove reachability, which is
unsound in the direction that matters - it would go quiet on the next spelling rather than loud. And it
would be red on day one against `grocery\audit-json-readers.ps1`, which `.claude\rules\ops-and-gates.md`
forbids. The rule in that file plus these three conversions is what this change ships; the next ratchet
copies `ops\audit-write-only-reports.ps1`, which is where the convention is written down.

**No retro-fill of the exemplars.** The four `-Update`/`-UpdateBaseline` scripts are correct as they
stand; renaming their flags to `-Tighten` for consistency would churn every caller for no behaviour
change.
