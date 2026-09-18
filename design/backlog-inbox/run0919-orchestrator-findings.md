# Backlog run 2026-09-18: findings the item agents reported that are not in the backlog

Collected by the orchestrator of the 2026-09-18 backlog run from the reports of the item subagents. Each
names the agent's item it was found under. Findings the run already fixed and filed elsewhere
(`run0919-board-wrong-cells.md`, `run0919-fixture-inputs.md`, `run0919-gate-stderr.md`,
`run0919-wave-p5-order.md`) are not repeated. Nothing here was verified a second time by the orchestrator
unless it says so.

## Reader-facing: 20 Walmart board entries rest on a store nobody sanctioned
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I165. `grocery/import-walmart-batch.ps1:168` stamps every row "Walmart Bellevue 68123" and never
reads the capture's `#tc-store` line, which `build-walmart-deals` refuses a capture without. On
`comparison-2026-09-17`, 20 of 3,188 store entries come from these batch rows, 12 of them cheapest-store
picks, on a store basis Brad never ruled (the ruled store is 5361 / 68137). Fixing it changes live board
cells, so the first rung is Brad's: retire the batch rows, re-stamp them, or give the importer the same
store-line refusal the builder has.

## Reader-facing: the deals page never shows "Doesn't carry"
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I132. `grocery/build-deals-page.ps1:153` reads not-carried as a `cells` list keyed `.id`, but
`grocery/not-carried.json` holds an `entries` list keyed `.commodity`, so the label never renders and readers
see "No price yet". Fixing it changes a page, so Brad's. Related: `grocery/derive-not-carried.ps1:116-120`
turns ONE empty Baker's search into a not-carried entry (12 of 24 entries, written 2026-08-21, unscheduled);
`pork-tenderloin` and `fresh-parsley` look doubtful for a Kroger store, and those entries hide the gaps from
`audit-coverage-gaps` for 90 days. A second, differently worded search is the missing check.

## Reader-facing: per-pound prices read as per-each, and multi-packs priced as one each
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I182. `graph/lib/units.py:496`: `per_unit(0.99, 'lb', 'each', ...)` returns `(0.99, 'each')`.
Two Fareway cantaloupe rows sit at $0.99 "each" (0.289x the median), inside what `flag_outliers` misses; not
the reader's cheapest on 2026-09-17 (Walmart $2.50). `bar-soap` and `bottled-water` price whole multi-packs as
one each, inflating the median in the harmless direction. A fix changes which rows can price a cell.

## Fareway's selector drops the sale end date, so sale dating never fires on the daily capture
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I124. `grocery/select-fareway-shop.ps1:429` drops `sale_ends_days` and `sale_note`: on 09-11, 143
of 2,392 candidates carried a sale end and 0 of 44 selected rows kept it, so `build-fareway-regular.ps1:582`
never fires. Fixing it changes sale dating on the board. Also: the newest Fareway storefront capture in the
main checkout was from 2026-09-12 when read on 09-18.

## The price-alert email leaves an orphan draft on every failed send, and the alert state is unguarded
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found under I105 and I161. `grocery/send-price-alerts.ps1:131`: when the PUT that publishes the alert fails,
the draft POSTed a moment earlier is never deleted (lines 143-147 only print SEND FAILED), so each retry leaves
another draft in Ghost. I161's held half is the same script: an unreadable state file is treated as empty
(every subscriber re-alerted) and a missing price mutes an item forever. Both change what members are emailed.

## The heartbeat's dedup signature changes every run, so a stale-task page repeats
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

Found under I125. `grocery/health-heartbeat.ps1:391` puts the task's age in hours into the TASK STALE text and
`:519` hashes that text as the dedup signature, so the signature moves every run and the page can repeat at
every heartbeat. The alert log shows silent-death pages on 09-12, 09-13, 09-14, 09-17 and 09-18.

## post-publish review verdicts are thrown away by the daemon, and none has run since 2026-09-03
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

Found under I164. `meal-prep/pipeline/hunt-daemon.py:7059` discards the reviewer's answer and writes the word
"reviewed" into the ledger; its one live review (wave 8, 2026-08-27) lost its verdict. Fix: write the
reviewer's status line, with a daemon self-test case.

## Gate and audit machinery: six small defects found in passing
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

