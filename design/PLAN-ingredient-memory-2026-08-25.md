# PLAN: ingredient memory — encode / attend / sleep, built in ONE session

Date: 2026-08-25. Author: Fable session, rewriting an external "learning brain" proposal Brad
commissioned, after a three-agent ground-truth sweep of the map lane, the graph learning loop, and
the sidecar. Status: **ORDERED BY BRAD — build it in one continuous session, no phases, no stops,
100% done.** The builder is an Opus session. This document is the spec; the SKILL files and the
external proposal are NOT the spec.

## 0. Contract for the builder — read before touching anything

1. **The QUOTES are the spec; line numbers are hints.** Every call site below is pinned with a
   verbatim code quote AND a line number. If the line number has drifted (this repo moves daily),
   re-locate by the quote. If the QUOTED CODE itself no longer exists or its semantics changed,
   do not guess and do not stop: prefer reality, write a `**CORRECTED**` block into THIS document
   in the same commit as the affected unit, and continue. That is the estate's standing idiom
   (see PLAN-map-judge-split-2026-08-25.md §4 "CORRECTED blocks in the same commit").
2. **One continuous session.** QA as you code: after each unit, run that unit's selftest, run a
   neuter proof (break the code, watch the MUST-FIRE go red, revert, print the counts), commit
   the unit, and move on. Commit per unit in ONE step (`git add <unit files>` + `git commit`
   together — the ~07:00 daily bot sweeps anything left staged). Push after the final unit.
   Do not stage-and-keep-working, do not batch all commits to the end.
3. **Do not touch** anything PLAN-map-judge-split-2026-08-25.md reserves (U1–U4 are NOT ordered):
   no changes to `map_prompt`'s obligations, no buy-string changes, no split of the mapper
   dispatch, no changes to T7/T8/M3/unbid-hold routing. This build ATTACHES to `assemble_mapped`
   and `map_dossier_extras`; it restructures nothing.
4. **Fixture idiom is mandatory**: every behavioral claim gets a MUST-FIRE and, where meaningful,
   a CLEAN TWIN. Pin fixtures at the CALL SITE, not only at the function — "twice this build a
   neuter came back 0 red because a fixture pinned a function while the bug lived at its call
   site" (PLAN-map-judge-split §4).
5. **Interpreters are non-negotiable.**
   - `meal-prep\pipeline\*` python: `C:\Codex\Python312\python.exe` (bare `python` is the
     Windows Store shim, exits 49).
   - Anything importing numpy/torch: `sidecar\.venv\Scripts\python.exe` and nothing else —
     the graph interpreter has no numpy (`graph\pipeline\resolve.py:1244-1251`).
   - PowerShell invocations from python go through `hunt_lib.ps_invoke` ONLY. `-File` cannot
     bind a multi-element `[string[]]` — that is the B8 class, frozen in
     `meal-prep\pipeline\decide_apply.py`'s selftest. Never `subprocess` + `-File` with array args.
6. **Windows PowerShell 5.1**: no `&&`/`||`, no ternary. Native stderr redirects throw under
   `$ErrorActionPreference='Stop'` — don't add `2>&1` on native calls.
7. Agent-definition edits (there is exactly one, §5.4) follow the estate's sync step described in
   PLAN-map-judge-split-2026-08-25.md §4 (:155-158).

## 1. What this is, and the falsification test it must pass

The estate already has an ingredient identity memory — `meal-prep\db\ingredient-resolutions.json`,
consulted as **step 1 of the per-line resolution ladder on every recipe**
(`map-preresolve.ps1:430-443`) — and it has been frozen at 23 rows since 2026-08-16T13:45:42
because **nothing calls its writer**. The writer exists, is mutexed (`Global\tc-ingredient-…`),
handles supersede-by-key, and is fixtured for 4-way concurrency (`ingredient-resolutions.ps1`,
`-Record` at :166-180) — it has zero callers (repo-wide grep, 2026-08-25). Likewise the `_rule`
on the file ("Invalidated by any registrar ruling that changes a commodity id") has a built
mechanism (`-Invalidate`, :181-192) with zero callers. Likewise the sidecar's
nearest-prior-rulings retrieval (`sidecar\sweep.py:163 memory_by_meaning`) is built, measured,
and dead — gated behind `--neighbours`, which nothing passes, feeding a field nothing reads.

This build connects those organs:

- **encode** — every mapper residual ruling becomes one append-only EVENT, written by the
  daemon's pen, and clean rulings project immediately into the resolutions ledger. Tomorrow the
  same phrase is a free cache hit instead of a frontier question.
- **error writes** — QA mapper-fails, registrar rulings, notes-vs-bid contradictions (OPEN-ITEMS
  §2.6), and bid rebids all become events too. A veto that leaves no event is the same sin as
  the 44 decide-rejections that vanished on 2026-08-15.
- **attend** — near-miss retrieval: the judge sees the k nearest PAST rulings as evidence,
  labeled as a shelf, never as an answer. Exact hits stay in the cache lane.
- **sleep** — a CPU-only nightly stage ingests the day's events into the graph's decision log,
  detects contradictions, accrues hunter gold, queues surprises, and emits a morning review
  packet for the held cases. Apply stays a human-reviewed morning verb.
- **measure** — a `hunter_identity` block in the scorecard, and a per-run postcondition:
  events written == residual rulings ruled, or a FINDING fires.

