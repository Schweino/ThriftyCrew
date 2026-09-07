---
description: Rules for gate, audit and shared-library code - exit codes, the guard contract, must-fire discipline.
globs: "ops/**, lib/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `ops/` or `lib/`

Loaded only when you touch a gate, an audit or a shared library. This is the machinery that keeps
everything else honest, so a defect here is silent by construction.

- **Read the EXIT CODE first and the tally second**, and do not decode the number: three vocabularies
  are live at once and the same `2` means "hard defect" in the guard-contract audits and "never ran" in
  the PLAN v3 batteries. Read the verdict LINE. [[exit-code-first-tally-second]]
- **A detector owes a `<NAME>-COMPLETE` marker as its LAST line** (`lib/guard-contract.ps1`). "No
  findings" and "died halfway" are indistinguishable without it, and this estate has been bitten by
  that shape at least five separate times.
- **A self-test that greps its own source cannot fail.** Build needles by concatenation, and never let
  a detector scan itself - `run-gates` and `audit-write-seam` both carry that exclusion for a reason.
  [[selftest-greps-its-own-source]]
- **Three fixture labels, three jobs** (Brad, 2026-09-07). `CLEAN TWIN` meant two OPPOSITE things
  here, so "add a must-fire and a clean twin" could be read either way:
  - `MUST FIRE` - the founding bug. The detector flags it, or the guard has stopped guarding.
  - `MUST NOT FIRE` - a legal input. The detector is SILENT, or it is crying wolf. **This is the
    negative assertion**, and it is what most of this estate's older `CLEAN TWIN` cases actually are.
  - `CLEAN TWIN` - an adjacent behaviour that **still works**. A POSITIVE assertion: the thing your
    fix was most likely to have broken on its way past.

  `ops/audit-fixture-vocabulary.ps1` fails a `CLEAN TWIN` whose assertion proves an absence. It reads
  the ASSERTION and never the prose, so labels whose sense lives only in their wording are out of its
  reach - it does not claim to have swept the estate.
- **A fixture built by string concatenation is not one argument.** `Test-Thing "a" + "b"` passes
  THREE positional arguments; a simple function binds the first and drops the rest into `$args`, so
  the case runs against a truncated line. Two must-not-fire cases passed that way on 2026-09-07 while
  being fed a fragment that could never have matched anything. Write fixtures as single-quoted
  literals with doubled inner quotes.
- **Never wrap a function call inline as `@(Get-Thing ...)`.** A comma-returned array reads as ONE
  element, so an empty result counts 1 and a real result binds the whole array to your loop variable.
  Assign, then wrap. Hit four times in one session on 2026-09-06.
  [[ps-json-array-collapse]], [[ps-null-count-is-one]]
- **Do not add a gate that is red on day one** for a backlog nobody is about to clear - it teaches
  people to ignore red. Use a ratchet with a high-water mark that may only go DOWN
  (`audit-write-seam`, `audit-fact-claims`, `audit-band-censorship`).
- **`git add` names what it owns.** `ops/audit-git-sweepers.ps1` fails a sweep.

Regime: this holds for gate and library code. Data-dependent audits live in the daily chain, not in
`run-gates`, and the split is deliberate - see `run-gates.ps1`'s own header.
