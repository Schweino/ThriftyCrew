## the push convergence report counts every hook-refused row as a ref it could not read

`OPEN` `2-WAY` `RUNG1 BUILD`

**Source.** Building W0.6 of `design/PLAN-push-derived-conflicts-2026-09-23.md` (the hook's refusal rows,
`ops/record-hook-refusal.ps1`), 2026-09-23.

**What is wrong.** `ops/probe-push-convergence.ps1`'s default report (its last block, the ledger read above
`Write-TcConvergenceReport`) passes EVERY ledger row to `Measure-TcPushRows`, whatever its event. W0.6 adds rows with
`event: hook-refused`, whose `base` and `grant` are empty on purpose: a refusal never waits for the lock, so there is no
ref to compare. `Measure-TcPushRows` counts a row without both shas as `Unknown`, which that report describes as a ref
that could not be read. So from the first refusal after W0.6 lands, `Rows` and `Unknown` in the convergence report grow
with refusals, and read as could-not-read rows. The wait distribution and the moved rate are not affected (a refusal
row has `waitMs` -1 and no shas). Confirmed by the writer's own CLEAN TWIN, which asserts such a row is counted UNKNOWN
and never as a wait. The `-Cost` section is not affected: it already keeps only `push-main` rows and counts the rest
as not costed.

**First rung.** In the W0.3b lane (the file's owner), keep the convergence block's `Measure-TcPushRows` input to the
events that queue for the lock (`hook-lock`, `push-main`), and print `hook-refused` rows as their own count beside it.

## a hook-lock row written through the main checkout's holder names the main checkout, not the one that pushed

`OPEN` `2-WAY` `RUNG1 MEASURE`

**Source.** Reading `ops/hold-push-lock.ps1` while building W0.6 of `design/PLAN-push-derived-conflicts-2026-09-23.md`,
2026-09-23.

**What is wrong.** `ops/hold-push-lock.ps1` records `checkout = $repo`, and `$repo` is the parent of the holder
script's OWN directory. `ops/hooks/pre-push` falls back to the MAIN checkout's copy of the holder whenever the pushing
checkout has none, which is every checkout whose tree predates the holder (added 2026-09-11). So a hook-lock row from
such a worktree names `C:\Codex\ThriftyCrew`, the main checkout. Read-only count over the production ledger's files for 2026-09-21 to
2026-09-23: 32 of 85 non-sandbox hook-lock rows name the main checkout. That count mixes real main-checkout pushes
with fallback rows, and nothing in the row can split them. It matters to W0.3b step 6, which counts main-checkout
plain pushes that passed every hook check from exactly these rows. W0.6's own rows take the pushing checkout from the
hook (`-Checkout "$repo"`), so they do not have this defect.

**First rung.** Measure the split: for each hook-lock row naming the main checkout, check whether an origin/main
update within 15 s came from a push whose reflog or push-main row names another checkout. Then, if the fallback share
is real, pass the pushing checkout from the hook to the holder (a new `-Checkout` argument, only to a holder whose
source names it, the way the hook already hands `-PushRefsFile` only to a gate that accepts it).

## the refusal writer's splice road is dead code once W0.1 lands

`OPEN` `2-WAY` `RUNG1 BUILD`

**Source.** `ops/record-hook-refusal.ps1`, W0.6 of `design/PLAN-push-derived-conflicts-2026-09-23.md`, 2026-09-23.

**What is wrong.** Nothing yet. The writer has two roads to one row: `Write-TcPushRow -Fields` when
`lib/push-ledger.ps1` declares it (W0.1, built on `feat/pd-ledger` and not landed when W0.6 was built), and a splice
of the same fields onto `New-TcPushRowText`'s row until then. Both were run: the writer's self-test passed 13 of 13
against origin/main's library (the splice road) and 13 of 13 against the `feat/pd-ledger` library blob `99d38754`
(the fields road), and the row they write has the same fields in the same order. Once W0.1 is on origin/main the
splice road, `Join-TcRefusalRowText` and its collision case can never run.

**First rung.** After W0.1 lands, delete the splice road and its case in the same commit, and drop the writer's
literal case count by one.
