# Which of our written rules actually enforce themselves

Audit date: 2026-09-12. Scope: every `- **...**` bullet in `CLAUDE.md` and `.claude/rules/*.md`
(62 bullets), classified against the 70 scripts `ops/run-gates.ps1` actually wires in.

Prompted by the 24-hour review: nine lessons became gates yesterday and are working, while one
rule written on 2026-08-26 sat unread for two weeks until it became a gate, one recurred the same
day it was written, and one spread by being copied. The question this answers is which of the
remaining prose is carrying its weight and which is waiting to be a gate.

## Method and its limits

Each bullet is read and assigned one of three classes. The classification is by hand and is
UNSOUND in the same sense our detectors are: it finds what it recognises. A bullet marked
JUDGEMENT is a claim that I could not see a mechanical test for, not a proof that none exists.

- **GATED** - a wired gate fails a push that breaks it.
- **GATE-ABLE** - mechanically decidable from source or data, and nothing checks it today.
- **JUDGEMENT** - needs a person or a model to decide. Prose is the right channel; it stays.

Counts: 62 bullets. **21 GATED, 18 GATE-ABLE, 23 JUDGEMENT.**

So a little over a third of the written rules already enforce themselves, and another third
could. The remaining third is what the prose channel is genuinely for.

## GATE-ABLE, ranked by (cheapness x how much it has already cost)

These are the ones worth building. Ranked with the cheap, already-bled ones first.

### Tier 1 - cheap AST checks over a defect this estate has already paid for

1. **An unread `WaitOne(n)` result.** ops-and-gates says a timed lock wait is a BRANCH. The
   founding bug rewrote the whole triage queue unlocked because one script stored the answer and
   never read it. An AST scan for a `WaitOne` whose result reaches no conditional is a few dozen
   lines and admits no false-negative spellings worth worrying about. Highest value on the list.

2. **A detector with no `SCOPE OF A CLEAN REPORT:` line.** The rule already says a new detector
   owes that line the way it owes its `-COMPLETE` marker, and the marker half IS gated while this
   half is not. A file-header grep over `ops/audit-*.ps1`. Nearly free. Baseline measured today:
   **37 of 43 carry it, 6 do not** - arg-binding, fixture-vocabulary, run-log-claims,
   source-control-bytes, threshold-register, write-only-reports. So it can be wired as a ratchet at
   6 and is not red on day one, or the six can be written and the gate set at zero.

3. **A self-test asserting an UPPER wall-clock bar.** Two of these blocked pushes that touched
   neither file, which is the exact red that teaches `--no-verify`. Detect an assertion comparing
   an elapsed/stopwatch value against a constant inside a self-test body. The replacement pattern
   already exists in `lib/concurrency-probe.ps1`, so the gate has somewhere to point.

4. **`VariablePath.UnqualifiedPath` used anywhere.** Reads as `$null` under PS 5.1 and fails
   silently in a `-match`. This is a literal string grep with one right answer.

   **This one found a live site while the audit was being written.** Four files mention the name:
   three are comments warning against it, sitting directly above the correct UserPath-stripping
   code. The fourth, `ops/prepush-test-auditors.ps1:485`, actually CALLS it, with a fallback to
   UserPath when it comes back empty. Because it is always empty under PS 5.1 the fallback always
   fires, so that file never strips the scope prefix the other three strip - `$script:x` and `$x`
   read as two different names there. What that changes downstream is NOT verified here, and it is
   NOT repaired in this audit because the file sits on the push path; it is named so the repair is
   a decision rather than a rediscovery. It is also the argument for the gate: three authors wrote
   a warning comment about this exact call, and the fourth call was written anyway.

5. **`@(Get-Thing ...)` - a command call wrapped inline in an array subexpression.** Recorded as
   hit four times in one session. AST-decidable exactly: an ArrayExpression whose sole element is
   a CommandAst.

### Tier 2 - real work, real payoff

6. **A harness that runs a child's self-test without reading BOTH its exit code and its verdict
   line.** run-gates enforces this for suites it discovers; a harness that spawns its own children
   is outside that, which is how one fall-through passed. Eight sites in one file needed fixing by
   hand and nothing stops the ninth.

7. **A hand-listed library copy into a sandbox.** Four sites are named in the rules as still
   standing and explicitly not swept, and the defect they carry is silent: the script loads, the
   missing library prints to a discarded stderr, and every case passes. Detect a sandbox copy that
   names individual `lib/*.ps1` instead of the directory.

8. **A rate printed without its denominator.** Swept by hand once (45 computations across 25
   files, 42 compliant) and never gated, so the three survivors and every new one are unchecked.
   Build it as a ratchet, not a bar, per the day-one-red rule.

9. **A self-test in a shape the must-fire census cannot see.** 17 files and 230 must-fire lines
   sit outside every shape `Get-SelfTestBlock` reads, and those fixtures can lose their assertions
   and stay green. The gate is a census-of-the-census: a file with self-test-looking content that
   the census did not enrol.

10. **An alias-shadowing helper name.** `audit-cmdlet-shadow` holds a pinned list of cmdlet names;
    the founding bug here was the ALIAS `R`, and aliases beat functions. Extending the existing
    gate's name list is cheaper than a new gate.

### Tier 3 - decidable but lower yield
11. A ledger read-modify-write whose READ sits outside the lock.
12. A string comparison with `-ne`/`-eq` on text that arrived from outside (precision will be poor).
13. A `known-wrong` / board-corrector edit that names a retire_when outside the closed vocabulary.
14. A content workbook regenerated values-only (count live formula cells before and after).
15. A paywall guard that checks only the cosmetic direction.
16. A tuning constant added without a `docs/CONTROL-CONSTANTS.md` entry.
17. A threshold added with no floor, where the producer stopping would go quiet.
18. A measurement document that names a harness whose file has moved since (partially covered by
    `audit-measurement-provenance`; the gap is documents, not code).

## JUDGEMENT - 23 bullets that stay as prose

These are reference facts and calls a detector cannot make: the 375px mobile look, Brad's voice,
what `cohort` means here, which Aldi a price came from, Ghost's 422 semantics, the three-fixture
vocabulary's intent, when a mutation probe is worth running, whether a gate would be red on day
one. Prose is the correct and only channel for these, and they are not the reason the channel is
expensive.

## The finding behind the finding

The 21 GATED bullets are the expensive ones - they are also the longest, because each carries the
measurement that produced it. They are paid for on every turn and enforced by a gate that does not
need them. That is the duplication worth attacking after the Tier 1 and Tier 2 gates exist, and
not before: the prose is the only record of WHY each gate exists, so it must not be cut until the
gate is the thing actually catching the defect.

Nothing in this document is a change. No gate here is red on day one, because none of them is
built yet; each will need its own baseline taken before it is wired.
