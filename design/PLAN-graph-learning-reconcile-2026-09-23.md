# PLAN: a learning verdict committed from any checkout survives the next export (2026-09-23)

Brad's decision, 2026-09-23: *"Lasting fix first: plan and build a reconcile step so graph.db takes newer tracked
verdicts from any checkout, then land the 69 through it."* This plan is written before the code. The bars in
section 6 were written before any reconcile ran.

## 1. The defect, verified at the code

`graph/lib/graphdb.py` `export_learning()` writes five learning tables from the DATABASE over the tracked JSON
"after every write", and `import_learning()` restores tracked JSON only into a FRESH database (`INSERT OR IGNORE`,
fired when every learning table is empty). Nothing ever moves a tracked row INTO an existing database. So a verdict
ingested in a worktree and committed to `graph/learning/proposals.json` and `approved-patches.json` is reverted by the
main checkout's next export, because main's `graph.db` still holds those rows as `proposed` with no patch rows.

W6.4 / D13 of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` rules that graph ingest runs in a
worktree and never in the main tree. So the sanctioned road for a human verdict is exactly the road that loses it.

Measured, not assumed:
- The D13 helper's stand-in probe (scratch DB restored from the pre-ruling JSON, one `export_learning()`): 69 of 69
  rulings back to `proposed` and 69 of 69 patch rows dropped. Row counts matched again afterwards, which is why a count
  check cannot see this (`.claude/rules/graph.md`, "An agreeing number escapes scrutiny").
- The main checkout's `graph.db`, copied read-only today at 03:2x (source mtime 2026-09-22T21:37:13, 453,259,264
  bytes), against the landing JSON (the rulings commit), row by row: `learning_proposals` 313 in the DB and 312
  tracked, exactly 69 rows differ and only in `status` (18 `proposed` to `accepted`, 51 `proposed` to `rejected`), 1 row
  only in the DB; `approved_patches` 186 against 255, the 69 new rows only tracked, 0 rows differ; `eval_runs` 53
  against 48, 5 only in the DB, 0 differ. Harness: `gr_prediff.py` (scratch, described in section 6).

## 2. The rule: reconcile is a JOIN on decision evidence, never an overwrite

Before every export, the database takes from the tracked JSON what the JSON can PROVE is further along, and keeps
everything else. Stated per table, one rule each:

| Table | Precedence | Evidence |
|---|---|---|
| `learning_proposals` | A row the DB lacks is inserted. A row both hold with a different `status` takes the TRACKED status only when the tracked side's decision evidence for that proposal strictly contains the DB's; otherwise the DB's status stands. | The evidence of a proposal is its `approved_patches` rows: each row's id, its `shadow_verdict` when it is not `not_run`, and its `applied_at` when set. A reviewed status over `proposed` wins only because it arrives WITH a patch row the DB lacks. |
| `approved_patches` | Union by id. A row the DB lacks is inserted, after its proposal. A row both hold takes the tracked row's apply fields (`shadow_verdict`, `shadow_before_json`, `shadow_after_json`, `applied_at`, `applied_by`) only when the tracked row has moved forward and the DB row has not. | The row is append-only: `id` is a hash of (proposal, verdict, payload), so its verdict and payload are fixed by its key. Its only moves are `not_run` to a terminal shadow verdict and `applied_at` from null to a time. |
| `eval_runs` | Union by id. A row the DB lacks is inserted; nothing else changes. | Rows are immutable: `id` is a hash of (run time, model, prompt version, context), and `score.py` only inserts. |
| `cell_state` | Not reconciled. The DB wins, exactly as today. | Derived: `graph/pipeline/state.py` rebuilds it with `DELETE` then `INSERT` from `price_observations` on every import. A tracked row from another checkout is a derivation from another observation set, not a decision. |
| `question_verdicts` | Not reconciled. The DB wins, exactly as today. | Derived the same way (`build_question_verdicts`, `DELETE` then `INSERT`); it records the match status a question earns, and no reviewer writes it. |

Four rules hold across all three reconciled tables:

1. **Nothing is ever deleted from the DB.** A row only the DB holds is kept, because the JSON may be stale (the 1
   proposal and 5 eval runs only main's DB holds today are exactly this).
2. **A DB-side decision newer than the tracked one is never overwritten.** A stale JSON's evidence is a subset of the
   DB's, so the join leaves the DB as it is. This covers the case a naive "reviewed beats proposed" rule gets wrong:
   `stage2_review.py --requeue-stuck` demotes `accepted` back to `proposed` and marks the patch `requeued`; an older JSON
   still saying `accepted` must not undo it, and does not, because the DB's evidence (`requeued`) is the larger set.
3. **An arrived verdict carries its status.** When a patch row arrives from the tracked side and its proposal is still
   `proposed` on both sides, the status is set from the newest arrived patch's verdict. No writer leaves a reviewed,
   un-requeued, unapplied patch beside a `proposed` status (`ingest()` sets both in one transaction and `requeue_stuck()`
   marks the patch `requeued`), so this is the shape a git merge leaves when it keeps the patch file's new row and loses
   the status line in a `-X theirs` hunk (section 4).
4. **An unreadable tracked file refuses the export**, before anything is written. A learning file with conflict markers
   holds BOTH sides of a merge; exporting over it silently resolves the merge for the DB, which is this defect. The error
   names the file. A MISSING file is not unreadable: there is nothing to adopt and the export writes it, as today.

**Equal evidence, different status, is UNDECIDED, and the DB keeps its own.** Three transitions leave no patch evidence
(read from `stage2_review.py`, the only writer that updates either table, found by grep over graph, meal-prep, grocery,
ops and lib): `--apply` holding a patch whose commodity has no gold coverage, `--apply` holding an `add_gold` or
`tighten_prompt` patch, and a re-ingest of the same verdict (same patch id, `ON CONFLICT DO NOTHING`). A change of that
kind made in another checkout cannot be ordered without a clock, so it is counted as undecided and the DB keeps its
status. The two holds re-derive on the next `--apply`; the re-ingest is the one genuine residual.

The state machine the evidence is read from:

| Writer | Status move | Evidence left |
|---|---|---|
| `ingest()` | `proposed` to accepted, rejected, modified, deferred or held_for_human | a new patch row |
| `shadow_and_apply()` applied | accepted or modified to `applied` | `applied_at`, shadow `no_regression` |
| `shadow_and_apply()` regression | status unchanged | shadow `regression` |
| `shadow_and_apply()` holds | accepted or modified to `held_for_human` | none |
| `requeue_stuck()` | accepted or modified to `proposed` | shadow `requeued` |

**Why a join on evidence and not a three-way merge or a timestamp.** A three-way merge (store what this DB last
exported per row, take whichever side moved since) was considered and rejected: the tracked JSON here moves BACKWARDS
(a `rebase -X theirs` hunk, a checkout of an older version, an autostash), while the DB moves only forward through
`stage2_review.py`. A three-way merge reads a JSON that went backwards as "tracked changed" and reverts the DB, which is
this defect mirrored. A `status_changed_at` column was rejected too: every writer must set it (a ninth hand-placed
convention beside the eight export calls), the 312 existing rows have none, and the rulings commit carries none, so the
D13 landing would fall back to evidence anyway. The join is idempotent and order-free: running it twice, or in either
checkout first, gives the same database.

## 3. Where it runs, and which runs it touches

Inside `GraphDB.export_learning()`, before its first write, in one savepoint: every tracked file is read first, then
the DB takes what it proves, then the export writes. So all eight hand-placed `export_learning()` calls and
`export_json()` (import_all) reconcile by construction, and no checkout's export can erase a committed verdict. The
logic is its own module, `graph/lib/learning_reconcile.py`, so it can be rewritten whole.

Which runs (memory `learning-must-be-per-batch-not-nightly`): every export touches it - the nightly `stage1_analyze`
and `import_all`, the daily chain's `import_all` (graph-gates lane), the per-batch human verbs `stage2_review.py
--ingest/--apply/--requeue-stuck`, `score.py`, `review_escalations.py --ingest`, and `rebuild.py --drill`. It does not
touch the immediate half of learning (the ingredient resolutions ledger and `ingredient-events.jsonl`).

Recording: the counts are on `db.last_reconcile`. When anything was adopted, inserted, repaired, undecided, in conflict
or refused, and the target is the live mirror (the export's directory is `GRAPH_DIR`), one `learning_reconcile` decision
event goes into the provenance trail. The library prints nothing: a stderr line under a caller running with
`EAP=Stop` is a terminating throw (`.claude/rules/ops-and-gates.md`, "A catch around a native redirect is not a guard").

## 4. What happens to a landed verdict across the ~07:00 bot run

Measured on the real blobs, first with a scratch `gr_botsim.py` before this plan was written and then again through
the committed harness `graph/bench/probe_learning_reconcile.py --bot-sim` (identical output), with main's state read
at 03:24 today:
- Main's `HEAD` is `54bff6167`, the 2026-09-22 graph nightly, whose push failed; it is 62 commits behind origin/main and
  is the ONE local commit the bot will replay. It adds one proposal (12 lines) to `proposals.json` and does not touch
  `approved-patches.json`. Main's working copies of both files are byte-equal to that commit's.
- `capture-run.ps1` rebases with `-c rebase.autoStash=true rebase -X theirs origin/main`. Replaying `54bff6167` onto the
  landing: **0 conflicts for `-X theirs` to decide, 69 of 69 statuses kept, 69 of 69 patch rows kept.** The autostash
  re-apply of main's working copy over that result: **0 conflicts, the same 69 and 69.**
- So after the bot, main's working JSON carries the rulings and its DB does not. TODAY its next export reverts them.
  With this change its next export adopts them.

What main will do, in order:
1. Until main rebases, nothing: its JSON does not carry the rulings, and its exports keep writing `proposed`, as the
   file already says.
2. The ~07:00 `capture-run` rebase brings the code and the rulings in ONE rebase, because they land in one push with
   the code commit first. A rebase either applies both or aborts, so the rulings can never reach main without the code
   that protects them (`.claude/rules/ops-and-gates.md`, "Write the POINTED-TO object before the object that points to
   it"). A process that imported the old `graphdb` before the rebase and exported after it would still revert them;
   none of the eight writers is long-lived (each is a stage subprocess), and `hunt-daemon.py` does not import graphdb.
3. The first export after it (whichever graph writer runs first, normally the daily chain's `import_all` about 08:30)
   adopts the 69 statuses, inserts the 69 patch rows, keeps main's 1 DB-only proposal and 5 DB-only eval runs, and writes
   JSON whose landed rows are unchanged. Section 6's verification runs exactly this on the copy.
4. The graph nightly about 21:30 commits `graph/learning`; its diff against origin carries main's own DB-only rows and
   no reversion.

What the bot can still do: a future `-X theirs` hunk can drop a status line while the patch file keeps its new row;
rule 3 recovers that. A checkout of an older version of BOTH files before main's first adoption leaves nothing to adopt;
after the first adoption the DB holds the verdict and a backwards JSON is dominated, so it is kept.

**One thing it can drop, and it is not a verdict.** The rulings commit also adds `graph/provenance/2026-09-23.jsonl`
with the one `stage2_ingest` event, and every earlier day's shard was first added by the bot. If main writes today's
shard and commits it before it rebases (the 08:00 daily pipeline does, when the 07:00 run has not already rebased),
the rebase meets an add/add on that file and `-X theirs` keeps main's lines and drops that event: reproduced in a
scratch repo, exit 0, the upstream line gone. The verdicts are unaffected (they live in the two learning files), and
main's own reconcile logs a `learning_reconcile` event naming the 69 adopted ids when it takes them. Concurrent
appends to one day's shard from two checkouts meet the same `-X theirs` rule whichever lands first; that is the
provenance trail's standing shape, named here and not changed.

## 5. Fixtures (in `graph/lib/graphdb_selftest.py`, hermetic, per-run temp directory)

- **MUST FIRE, the D13 shape**: a DB that predates two verdicts in tracked JSON, one export: each verdict survives in the
  DB and in the exported file, and each patch row exists in both.
- **MUST FIRE, the counts say so**: the same export reports 2 statuses adopted and 2 patch rows inserted.
- **MUST FIRE, a requeue made elsewhere is adopted**: tracked `proposed` with its patch `requeued` over a DB `accepted`
  with the patch `not_run` (evidence, not "reviewed beats proposed").
- **MUST FIRE, an arrived verdict carries its status**: tracked and DB both `proposed`, a patch row arrives: `accepted`.
- **MUST FIRE, an unreadable tracked file refuses**: conflict markers in `proposals.json`, the export raises and no
  mirror file changes by a byte.
- **MUST NOT FIRE, a DB-side decision newer than the tracked row is kept**: DB `rejected` with its patch over a tracked
  `proposed` with none.
- **MUST NOT FIRE, a DB-side requeue is kept** against an older JSON still saying `accepted`.
- **MUST NOT FIRE, equal evidence keeps the DB and counts it undecided.**
- **CLEAN TWIN, a fresh-DB import is unchanged**: `import_learning()` into a fresh DB restores every row and its counts.
- **CLEAN TWIN, an export with nothing to reconcile is byte-identical to today's**: all five files equal the bytes the
  pre-change algorithm writes, and the database is not written.
- **CLEAN TWIN, a row only the DB holds survives**, and an eval run only the JSON holds is inserted.

## 6. Bars, written before the run

- Fixtures: every case above passes, the suite prints its verdict line, exit 0, and the case count equals the literal
  count in the file.
- Mutation (temp mirror, originals md5-identical afterwards): removing the reconcile call from `export_learning()` turns
  the D13 MUST FIRE red; making the adoption test non-strict (superset or equal) turns the undecided MUST NOT FIRE red.
- Verification on a read-only copy of the main checkout's `graph.db` against the landed JSON, through
  `graph/bench/probe_learning_reconcile.py` (reconcile plus export into a scratch directory):
  - 69 of 69 proposal statuses equal Brad's ruling (18 `accepted`, 51 `rejected`), checked per id;
  - 69 of 69 patch rows present, one per id, verdict matching the ruling, reviewer "Brad via approvals page 2026-09-12";
  - 0 other rows in the three reconciled tables changed; the 1 DB-only proposal and 5 DB-only eval runs kept;
  - every landed row of `proposals.json` and `approved-patches.json` present and equal in the exported file;
  - a second export: every file byte-identical to the first, and the reconcile counts all zero.
- Real-data clean twin: a DB rebuilt from origin/main's JSON with `graph/lib/rebuild.py`, exported into a scratch
  directory, gives 5 of 5 files byte-identical to origin/main's blobs.
- Re-validation of the 69 against origin/main's `proposals.json` before landing: each still `proposed`, its payload,
  target and kind byte-identical to the version Brad ruled against; any that moved is skipped and named.
- Gate: `ops\push-main.ps1` exit 0 with its gate line read, never `--no-verify`.

Measured BEFORE this plan was written, so inputs, not bars: `gr_prediff.py` (section 1) and the bot simulation
(section 4). `gr_prediff.py` reads the DB copy mode=ro and `git show <rev>:<file>` for the three tables and prints, per
table, rows only in the DB, only tracked, and rows in both differing by field. The bot simulation is committed as the
harness's `--bot-sim` mode so the question can be asked again at the next cross-checkout landing.

## 7. Deliberately not done

- No three-way base table and no `status_changed_at` column (section 2 says why).
- `cell_state` and `question_verdicts` are not reconciled (section 2).
- No alert on an undecided or conflicting row: the provenance event is the record. If one ever appears, an alert lane
  is the next step, not before.
- The 18 accepts are NOT applied. `--apply` shadow-scores against the gold set and stays a human verb; they wait at
  shadow `not_run`.
- `import_learning()` and `rebuild.py` are unchanged: a fresh DB restores exactly as before.
- No gate that reads the main checkout's `graph.db`: run-gates is hermetic by design.

## 8. Results against the bars

Run 2026-09-23 between 03:40 and 04:10, in the worktree `claude/graph-reconcile`, interpreter
`C:\Codex\Python312\python.exe`. The harness is cited by blob because `ops\push-main.ps1` rebases before it pushes:
`graph/bench/probe_learning_reconcile.py`, `graph/lib/learning_reconcile.py`, `graph/lib/graphdb.py` and
`graph/lib/graphdb_selftest.py` at the blobs named in the commit that adds them.

- **Fixtures**: `graph/lib/graphdb_selftest.py --selftest` exit 0, `SELF-TEST PASS: graphdb 25 of 25 cases` (13 before
  plus the 12 in section 5). Unchanged and still green: `graph/lib/graphdb.py --selftest` (10 of 10),
  `audit_graph_durability.py`, `learning_status.py`, `importers_selftest.py` (32 of 32), `promote_aliases.py` (37),
  `durable_write.py` (12), all exit 0 with their verdict lines.
- **Mutation**, from a temp mirror of `graph/lib` plus `graph/sqlite/schema.sql`, originals md5-identical afterwards:
  control exit 0 with 0 red; M1 (no reconcile call) exit 1 with 9 red, the three D13 MUST FIREs among them; M2
  (adoption on `>=`) exit 1 with exactly 1 red, the undecided MUST NOT FIRE. Both bars met.
- **Main DB copy** (453,259,264 bytes, source mtime 2026-09-22T21:37:13) against the rulings' learning blobs, through
  `--db`: the reconcile reported 69 statuses adopted, 69 patch rows inserted, 0 of every other count. 69 of 69 statuses
  equal the ruling (18 `accepted`, 51 `rejected`); 69 of 69 ids have their patch row (18 `accept`, 51 `reject`, reviewer
  "Brad via approvals page 2026-09-12" on all 69); 69 of 69 statuses are the status their own patch verdict names; all
  312 landed proposals, 255 landed patch rows and 48 landed eval runs present and equal in the exported files; the 1
  DB-only proposal and 5 DB-only eval runs kept; the database changed on exactly the 69 plus 69 rows and no other; a
  second export byte-identical on 5 of 5 files with nothing to reconcile. Every bar met.
- **Real-data clean twin**: `rebuild.py` into a scratch directory from origin/main's JSON, exit 0, then one export: 5 of
  5 files byte-identical to origin/main's blobs, reconcile counts all zero. The same from the rulings' JSON: 5 of 5.
- **Bot simulation** through `--bot-sim`: the one replayed commit (`54bff6167`), 0 conflicts decided by `-X theirs`,
  0 left by the autostash, 69 of 69 statuses and 69 of 69 patch rows kept at both steps. Re-run against the branch tip
  after the rulings were cherry-picked, whose two learning blobs are identical to the rulings commit's: the same. That
  re-run found a harness bug first: `--landing HEAD` was resolved inside the main checkout, so it named main's HEAD and
  replayed nothing. The landing is now resolved in the harness's own checkout before it is handed across.
- **Re-validation of the 69** against origin/main at 03:28 (no commit had touched `graph/learning` since the rulings'
  parent): 69 of 69 valid (18 Accept, 51 Reject), 0 skipped. Each is still `proposed` there, with payload, target, kind,
  created_at, confidence and rationale identical to `proposals.json` at `4cd3733d6`, the version Brad ruled against;
  the rulings commit moves exactly these 69 and only their status; `approved-patches.json` gains exactly one row per
  id with his verdict and the proposal's own payload, and 0 pre-existing rows change.
- **Not tested**: the probe itself was not mutation-probed; its red path was shown only by the D13 helper's original
  stand-in probe (69 of 69 reverted under the pre-change export).

## Knowledge consulted

- `.claude/rules/graph.md`: "A commodity id is NAMESPACED: `commodity:staple:<id>`" (the 69 rows' `target_id` values are
  bare legacy ids resolved by `resolve_target` at apply time; the reconcile compares ids as strings and never resolves
  them) and "An agreeing number escapes scrutiny. Run the check by rule, not by suspicion." (the revert kept every count,
  so section 6 checks statuses per id).
- `.claude/rules/ops-and-gates.md`, "Write the POINTED-TO object before the object that points to it": the code lands
  before the data in the same push, and inside the reconcile a proposal is inserted before the patch row that points at it.
- `.claude/rules/ops-and-gates.md`, "Do not add a gate that is red on day one" and "Three fixture labels, three jobs":
  no new gate; the fixtures carry MUST FIRE, MUST NOT FIRE and CLEAN TWIN in their stated senses.
- `.claude/rules/ops-and-gates.md`, "A catch around a native redirect is not a guard": the library prints nothing.
- `.claude/rules/measurement.md`, "Write the ACCEPTANCE BAR before the run" and "NAME THE HARNESS": section 6.
- `~/.claude/CLAUDE.md`, "Plan to a file when there is blast radius": this file, before the build.
- `~/.claude/skills/database-craft/applies-here.md` section 10 (found by searching "graph learning export tracked
  json"): "the tracked JSON is TRUTH, `graph/sqlite/graph.db` is an index ... Five tables are the exception ... kept
  mirrored by eight hand-placed `export_learning()` calls." The reconcile keeps that claim true across checkouts.
- Memory `learning-must-be-per-batch-not-nightly` (section 3), `landing-a-push-needs-a-clean-worktree` (land through
  `ops\push-main.ps1`), `daily-bot-commits-the-whole-tree` and `autostash-restores-content-not-the-index` (section 4).
- `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` W6.4 / D13: "Do not run graph ingest in the main tree,
  or in a worktree without graph.db."