**Falsification test (run it at the end, report the numbers either way):** after the build's
end-to-end drill maps 3 scratch recipes with ≥5 residual rulings, `ingredient-resolutions.json`
count must be > 23, `meal-prep\db\ingredient-events.jsonl` must hold ≥1 event per residual
ruling, and re-running preresolve on the same terms must resolve them as `cache` hits. If after
a real 30-recipe week the count is still 23, the brain is a bystander and this plan failed —
that sentence belongs in the report, not softened.

## 2. The files this build creates and edits

CREATE:
- `meal-prep\pipeline\learn_apply.py` — the encode pen (D1, D2 partial). Modeled on
  `decide_apply.py`: validate → write events → project → selftest with end-to-end drill.
- `meal-prep\pipeline\resolution_embed.py` — the attend retriever (D3). Modeled on
  `meal-prep\pipeline\harvest_embed.py` (CPU-first, own cache namespace, sidecar venv).
- `graph\learning\ingest_hunter_events.py` — the sleep ingest (D4).
- `graph\gold\hunter-gold.jsonl` — hunter identity gold, NEW file, never merged into
  `gold.jsonl` (see §7.3).
- `graph\learning\hunter-review-packet.json` — emitted by ingest; consumed by
  `learn_apply.py --apply-reviews`.
- `meal-prep\db\ingredient-events.jsonl` — the event log. Tracked in git (append-only, LF,
  one sorted-keys JSON object per line — the `graph\provenance\*.jsonl` idiom).

EDIT:
- `meal-prep\pipeline\hunt-daemon.py` — call `learn_apply` from `assemble_mapped` (§3.3), write
  QA-fail events (§4.1), render the prior-rulings channel in `map_dossier_extras` (§5.3), add
  one sentence to `map_prompt` (§5.4).
- `meal-prep\pipeline\hunt_lib.py` — add `validate_map` (§3.5).
- `grocery\rebid-ingredient.ps1` — invalidation hook (§4.3).
- `graph\pipeline\nightly.ps1` — new CPU stage before the GPU window (§6.1).
- `graph\pipeline\scorecard_query.py` + `graph\pipeline\scorecard.ps1` — `hunter_identity`
  block (§6.4).
- `graph\sqlite\schema.sql` — extend the `type` comment enum with `hunter_identity` (§6.2). The
  enum at schema.sql:153-154 is a COMMENT, not a CHECK constraint; verify that before editing,
  and if it IS a constraint, write the CORRECTED block and use a migration-safe path (new value
  via table rebuild is NOT authorized; fall back to `type='learning_proposal'` with
  `decision` values prefixed `hunter_`).
- `.claude\agents\recipe-ingredient-mapper.md` — one paragraph, §5.4.
- `design\OPEN-ITEMS-recipe-hunter-2026-08-24.md` — mark §2.6's proposed check BUILT with the
  commit hash.

## 3. D1 — encode: `learn_apply.py` and the daemon hook

### 3.1 The event schema (frozen here; do not extend silently)

One JSON object per line in `meal-prep\db\ingredient-events.jsonl`. Sorted keys, LF endings,
`ensure_ascii=False`. ALL 14 fields always present (null/empty, never omitted):

```json
{"event_id": "ie:<sha256 of [kind,key,slug,decision,bid,evidence] first 20 hex>",
 "at": "YYYY-MM-DDTHH:MM:SS",
 "run": "<run dir basename or ''>",
 "slug": "<recipe slug>",
 "kind": "ruling | registrar | qa_mapper_fail | supersede | invalidate | review",
 "key": "<Get-TermKey-normalized term, '' for slug-level kinds>",
 "term": "<term verbatim>",
 "raw": "<the recipe's raw line, '' if n/a>",
 "decision": "<one of hunt_lib.MAPPED_RULING_DECISIONS, or the registrar/QA verdict>",
 "bid": "<ruled commodity id or ''>",
 "predicted": {"source": "cache|vocab|none", "bid": "<what preresolve said or ''>"},
 "surprise": false,
 "projected": false,
 "held_reason": "",
 "evidence": "<the judge's evidence sentence(s), verbatim, untruncated>",
 "by": "mapper | daemon | qa | registrar | adjudication"}
```

- `event_id` is content-addressed → appending the same ruling twice writes ONE line (the writer
  keeps an in-memory set of ids seen in the file; load once per invocation).
- **Key normalization must be byte-identical to `Get-TermKey`** (`ingredient-resolutions.ps1:31-40`
  == `map-preresolve.ps1:238-248`): lowercase, trim, every char outside `[a-z0-9 ]` → space,
  collapse whitespace, trim. Implement `term_key()` in `learn_apply.py` and pin it with the same
  fixture the PS pair uses: `'beef steak' != 'shaved beef steak'`, `"it's"` → `'it s'`,
  punctuation never deletes a word. Add a cross-language pin: shell
  `ingredient-resolutions.ps1 -Query` is NOT needed — instead the selftest feeds 6 fixed strings
  through `term_key()` and through a one-line `powershell` invocation of the PS function body,
  and asserts equality (via `hunt_lib.ps_invoke` on a temp script).
- `surprise` is true when: `predicted.bid` is non-empty and != `bid`; OR the notes-refuse-bid
  check fires (§3.4); OR `key` already exists in the ledger with a different `item_id`.

### 3.2 What projects into the ledger, exactly

`apply_learn()` projects a ruling into `ingredient-resolutions.json` (via
`ingredient-resolutions.ps1 -Record`, through `hunt_lib.ps_invoke`, NEVER by writing the file
directly — the mutex and envelope live in that script) **iff ALL of**:

1. `decision` ∈ {`mapped`, `mapped-optional`} and `bid` non-empty.
2. The assemble step reported ok — `apply_learn` is called ONLY after `-Assemble` returned
   exit 0 (§3.3). A ruling that failed assembly must not become memory.