- `grocery/test-precedence-ladders.ps1` fails 7 of 8 at HEAD (found under I183): its `%TEMP%\tc-precedence-fixture`
  sandbox has no `lib\`, so `rollback-ttl-lib.ps1:65` cannot load `lib\ledger-lock.ps1`. The whole-lib sandbox
  rule, one missed site.
- `grocery/audit-json-readers.ps1` rewrites the TRACKED `grocery/out/json-readers.json` on a plain run (I174),
  against "a plain run of a ratchet never writes its mark".
- `grocery/audit-store-registry.ps1` exits 2 on main (I185): two 3-store fixture strings in
  `grocery/test-auditors.ps1` (line 1376 from 5d1968736, 1405 from 499c3fd0c6) are neither registered nor
  marked `store-subset-ok`. Not in the pre-push gate.
- `ops/audit-write-only-reports.ps1` exits 2 by hand (42 families against a baseline of 41, a new `out\x.json`)
  while the pre-push gate passes (I156). Hand run and gate disagree, unexplained.
- `meal-prep/pipeline/find-similar.ps1` and `make-saturation.ps1` self-tests FAIL (exit 2, "the digest exists")
  in an unseeded worktree instead of reporting BLIND, and push-main's pre-lock gate does not seed first (I206).
- Six audits lack a `SCOPE OF A CLEAN REPORT:` line (I178): arg-binding, fixture-vocabulary, run-log-claims,
  source-control-bytes, threshold-register, write-only-reports; `ops/audit-fixed-temp-names.ps1:7` still says
  "A reported site is real".

## A harness change a MEASURE doc names cannot land cleanly through push-main
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

Found under I171 and I187. `ops/audit-conclusion-currency.ps1` demands a "Re-read at commit" line citing a commit
at or after the harness change, which exists only locally until push-main's rebase renames it; it works only
when no rebase happens. Since 7aeb653f0 the audit already classifies a cited BLOB id as content, so accepting a
re-read that cites the harness blob would close this. Related: `ops/push-main.ps1:143` starts run-gates with an
inherited console, so any gate's unredirected git error reaches the console and never the saved log.

## Graph: stale filed-under edges are never removed, and a missing graph.db is silently recreated
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

- `graph/import/importers.py` (~1098, found under I193) never removes an old "filed under" edge: 3,437 of
  38,748 such links are no longer in the current identity files (Birds Eye Steamfresh Sweet Peas still filed as
  canned peas).
- `graph/lib/graphdb.py:64-79` (I213) creates graph.db when missing, so an `open_db()` script run in a
  worktree (none of 66 has one) builds a fresh db and restores learning into it instead of failing. Inferred.
- `graph/lib/graphdb.py:492-494` (I161): restoring `cell-state.json` skips bad rows silently but counts them
  restored (probe: 3 counted, 1 in the table).
- `graph/import/importers.py:848-851` (I211) reports 606,442 unresolvable rows per run against 310,447 resolved;
  not checked whether that is expected.
- `graph/learning/ingest_hunter_events.py:332` (I119) silently skips an unparseable hunter-gold line.

## Stale facts in standing guidance and data
`OPEN` `run-0919` `2-WAY` `RUNG1 DOC`

- `.claude/agents/recipe-hunter-pricer.md:249` (+ its prompt-backup copy) and
  `grocery/PLAN-search-verdict-contract-2026-08-15.md:97` name the Omaha Sam's as 13130 L St; the session has
  read 15429 Blackwell Dr since 2026-08-15 (I124).
- run-gates reports "24 slot(s) of a machine-wide 24" while CLAUDE.md and ops-and-gates.md say 10 (I160).
- `ops/scheduled-tasks/tc-grocery-capture-watchdog-0930.xml` is still named 0930; the task fires at 10:30 (I45).
- `grocery/audit-script-census.ps1:107` says send-friday-email runs as task "SMP Friday Email (draft)"; no such
  task is registered (I198).
- The live site runs Ghost v6.64; every repo script sends `Accept-Version: v5.0` (I167). Endpoints in use still
  answer 200.
- `meal-prep/food-macros-db.json` broccoli row cites an NDB number as an FDC id (I137); FDC's "full" format drops
  nutrient names on some Branded records, which `meal-prep/pipeline/fdc_lookup.py:149` would read as blank.

## Untracked and ungitignored files the bot could commit, and one the worktrees never get
`OPEN` `run-0919` `2-WAY` `RUNG1 DOC`

- `grocery/out/friday-email.stamp` and the new `friday-email.invoking` marker (I198).
- `meal-prep/db/dedup-paired/cases.jsonl`, the frozen dedup cases (I48), fingerprint `34be0270169e593c`.
- `TC_WRITE_JOURNAL` in the user environment points at the MAIN checkout's `ops/ghost-journal.jsonl`, so a
  shell test of ghost-lib from any worktree writes the live journal unless it clears the variable (I105).

## Cadence gaps: verification samples and Family Fare's cursor date
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

- No whole-board verification sample verified since 2026-08-15; the 09-02 sample was drawn and never verified
  (I133).
- `grocery/pull-regular-familyfare.ps1:1141` advances the shared cursor without a date, so
  `capture-cursor.json` has no `FamilyFare_last` and the one-slice-per-day check reads nothing (I161); `:1107`
  stamps every refused term as indistinguishable from throttling though 597-613 detects the throttle code (I132).
- The daily-ratchets green stamp of 09-18 03:17 was written at `59b7fefa5`, a local graph-nightly commit not on
  origin/main, so a green daily stamp can describe a stale checkout (fixture-inputs agent).
- The daily chain has logged "match-soundness is BLIND (exited 1 without its completion marker)" since 09-13,
  while standalone runs end with the marker (board agent).
- `grocery/audit-household-in-food.ps1:51` has no "scent" word and `:54` sweeps only `out\regular`, never the ad
  files, so it could not see the Dawn row; no self-test (board agent).
- The band-censorship ratchet's cutoff is relative to the median (`grocery/audit-band-censorship.ps1:150`), so
  another store's sale can break and heal it (board agent).
- Three recipe cards lose a structured-data block on rebuild, untraced: creamy-tuscan-chicken-skillet,
  scalloped-potato-turkey-casserole, turkey-alfredo-rotini-bake (I172).
