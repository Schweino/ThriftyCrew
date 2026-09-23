## eleven ratchets still write a new mark on a plain run when their baseline is missing, and seven of them also when it is unreadable

`OPEN` `queue-6` `2-WAY` `RUNG1 BUILD`

**Source.** W1.2 of `design/PLAN-push-derived-conflicts-2026-09-23.md` (the currency lane, 2026-09-23), step 5: "Census,
not a sweep ... Fix only this one, and file the others as one backlog inbox finding." W1.2 made
`ops/audit-conclusion-currency.ps1` fail closed: a baseline that is ABSENT or UNREADABLE now exits 3 on a plain run and
on `-Tighten`, writes nothing, and only `-Accept` writes one. Before that, the catch set `$base = $null` and
`if ($Accept -or $null -eq $base)` WROTE the current count as the mark and exited 0, so a botched hand resolution of the
JSON (conflict markers from a rebase) silently accepted whatever count the push carried, a rise included.

**Measured.** A grep of `ops/*.ps1` and `grocery/*.ps1` on 2026-09-23, over origin/main `f33d11829` plus this lane's
branch, for a branch where a missing or unreadable baseline leads a PLAIN run to write one. Each site read by eye.

- A `$null` base on ABSENT or UNREADABLE (the read sits in a try whose catch sets `$null`), then a write:
  `ops/audit-arg-binding.ps1:356`, `ops/audit-lesson-rate-claims.ps1:384`, `ops/audit-source-comment-strip.ps1:228`,
  `ops/audit-write-only-reports.ps1:354`, `grocery/audit-board-mojibake.ps1:231`,
  `grocery/audit-band-censorship.ps1:588` (the `'first'` verdict), `grocery/audit-json-readers.ps1:236` (`'first'`).
  7 files.
- ABSENT only, then a write (an unreadable file throws at the `[int]` cast, so it fails loud, not open):
  `ops/audit-full-path-excludes.ps1:609`, `ops/audit-ruling-drift.ps1:217`, `ops/audit-write-seam.ps1:222`,
  `grocery/audit-ad-forecast.ps1:402`. 4 files.
- Already fail closed, the shape to copy: `ops/audit-mustfire-census.ps1:536`, `ops/audit-typed-param-shadow.ps1:596-609`,
  `ops/audit-cross-module-reach.ps1:500`, `ops/audit-measurement-provenance.ps1:172`.

The census is UNSOUND: it found the spellings it grepped for (`$null -eq $base`-style tests and `-not (Test-Path` on a
baseline path), and a ratchet that decides "no baseline" some other way is out of its reach.

**What to do.** Per file, the W1.2 shape: tell ABSENT, UNREADABLE and READ apart; on the first two a plain run and
`-Tighten` exit 3 with `blind=baseline-missing` or `blind=baseline-unreadable` and write nothing, and only `-Accept`
writes. Each change carries its own MUST FIRE (conflict markers, bytes unchanged) and CLEAN TWIN (`-Accept` over an
absent baseline writes it). `Read-CcBaseline` in `ops/audit-conclusion-currency.ps1` is the exemplar; a shared helper in
`lib/ratchet.ps1` would be the one-copy version, and is a design choice for whoever takes this. Not a sweep in one
commit: several of these run in `run-gates` on every push, so each needs its own fixtures and its own re-reads.

## audit-write-only-reports reads 35 write-only families against a mark of 34 on this tree, and none of the change is this lane's

`OPEN` `queue-6` `2-WAY` `RUNG1 READ`

**Source.** Found by the currency lane on 2026-09-23 while running every source-reading static audit over its own
change: `ops/audit-write-only-reports.ps1` exits 2, `RATCHET BROKEN - 35 write-only family(ies) now, baseline 34`. It is
a `daily = $true` entry in `ops/run-gates.ps1`, so it does not stop a push; it reddens the daily ratchets run.

**Measured.** From a linked worktree at origin/main `f33d11829` plus this lane's three commits (none of which writes or
reads an `out\*.json` family), against the committed `ops/out/write-only-reports-baseline.json` (34 names, last set by
`574722dab` on 2026-09-22): two families are new, `match-worklist` and `regular-<date>`, and one is gone,
`research-worklist`, so the count moved by one. Which commit made `match-worklist` and `regular-<date>` write-only was
not traced.

**What to do.** Read the two new families: give each a reader, or record it as human-read and move the mark with
`-Accept` in the commit that explains why. Check the daily ratchets run's page for the same count before acting, in
case another lane already owns it.