3. `bid` exists in a commodity namespace OR carries an approving/aliasing registrar ruling in
   this batch's `registrar_rulings` (mirror of the assembler's own gate,
   `map-preresolve.ps1:1231-1249`; for an `alias` verdict, project the ALIASED-TO id).
4. The notes-vs-bid check (§3.4) does not fire.
5. `evidence` is non-empty. An unexplained ruling is recorded as an event but never as a cache
   row — the ledger's rows all carry evidence today; keep that invariant.

The `-Record` call: `-Term <term> -ItemId <bid> -BidExists -Evidence "<evidence> [slug <slug>,
run <run>]" -By mapper`. (`-BidExists` mirrors the mapper's `bid_exists: true` convention; if
`db\ingredients.json` wiring is unknown, omit the switch rather than lie — check how `-Record`'s
`$runBid` binds and pass accordingly.)

Everything else — `mapped-null`, `not-purchased`, `rejected`, refused projections — is an EVENT
ONLY, with `projected: false` and a specific `held_reason`
(`"decision mapped-null"`, `"notes refuse the bid"`, `"bid unknown to every namespace"`,
`"no evidence"`, …). `rejected`/`not-purchased` are judgments about a LINE in a RECIPE, not
about the term's identity — caching them as identities would be wrong, and the selftest pins
that.

**Supersede:** `-Record` replaces by key (`ingredient-resolutions.ps1:170-178` keeps
`$keep + $row`). When a projection replaces a row whose `item_id` differed, ALSO append a
second event `kind: "supersede"` recording old bid → new bid. This is the cache-correction
loop: a QA fail routes the recipe back through the mapper, the repair ruling re-projects, and
the wrong row is superseded with a written trace.

### 3.3 The daemon call site

In `assemble_mapped` (`hunt-daemon.py:2148-2205`), AFTER the `-Assemble` invocation
(`args = ["-Assemble", "-RunDir", ...]` … `rc, out, err = await self.ps_timed(...)` at
2193-2196) and only when it succeeded, add:

```python
learned, lfindings = await asyncio.get_running_loop().run_in_executor(
    None, learn_apply.apply_learn, self.run_dir, slug, res, tables, payload)
```

- Import `learn_apply` at module top beside the other pipeline imports.
- `res` is the mapper's validated result for this slug; `payload` is the dict already built at
  2164-2181 (it carries `rulings` and `registrar_rulings`); `tables[slug]` carries the
  preresolve rows, from which `predicted` is read: for each ruling's key, find the preresolve
  row with the same key and take its `resolution`/`source` (`src == 'cache'` → predicted from
  cache; a vocab hit → `vocab`; residual → `none`).
- `apply_learn` returns `(summary_dict, findings_list)`. Findings append to the same findings
  road `assemble_mapped` already uses (2200-2205) — they are advisory, they do NOT fail the
  assemble (memory must never block the lane; a broken pen is a finding, not a parked recipe).
- **Postcondition, enforced at this call site and fixtured at this call site:** after
  `apply_learn`, `summary["events_written"] + summary["events_skipped_duplicate"]` must equal
  `len(payload["rulings"])` + the registrar events. If not, append the finding
  `"<slug>: N residual rulings but M learn events - a ruling left no trace (the 44-class)"`.
  This is the proposal's `Events / mapped residuals = 1` metric made mechanical.
- Also append one `kind: "registrar"` event per entry in `payload["registrar_rulings"]`
  (they are otherwise invisible across runs — no registrar ledger exists; this is the first).
- One per-slug summary event is NOT needed; the nightly ingest aggregates.

### 3.4 The notes-vs-bid check (OPEN-ITEMS §2.6, built)

Mechanical, in `learn_apply.py`, applied per ruling before projection:

```python
REFUSE_NEAR_BID = re.compile(
    r"(refus\w*|reject\w*|not\s+the|is\s+not)\W{0,80}" + re.escape(bid), re.I)
```

If the ruling's `evidence` matches, the ruling does NOT project; the event carries
`surprise: true, held_reason: "notes refuse the bid"`, and a finding names it. CLEAN TWIN
(pin the real 2.6/2.7 shape): evidence that refuses a DIFFERENT id than the bid — e.g.
evidence "Refused the chicken-thighs bridge…" with `bid: chicken-drumsticks` — projects
normally. The check reads the ruling's own `evidence`; it does not re-read mapped files.
Mark OPEN-ITEMS §2.6 BUILT with the commit hash, in the same commit.

### 3.5 `validate_map` in `hunt_lib.py`

The MAP lane is the one judge with no semantic validator (DECIDE: `hunt_lib.py:152`; REGISTRAR:
:872; WRITER: :964). Add `validate_map(payload)` beside them: per result, every ruling's
`decision` ∈ `MAPPED_RULING_DECISIONS`; a `decision` of `mapped`/`mapped-optional` with an
empty `bid` AND an empty `canon_item` is refused; duplicate `raw` within one slug's rulings is
refused. Call it in `learn_apply.apply_learn` as a pre-flight (NOT in the dispatch path — do
not change what the daemon accepts from the mapper in this build; the validator guards the
pen, the way `decide_apply` validates before writing). Selftest: MUST-FIRE per rule +
CLEAN TWIN of a conforming payload.

### 3.6 `learn_apply.py --selftest` (the drill)

Follow `decide_apply.py cmd_selftest` structurally: pure-predicate fixtures first, then an
END-TO-END DRILL against a scratch run dir and scratch ledger/event files (`--store` /
`--events` parameters exist so the drill never touches the real files; default paths are the
real ones). MUST-FIREs, minimum set:

1. a `mapped` ruling with known bid, clean notes → ONE event, `projected: true`, ledger row
   exists with the normalized key, `by: mapper` (CLEAN TWIN).
2. the same ruling applied twice → one event line, one ledger row (idempotence).
3. notes refusing the bid → no projection, `surprise: true` (+ CLEAN TWIN from §3.4).
4. `rejected` / `not-purchased` / `mapped-null` → event only, never a ledger row.
5. an unknown bid with no registrar approval → event only, `held_reason` names it; the SAME
   bid with an `approve` ruling in `registrar_rulings` → projects; an `alias` ruling →
   projects the aliased-to id.
6. a re-ruling with a different bid → row superseded (one row per key) AND a `supersede`
   event exists.
7. `predicted.bid` ≠ ruled bid → `surprise: true` (the surprise wire).
8. a ruling with empty evidence → event only, never a row.
9. `-Record` failing (point `--store` at a locked/unwritable path) → a finding, exit 1,
   never silence.
10. `term_key()` fixtures incl. the cross-language pin (§3.1).
11. the 44-class call-site postcondition: hand `apply_learn` a payload of 3 rulings and a
    stubbed event writer that drops one → the summary mismatch finding fires.

Marker: `LEARN-APPLY-COMPLETE`, exit 0/1/2 per the estate contract (`hunt_lib.EXIT_*`).

## 4. D2 — error has to write

### 4.1 QA mapper-fails

At the QA routing site (`hunt-daemon.py:3526-3577`, where `write_qa_verdict` runs and
`owner = self.owner_agent(q.get("owner"))` resolves): when the verdict is a fail and the raw
owner field is `"mapper"`, append one `kind: "qa_mapper_fail"` event (slug-level: `key: ""`,
`decision: "fail"`, `evidence: findings text`, `by: "qa"`, plus the slug's residual keys listed
inside `evidence` — read them from `<RunDir>\mapped-pre\<slug>.rulings.json` if present, else
say so). Do this via a small sync helper in `learn_apply` (`append_event(...)`) run in the
executor. The event does not touch the ledger — the correction loop is the repair re-ruling
(§3.2 supersede). Fixture: in the drill, a fabricated QA-fail with owner mapper writes exactly
one event; owner `writer` writes none.

### 4.2 Registrar rulings

Covered by §3.3 (one event per ruling, kind `registrar`). No other change — the registrar
agent itself stays read-only.

### 4.3 Rebid invalidation (the `_rule`, finally enforced)

In `grocery\rebid-ingredient.ps1` (a sanctioned editor named by the commodity-registrar's agent
def), after a successful rebid that CHANGES which commodity id an ingredient points at, invoke:

```powershell
& powershell -NoProfile -ExecutionPolicy Bypass -File "$mealPrepPipeline\ingredient-resolutions.ps1" -Invalidate -ItemId <old-id>
```

and append a `kind: "invalidate"` event (via `learn_apply.py --append-event <json>`, a small
CLI verb added for PS callers). Locate the success point by reading the script; if
`rebid-ingredient.ps1` does not exist under `grocery\` (locate with Glob — the agent def names
it without a path), write the CORRECTED block with where it actually lives, and hook it there.
The hook is best-effort with a visible warning on failure — a rebid must never be blocked by
the memory layer, but a silent skip is forbidden. Fixture: extend the script's selftest (or add
one in the estate's guard idiom if none exists) — a rebid drill against a scratch store drops
the stale row.

## 5. D3 — attend: nearest prior rulings as judge evidence

### 5.1 `resolution_embed.py` (sidecar venv, CPU, own namespace)

Model on `meal-prep\pipeline\harvest_embed.py` — copy its interpreter guard (wrong interpreter
exits 2 naming `sidecar\.venv\Scripts\python.exe`), its CPU-first stance
(`lib_match.DEVICE = "cpu"`, no reranker), and its cache-namespace discipline. **Own cache dir:
`sidecar\out\resolution-embed-cache\`.** Never write `sidecar\out\embed-cache\` — the sweep's
`keep_only` prune evicts foreign vectors (`score_cache.py:120-127`); ship the eviction-twin
fixture exactly as `harvest_embed.py:272-278` does.

Verbs:
- `--query <in.json> --out <out.json>`: input `{"terms": [{"key":..., "term":..., "raw":...}]}`;
  corpus = every event in `ingredient-events.jsonl` with kind `ruling` (all decisions — a
  `rejected`/`mapped-null` neighbor is evidence too). Embed `term` strings, cosine top-k
  (k=5) per query term, **leave-one-out: a corpus event whose `key` equals the query's `key`
  is excluded** (never its own precedent). Output per term: up to 5 neighbors
  `{term, key, bid, decision, evidence (first 200 chars), cos, at, slug}` — every neighbor
  CARRIES ITS OWN RULED CONTEXT, because "ruled X for a different phrase" must never render as
  "ruled X for this phrase" (the false-precedent lesson, `sweep.py:181-185`).
- `--selftest`: eviction twin; leave-one-out MUST-FIRE; empty corpus → `{"terms": [...
  "neighbours": []]}` with `"state": "empty"`; and the three-state contract below.
- Latency budget (measured, `meal-prep\db\harvest-embed-latency.json`): ~4.4 s model load +
  ~36 ms/string on CPU. Fine for a map batch; never touch the GPU.

### 5.2 The daemon side — three states, never faked

Before building the map dossier (in the same stretch of `map_lane` where `fill_fdc_shelf` runs,
`hunt-daemon.py:2235` area), the daemon writes the residual terms to a temp JSON and invokes
`resolution_embed.py --query` via the estate's python road with the SIDECAR interpreter
(`sidecar\.venv\Scripts\python.exe`), timeout 120 s. Result states:

- ran, neighbors found → render (§5.3);
- ran, none found → render the channel with "no prior rulings near this term" (empty ≠ absent);
- could not run (no venv, timeout, nonzero exit) → the channel renders
  `PRIOR RULINGS: BLIND - <reason>. Absent evidence, not absence of precedent.` — copy the
  announced-unreadable idiom of `hunt-daemon.py:2498-2503`. **Never an empty list pretending
  it looked.**

### 5.3 Rendering — in `map_dossier_extras`

Add a fourth channel to `map_dossier_extras` (`hunt-daemon.py:2464`, cap `MAP_EXTRAS_CAP =
4000` at :2433 — respect it; the cap announces truncation, :2547-2553), in the FDC-shelf
framing (`map-preresolve.ps1:511-515` is the model):

```
  PRIOR RULINGS NEAR THESE TERMS - a shelf, not an answer. Each was ruled for a DIFFERENT
  phrase; cosine ranks wording likeness, not food identity, so any of these can be the wrong
  precedent. Weigh them; you still rule this line yourself:
    'kosher salt' -> salt (mapped, 2026-08-16, cos 0.91): "no Kosher Salt vocab row today; ..."
```

The judge still asserts; neighbors never auto-resolve anything; `status` of the line stays
residual. Rejection-type neighbors are the most transferable, confirmation-type the least
(`sweep.py:207-223`) — do NOT encode that as a filter, just keep decisions visible.

### 5.4 Prompt + agent def (name the field, or repeat the "unchanged contract" bug)

`map_prompt` gains ONE sentence in the dossier-conventions area: "Some residual lines carry a
PRIOR RULINGS shelf - rulings on SIMILAR past phrases, evidence only; they resolve nothing and
you may disagree with them." (The lesson at `hunt-daemon.py:2702-2706`: a prompt that said
"unchanged contract" without naming the new field broke a clean batch — NAME the field.)
`.claude\agents\recipe-ingredient-mapper.md` gains the matching paragraph; then the sync step
(§0.7). The forbid-reread list at `hunt-daemon.py:2662-2664` stays as is — the shelf is inlined
or invisible.

## 6. D4 — sleep: nightly ingest, morning packet, scorecard

### 6.1 `ingest_hunter_events.py` and its nightly slot

New stage in `graph\pipeline\nightly.ps1` **between the `defs` Record and the sweep block**
(between :395 and :400) — after `emit`/`defs`, BEFORE anything holds the card. CPU-only,
read-mostly, BLIND-not-fatal. Follow the stage idiom exactly: `[switch]$SkipHunterIngest`
param, a `-WhatIfOnly` plan line, `Invoke-Stage` with explicit exe + 300 s timeout, `Record`
with `OK|BLIND|FAILED|SKIPPED`, and extend `-SelfTest` (pure functions only; the selftest
touches no data). Do NOT place it after Stage 1 or in the `finally` — the GPU window is
:401-:470 and teardown must never do work.

The script (graph-side interpreter; stdlib only — it may NOT import numpy):
1. Read `meal-prep\db\ingredient-events.jsonl`. Missing file → print BLIND with reason, exit 3
   (absent ≠ empty; an empty file is a clean zero-event day, exit 0).
2. For each event not yet in the graph: `db.log_event(run="run:hunter-ingest:<stamp>",
   etype="hunter_identity", decision=<kind>, detail=<the event>, output_hash=<event_id>)` —
   idempotency via the content-addressed event_id inside detail; keep a high-water file
   `graph\state\hunter-ingest-cursor.json` (line count + last event_id) so re-ingest is cheap,
   but the dedupe truth is the event_id, not the cursor.
3. Contradiction sweep: group events by `key`; a key with ≥2 distinct non-empty `bid`s where
   the LEDGER's current row disagrees with the newest event → a packet entry. A key whose
   events refute its own cached row (`surprise` events newer than the row's `at`) → a packet
   entry.
4. Hunter gold accrual: every event with `projected: true`, and every `supersede`, appends a
   row to `graph\gold\hunter-gold.jsonl` (schema §7.3), deduped on its `id`.
5. Surprises (`surprise: true`, not yet queued) append items to `grocery\learning-queue.json`
   in the executor's read-modify-write idiom (`graph\agentic\executor.py:193-212`):
   `{"step": "hunter-ingest", "type": "hunter_surprise", "tool":
   "meal-prep/pipeline/learn_apply.py", "detail": <event>, "attempts": 1, "policy":
   "triage_queue_or_learning_queue", "queued_at": ...}`. The queue is schema-free on the
   consumer side (`stage1_analyze.py:115-123` dumps items opaquely) — Stage 1 will SEE hunter
   surprises in its prompt with zero changes to Stage 1. Stage 1's proposal kinds stay
   grocery-only in this build (§7.2).
6. Emit `graph\learning\hunter-review-packet.json`: `{generated_at, instructions, cases: [...]}`
   — each held/contradiction case with its full event(s), the ledger's current row if any, and
   the verdict contract: `{event_id, verdict: record|supersede|leave, item_id (required for
   record/supersede), evidence, by: "adjudication"}`.
7. Print a summary line; `log_event` one `decision: "hunter_ingest_complete"` with counts.
8. `--selftest`: scratch files; double-ingest idempotence MUST-FIRE; contradiction detection
   MUST-FIRE + clean twin; queue append preserves existing items (MUST-FIRE: 1 existing + 1
   new = 2, never 1); missing-events-file → exit 3 path.

### 6.2 The morning apply verb

`learn_apply.py --apply-reviews graph\learning\hunter-review-packet.verdicts.json` — for each
`record`/`supersede` verdict: `-Record` with `-By adjudication` and the reviewer's evidence,
plus a `kind: "review"` event. `leave` writes only the event. This is the ONLY promotion road;
nothing applies automatically at 3am — "apply stays a morning packet" survives verbatim.
Fixture in the drill: a verdicts file records a row; a `leave` does not; a verdict on an
unknown event_id is refused loudly.

### 6.3 schema.sql co-edit

Extend the comment enum at `graph\sqlite\schema.sql:153-154` with `hunter_identity` (§2's
caveat applies). `graph\schema.md` needs no node/edge change — this build creates NO new node
types and NO new predicates (events live in `decision_log`; the reserved `AuditFinding` stays
reserved).

### 6.4 Scorecard

`scorecard_query.py collect()` gains a `hunter_identity` block:
`{resolutions_count: <count from ingredient-resolutions.json>, events: {kind -> n in window},
surprises: n, projected: n, ingest: {last_run, state}}` — sourced from `decision_log WHERE
type='hunter_identity'` (the GROUP BY idiom at :177-193) and a direct read of the ledger file
(missing file → BLIND with why, never zero — the rule at scorecard_query.py:26-30).
`scorecard.ps1` renders the block in its report and `-Json` object; extend both selftests
(`--selftest` on the python side, the `-SelfTest` block on the PS side) with one MUST-FIRE
each. The falsifying read (§1) is this block a week from now.

## 7. NOT built, and why — the builder must not invent these

1. **No LoRA, no trained anything.** The proposal's own P5 discipline: not before a week of
   scorecard. Out of scope by design.
2. **No generalization to unseen surface forms, no Stage-1 hunter proposal kinds, no
   `commodities.json`/vocab writes.** The exact-key cache settles every SEEN form on first
   ruling; the marginal value of promoting "concept aliases" for UNSEEN forms is small and the
   false-merge risk ("fresh garlic" → Ground Cloves; the $11.92/oz clove cell) is the one
   error the estate froze promotions over. The grocery promotion road (Stage 2, blast radius,
   gold-coverage hold, guards) is commodity-alias-shaped and its blast-radius corpus is store
   listings, not recipe phrases — reusing it here would be gate theater. Revisit only after
   the scorecard shows a real residual stream the cache is NOT absorbing.
3. **`hunter-gold.jsonl` stays a separate file.** Schema mirrors `gold.jsonl` rows
   (`kind: "ingredient"`, `commodity: <bid>`, `commodity_node` via the staple→recipe ladder,
   `product: <term>`, `store: null`, `label: MATCH` for projected / `NO_MATCH` for refuted,
   `source: "hunter-event:<slug>"`, `evidence`, `id: "gold:"+hash_obj([kind,commodity,product,
   None])[:20]`). It is NOT merged into `gold.jsonl`: the SKU gold's NO_MATCH rows feed
   `alias_blast_radius` kill detection scoped by commodity slug, and recipe PHRASES in that
   corpus have unvetted effects on grocery alias kills. Merging is a later, human decision.
4. **No changes to the mapper's pin, dispatch shape, or the map-judge-split units.** §0.3.
5. **No second nightly, no new scheduled task.** One new stage inside the existing owner.
6. **The graph stays a checker, not the matcher**; preresolve's ladder order (cache → vocab →
   …) does not change.

## 8. Build order, verification, and the report

Units, in order, one commit each (suggested messages in quotes):

- **B1** `learn_apply.py` + `validate_map` + selftest green + neuter proof. ("the map lane's
  rulings become events, and the pen that was built for them finally has a caller")
- **B2** daemon hook in `assemble_mapped` + 44-class postcondition + QA-fail events +
  registrar events. Run `hunt_daemon_selftest.py` — it must stay green; if it has no coverage
  of `assemble_mapped`, add the call-site fixture there.
- **B3** rebid invalidation hook + fixture.
- **B4** `resolution_embed.py` + daemon retrieval + dossier channel + prompt/agent-def sentence
  + sync. Selftests green (BOTH venvs).
- **B5** `ingest_hunter_events.py` + nightly stage + `nightly.ps1 -SelfTest` green +
  `-WhatIfOnly` shows the new stage.
- **B6** morning apply verb + scorecard block + both scorecard selftests green.
- **B7** THE DRILL: a scratch run dir with 3 fabricated recipes / ≥5 residual rulings driven
  through `apply_learn` (scratch store), then `resolution_embed --query` over 2 of the terms,
  then `ingest_hunter_events` (scratch graph db is fine — `open_db` takes a path), then
  `--apply-reviews` on one held case. Assert the §1 falsification numbers. Then run the REAL
  gates that exist: `decide_apply.py --selftest`, `learn_apply.py --selftest`,
  `nightly.ps1 -SelfTest`, `scorecard.ps1 -SelfTest`, `test_gates.py`. All green.
- **B8** OPEN-ITEMS §2.6 marked BUILT; this doc's CORRECTED blocks (if any) landed; push.

## 8b. B7 — the drill, and §1's falsification numbers as measured (2026-08-25)

Three fabricated recipes through the REAL road: `map-preresolve.ps1` (scratch vocab-live,
`-ResolutionsFile` scratch, `-NoBoard -NoPrecheck`) → `learn_apply.apply_learn` → a SECOND
`map-preresolve` over the same run dir → `resolution_embed.py --query` under the sidecar venv →
`ingest_hunter_events.py` against a scratch graph db, twice → `learn_apply.py --apply-reviews`.
The scratch ledger is **seeded byte-for-byte from the live `ingredient-resolutions.json`**, so the
before/after counts are the estate's own numbers. Nothing live was written; the worktree was clean
before and after. 35 assertions, all green.

| §1's question | measured |
| --- | --- |
| residual rulings ruled | **7** (6 residual + 1 on a cache-settled line the judge disagreed with) |
| registrar rulings | **1** |
| events written (primary) | **8** — 7 rulings + 1 registrar, exactly `rulings + registrar` |
| event lines on disk | **9** — the 8 above plus 1 `supersede` |
| **ledger count before → after** | **23 → 26**, and **27** after the morning verb recorded one held case |
| projections | 4 (2 + 1 + 1); the ledger grew by 3 because the 4th REPLACED an existing row |
| held, event-only | 3 — `labneh cheese` (bid unknown to every namespace), `duck fat` (decision rejected), `ras el hanout` (decision mapped-null) |
| surprises | 2 (the contrary ruling and its supersede) |
| **cache-hit re-resolve** | **3 of 3** projected terms came back `source: cache` on the second pass, at the bid they were ruled to; residual count fell **6 → 4** |
| what did NOT cache | the `mapped-null` and the `rejected` line stayed residual on the warm pass — a judgment about a LINE is not an identity |
| attend | corpus 7; the UNSEEN phrase "shaved beef for cheesesteaks" retrieved "thin sliced beef for sandwiches" at **cos 0.7016**, ahead of every other ruling, and the ruled term did not get itself back |
| sleep | 9 events filed, 3 review cases, 5 gold rows (4 MATCH, 1 NO_MATCH for the superseded id), 2 surprises queued behind a pre-existing queue row; second night filed **0** duplicates (11 decision_log rows over two nights, the +2 being the two `hunter_ingest_complete` rows) |
| promote | the ingest changed the ledger by **0** rows; only `--apply-reviews` moved it, and a verdict on an event_id the packet never held was refused |

Gates, all green on a clean tree: `learn_apply --selftest` 53, `decide_apply --selftest` 43,
`hunt-daemon --selftest` 245, `hunt_lib --parity` 63/63, `rebid-ingredient -SelfTest` 12,
`ingredient-resolutions -SelfTest` 9, `resolution_embed --selftest` 25,
`ingest_hunter_events --selftest` 24, `scorecard.ps1 -SelfTest` 23,
`scorecard_query --selftest` 15, `graph/learning/test_gates.py` 12, `nightly.ps1 -SelfTest` OK,
`nightly.ps1 -WhatIfOnly` prints the new `1c hunter` stage.

## 9. CORRECTED blocks, written during the build (2026-08-25)

Each block landed in the same commit as the unit it affects, per §0.1.

### C1 (B1) — §3.4's `REFUSE_NEAR_BID` regex cannot fire on its own founding case

The plan freezes:

```python
REFUSE_NEAR_BID = re.compile(
    r"(refus\w*|reject\w*|not\s+the|is\s+not)\W{0,80}" + re.escape(bid), re.I)
```

`\W` matches only NON-word characters, so the span between the refusal word and the id may hold
spaces and punctuation but **not a single letter**. Run against the verbatim evidence OPEN-ITEMS
§2.6 is written from —

> "...Refused the chicken-thighs bridge on the standing 'leg quarters are not thighs' precedent:
> drumsticks are a distinct cut ... so the thigh id would overprice and mis-weigh."

— with `bid: chicken-thighs`, the word `the` sits between `Refused` and the id, so `\W{0,80}`
cannot reach it. **MEASURED**: with the literal regex restored, `learn_apply.py --selftest` came
back **3 RED**, the first being "the 2.6 slip: the prose refuses `chicken-thighs` and the bid IS
`chicken-thighs` — got: did not fire" (the other two were the drill's downstream cases: the ruling
got cached, and the extra row produced a second supersede). A must-fire that cannot fire on the
only real example the estate owns is gate theater.

REALITY PREFERRED: the gap class is `[^.;:!?]{0,80}?` — up to 80 characters that do not end the
clause. The bound still does the plan's intended work (the refusal has to be about THIS id in THIS
clause), and both halves are pinned against the 2.6 text: MUST-FIRE with `chicken-thighs`, CLEAN
TWIN with `chicken-drumsticks` (§2.7's correct ruling, whose id appears only after the colon that
ends the refusal clause).

### C2 (B1) — §3.1 says "ALL 14 fields" over a 16-key JSON block

The frozen event JSON in §3.1 lists sixteen keys: `event_id, at, run, slug, kind, key, term, raw,
decision, bid, predicted, surprise, projected, held_reason, evidence, by`. The KEYS are the spec
and are implemented verbatim; the count in the prose was miscounted. `learn_apply.EVENT_FIELDS`
holds the 15 authored fields, `event_id` is derived, and the fixture asserts `len(event) == 16`.

### C3 (B3) — `rebid-ingredient.ps1` is not under `grocery\`

§4.3 says "In `grocery\rebid-ingredient.ps1`" and adds "if it does not exist under `grocery\`,
locate with Glob and write the CORRECTED block". It does not: the script lives at
**`meal-prep\pipeline\rebid-ingredient.ps1`**, which is the right home — it edits
`meal-prep\db\ingredients.json` and every `meal-prep\db\recipes\*.json` spec that costs the item.
The hook is built there, and the invalidation goes through
`meal-prep\pipeline\ingredient-resolutions.ps1` (a sibling), so §4.3's `$mealPrepPipeline` path
variable is unnecessary — `$here` already is that directory.

Two further deltas from §4.3's sketch, both because the sketch could not run as written:

* The invalidation is a FUNCTION (`Invoke-MemoryInvalidation`) rather than an inline `& powershell`
  line, so its behaviour is fixturable against a scratch ledger. Its returned object carries
  `Ran`/`Invalidated`/`Why`, and the applied path prints whichever happened. Best-effort with a
  visible warning, exactly as §4.3 requires; never a throw, and never a silent skip.
* The `invalidate` event goes to `learn_apply.py --append-event` through a **temp FILE**, not a
  JSON string on a command line. A JSON object as an argv token is one quoting accident away from a
  truncated event, which is the estate's own B8 class wearing a different hat.

### C4 (B3) — a source-level call-site pin needs the FIRST match and the count, not the last

Driving the real `-Apply` road would need a whole scratch estate (`smp-feed.json`,
`db\ingredients.json`, `db\recipes\*.json`), so the call site is pinned by source position. Written
as `LastIndexOf`, that pin came back **0 RED** against a neuter that hoisted a SECOND call ABOVE the
dry-run gate — under which a DRY RUN would wipe the identity cache for a rebid it never performed.
Rewritten to assert "exactly one occurrence, and it is after the gate", the same neuter returns
**1 RED**. Third time this build's lineage has watched a pin miss a call site (PLAN-map-judge-split
§4 records the first two).

### C5 (B5) — `open_db` takes no path, and `log_event` requires a timestamp

§6.1 step 2 quotes `db.log_event(run=…, etype=…, decision=…, detail=…, output_hash=…)` and B7 says
"scratch graph db is fine — `open_db` takes a path". Neither is the code:

* `graph\lib\graphdb.py:504` — `def open_db(create: bool = True) -> GraphDB`. No path parameter.
  The path lives on the class: `GraphDB(path=DB_PATH, create=True, restore_learning=True)`. The
  ingest therefore constructs `GraphDB(path=…)` directly, and passes `restore_learning=False` for a
  scratch db so a drill does not pull the estate's learning tables into a throwaway file.
* `log_event`'s signature is `(self, run, timestamp, etype, …)` — `timestamp` is REQUIRED and
  positional-adjacent, because graphdb's stated rule is "No implicit clock. Timestamps are passed
  in. A replayed run reproduces byte-identical ids and rows."

### C6 (B5) — the idempotency mechanism §6.1 step 2 names cannot work

§6.1 says "idempotency via the content-addressed event_id inside detail". It cannot be:
`GraphDB.log_event` mints its OWN primary key as
`event_id(run, step_id, etype, hash_obj([decision, detail, output_hash]))`, and the run id carries
a per-night stamp — so re-filing yesterday's event tonight produces a DIFFERENT primary key and the
`ON CONFLICT(event_id) DO NOTHING` never fires. The dedupe truth is a `SELECT output_hash FROM
decision_log WHERE type='hunter_identity'`, which IS the event's own content-addressed id, through
the column that actually holds it. The cursor file stays what §6.1 calls it — a cheap skip, never
the truth.

**MEASURED, and it caught a bad fixture first.** Deleting `already_ingested()` outright came back
**0 RED**: the fixture's two ingests ran inside the same second, so the run ids matched, so
log_event's own primary key collided and hid the missing dedupe. A `--run` seam was added so the
two halves of the fixture are two NIGHTS rather than two calls, and the same neuter then returns
**1 RED**.

### C0 (B8) — the one thing this build did NOT do, and why

§0.7 requires the estate's agent-def sync step after the one agent-definition edit (§5.4). The
mapper's definition was edited and `ops\prompt-backup\agents\recipe-ingredient-mapper.md` was
brought byte-identical to it in the same commit — so the REPO half of that step is done, and the
live project-scope file at `C:\Codex\ThriftyCrew\.claude\agents\` becomes correct the moment this
branch merges, because that path IS the repo.

`ops\audit-prompt-backup.ps1 -Sync` was **not run**. It writes to `C:\Users\Owner\.claude\agents`
— outside the repository entirely — which this build was explicitly forbidden to touch. The
USER-scope copy of `recipe-ingredient-mapper.md` is therefore still the pre-edit text, and
`audit-prompt-backup.ps1` will report SCOPE DRIFT on it until someone runs `-Sync` after the merge.
That is one command and it is named here so it cannot be forgotten: **run
`ops\audit-prompt-backup.ps1 -Sync` after merging.**

### C7 (B5) — a source-position fixture that can see itself is reading the wrong file

The nightly `-SelfTest` pins the new stage's SLOT by source position. Written with literal needles,
three of its checks matched THEIR OWN source lines: `$iSweep = $src.IndexOf('if (-not $SkipSweep)
{')` found itself at index 21,230 and reported the real sweep block as running before a stage
7,600 characters further down, and the BLIND-branch check was satisfied by the text of the check
itself. Two neuters came back 0 RED before the needles were built from parts. Same class as C4,
in a different file, on the same day — this idiom needs the built needle every time.

Final report, numbers not adjectives: events written in the drill, ledger count before/after,
cache-hit re-resolve proof, every selftest's pass count, every neuter proof's red count, and
anything CORRECTED. If a bar was missed, say which and by how much — a miss reported plainly
beats a pass described vaguely.
