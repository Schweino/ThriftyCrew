# PLAN: The latency build - F1 through F7, from the cold read to a 2-minute recipe

Date: 2026-08-25. Author: the judge-contract build session, from Brad's direction after reading
EVAL-latency-cold-read-2026-08-25.md. Status: WRITTEN FOR RATIFICATION; Brad ordered a single
implementing session for the whole scope ("do the entire thing in a brand new session"), which
supersedes the one-phase-per-session default for THIS build only. The implementer still asks Brad
for the weekly usage % before starting and at each numbered unit boundary, and STOPS at 80%.

THIS DOCUMENT IS THE SPEC for that session. It was written with every surface read in the working
tree at commit 9c6e840d and every anchor verified against it. Where this plan and code reality
disagree, fix THIS plan in the same commit, marked CORRECTED with date and measurement - the same
standing rule PLAN-hunter-judge-contract carries, which produced three such corrections during its
own build. Expect to earn at least one here.

## 0. The verdict in one paragraph

The cold read (EVAL-latency-cold-read-2026-08-25.md, commit 9c6e840d) measured where the minutes
go: a recipe rides a serial chain of 6 to 10 judgment dispatches, and the expensive dispatches
spend their turns on RETRIEVAL - the mapper fetching nutrition labels one WebFetch-turn at a time
(77% of the jc1 drill's wall), the registrar re-proving namespace sweeps, QA re-reading files a
dossier could carry. This plan finishes the judge contract's own move on the three stages that
still lack it (map's label acquisition, the registrar, QA), adds one small delta to the scoped
re-audit, and fixes the hygiene defects the jc1 drill surfaced. Nothing here weakens a gate; every
change is "the daemon gathers, the judge rules", which is the ratified pattern of
PLAN-hunter-judge-contract applied to the last stages without it. End state, arithmetic not
promise: a clean board-priced recipe at roughly 7 judgment turns across 5 dispatches, 2.5-4 min
serial, 1-2 min throughput at width. Recipes needing a NEW priced ingredient stay outside any
2-minute figure (F6/eval), and that is stated, not hidden.

## 1. Required reading for the implementing session, in order

1. This whole file.
2. design\EVAL-latency-cold-read-2026-08-25.md - the measurements this plan is built on.
3. design\PLAN-hunter-judge-contract-2026-08-25.md - the ratified pattern being extended, and the
   CORRECTED blocks showing what its build learned.
4. hunt-daemon.py: preresolve (~1061), registrar_rulings (~1190), commodity_near_misses (~1337),
   registrar_evidence_block (~1365), registrar_prompt (~1381), write_food_db_rows (~1431),
   map_prompt (~1727), price_prompt (~2079), writer_dossier (~2549), qa_repair_by_patch (~2723),
   qa_prompt (~2790), repair_by_patch (~3004), render_audit_dossier (~3153), audit_prompt (~3219).
   Line numbers are as of 9c6e840d; re-grep, do not trust them blind.
5. fdc_lookup.py: api_key (60), search (115), atwater_check (187), _cache_key (230), cache_get
   (248), cache_fill (263). Read the docstrings; two of them are load-bearing design rulings.
6. map-preresolve.ps1: the FDC attach (~500-514), Get-FdcCandidates (~941-963), residual_terms
   (~573).
7. .claude\agents\commodity-registrar.md and recipe-source-qa.md, whole.
8. The jc1 artifacts if still present: C:\tmp\jc1\run\lane-log.jsonl and mapped-pre\*.json - the
   measured evidence for F1. If C:\tmp\jc1 is gone, the eval's section 1.1 carries the numbers.

## 2. What does not move, restated so nobody relitigates

Every gate and threshold; the price lane singleton; PLAN v3 section 10 and section 11 (model pins
included - no tier changes); the registrar's EXISTENCE, AUTHORITY and its concurrency + collision
re-check (commit c36879cd); QA's one-repair rule and the re-QA dispatch; the auditor's authority
and tools; the unbid hold (nothing unbid reaches the writer - a recipe blocked on pricing PARKS,
it does not proceed); the changed-nothing repair guard; wave-publish and everything downstream of
GO; the never-auto-coerce rule; ps_invoke/py_invoke as the only marshalling roads; the writer
computes no number; local may never assert an identity. F7 of the eval is also a non-item BY
FINDING: the mechanical floor is free, and nobody spends this session optimizing it.

## 3. F1 - the FDC shelf gets filled, mechanically, before the mapper is paid

### 3.1 The measured defect

The judge-contract plan's section 3.1 premise ("the FDC shelf is ALREADY in the dossier... So
candidates arrive") is FALSE in practice, measured on jc1: 4 of 19 residual lines carried a
candidate, 15 did not, and the mapper spent ~12 minutes at 61 s/turn acquiring labels it then
cited as `fdc:<id>` - proof the data was reachable by the offline tool. Root cause is not the
shelf code (map-preresolve attaches candidates correctly): it is that NOTHING FILLS THE CACHE for
a run's terms. fdc_lookup.cache_fill exists, is fixtured, takes a term list, and no daemon road
calls it. The 150 cached terms are leftovers from an earlier manual pass.

The key file exists at meal-prep\db\fdc-api-key.txt (verified 2026-08-25), so the fill can run
today. fdc_lookup.api_key() returns None on a missing key and cache_fill records a could-not-run
without freezing "FDC has nothing" into the cache - that degrade behavior is already built and
already fixtured.

### 3.2 The design decision this plan takes, and the one it refuses

TAKEN: fill the cache with the RUN'S OWN EXACT TERMS. cache_get's docstring is a ruling: "KEYED BY
THE RECIPE'S OWN TERM, not by a canonical food name, and that is the point." Filling per-run with
exact terms makes exact-key hits and respects that ruling.

REFUSED: fuzzy or head-noun keying in Get-FdcCandidates. The eval noted 5 of 15 misses were foods
the cache held under a head noun (`Parsley leaves` vs `parsley`) - but head-noun matching is an
IDENTITY assertion, and the estate's founding mapping rule is that local/mechanical code may rank
but never assert identity. The trap is concrete: stripping `garlic cloves` toward its head noun
reaches `cloves`, and the vocabulary near-miss table already shows `garlic cloves` sitting next to
`Ground Cloves [ground-cloves]` - a wrong-food shelf served with mechanical confidence. With
per-run exact fill, the head-noun gap mostly disappears (the run asks FDC for `Parsley leaves`
itself); whatever FDC genuinely lacks under the recipe's phrasing remains the mapper's licensed
web read, which is the correct residue. Do not build fuzzy keying. If the drill shows exact fill
still missing badly, that is a MEASUREMENT to bring to Brad, not a license to guess.

### 3.3 The change

1. New daemon method `fill_fdc_shelf(self, slugs, tables)` in hunt-daemon.py, placed beside
   preresolve. Behavior:
   - Collect the fill list from the preresolve TABLES (not the extraction): every row of every
     slug's table where `resolution != 'resolved'` OR `fooddb_known` is false, taking `term`
     (falling back to `raw`). Dedupe case-insensitively via fdc_lookup._cache_key.
   - Call fdc_lookup.cache_fill(terms, page_size=3, pause=0.5) IN THE EXECUTOR
     (loop.run_in_executor, the ps()/py() pattern) - it is synchronous network code and must not
     stall the event loop.
   - UNDER A LOCK: `self.fdc_lock = asyncio.Lock()` in __init__ beside food_db_lock. Two map
     workers can fill concurrently and cache_write is a whole-file write; this is the
     ingredient-resolutions lesson a third time. The CONCURRENCY FIXTURE MUST BE PROVEN to fail
     with the lock removed before it counts, and note the CHANGE M correction: with the I/O
     synchronous on the loop nothing interleaves, which is WHY the executor call is part of the
     spec and not an optimization.
   - DEGRADE, NEVER BLOCK - the pre-pass philosophy, stated in gather_price_evidence's docstring.
     A missing key, a transport failure, or a whole fill failure logs ONE finding naming the count
     ("F1: the FDC fill could not run (%s) - the mapper will acquire labels itself for N term(s)")
     and the map dispatch proceeds exactly as today. Exit 2 semantics do not apply here; this
     stage can only add evidence, never gate.
   - Timebox: pass cache_fill's own loop a deadline via the terms slice if needed; a batch of ~20
     terms at page_size 3 with 0.5s pause is ~30-60s of wall, which is fine. Do NOT parallelize
     the HTTP calls; api.data.gov rate limits and a throttled key reads as "FDC has nothing",
     which fdc_lookup's header calls the worst possible lie.
2. Call order in map_lane's worker: preresolve(slugs) -> fill_fdc_shelf(slugs, tables) ->
   RE-RUN preresolve(slugs) -> dispatch. The second preresolve re-attaches the now-warm shelf into
   the tables and the dossier. It is mechanical, measured at ~5s, idempotent, and stamps its own
   lane pair through the existing road. Do NOT try to splice candidates into the already-built
   table in Python - map-preresolve owns that rendering (the attach at ~500-514 formats the shelf
   into `evidence` with its own wording) and a second renderer is a fork.
   - Wrap the fill+rerun so a fill that added ZERO terms (all already cached) skips the re-run:
     cache_fill returns {added, skipped, failed}; `added == 0 and failed == 0` means the first
     table is already as warm as it can get.
3. Shelf-coverage visibility (this is F5's whole work item, folded here): after the second
   preresolve, log one line per batch: "map shelf: X of Y unresolved term(s) carry FDC candidates;
   FDC lacks: <terms>" computed from the tables (a row's evidence containing the attach's marker
   string vs not - grep map-preresolve ~500-514 for the exact marker it prepends and match on
   that). Terms FDC genuinely lacks are NOT findings - they are the mapper's legitimate web reads.
   The line exists so the drill and Thursday can correlate mapper turns against shelf coverage
   without transcript archaeology.

   **CORRECTED 2026-08-25 (F1 build, measured against map-preresolve.ps1's attach at lines 495-514).**
   "X of Y unresolved term(s)" names the wrong population. The attach only ever runs inside the
   `if (-not $foodDbKnown)` branch, so a row that is unresolved but HAS a food-macros-db row can
   never carry a shelf marker and counting it as a gap would report a defect that does not exist -
   and the reverse case is real too: a SETTLED line with no DB row still needs a label and does get a
   shelf. The line as built reads "map shelf: X of Y term(s) with no food-DB row carry FDC
   candidates; FDC lacks: ...", computed over exactly the rows the attach can serve, deduped through
   fdc_lookup._cache_key. The FILL list is the wider set section 3.3.1 specifies (unresolved OR no DB
   row) and is unchanged - the two populations are deliberately different and the code says so.
4. map_prompt: no contract change. It already says prefer the shelf and cite `fdc:<id>` (CHANGE M
   wrote that language). One addition, in the licensed-read paragraph: "Most terms now arrive with
   the shelf already filled for this run; a term with no shelf candidates means FDC was ASKED and
   lacks it, so go to the open web for that one without re-checking FDC."

### 3.4 Fixtures (hunt_daemon_selftest.py, new section "F1 - the shelf is filled before the mapper is paid")

- MUST FIRE: given stub tables with 3+ unresolved terms, fill_fdc_shelf passes exactly the
  unresolved/fooddb-missing terms to cache_fill (stub fdc_lookup.cache_fill via monkeypatch;
  assert the term list, deduped, resolved rows excluded).
- MUST FIRE: the map worker's order is preresolve, fill, preresolve, dispatch - assert via the
  FakePS call sequence (two map-preresolve invocations around one recorded fill) and that the
  DISPATCHED tables are the second preresolve's.
- CLEAN TWIN: `added == 0 and failed == 0` skips the second preresolve - exactly one
  map-preresolve call in the FakePS record.
- MUST FIRE: a fill that throws (stub raises) produces the degrade finding and the mapper is
  STILL dispatched - the FakeDispatch saw the map prompt; the finding names the count.
- CONCURRENCY, with neuter proof: two workers filling overlapping term lists against a scratch
  cache file -> the cache holds the union. PROVE it loses terms with fdc_lock removed (the
  executor+lock interplay per CHANGE M's correction). 3+ terms per worker.
- MUST FIRE: the shelf-coverage log line renders with the correct X of Y and names the lacking
  terms (drive with a table whose evidence strings mark 2 of 5 as shelved).

### 3.5 Target to measure in the drill

Map batch of 2-4 with a warm-fillable shelf: <=6 turns, <=300k raw - the ORIGINAL judge-contract
target, now expected to be reachable because jc1's miss decomposed as ~15 acquisition turns that
this change deletes. Compare against jc1's 12 turns / 444,300 and 6b's 22 / 1,084,231. Also
report sec/turn: mapper turns should drop from 26-61s (tool turns) toward 10-20s (reasoning).

### 3.6 Plan corrections owed in the same commit

- PLAN-hunter-judge-contract-2026-08-25.md section 3.1: CORRECTED - the "candidates arrive"
  premise, with the jc1 measurement (4 of 19) and the root cause (nothing called cache_fill).
- PLAN-recipe-hunter-v3-2026-08-23.md S4: append to the existing CORRECTED block - the mechanical
  pre-resolve now includes a per-run FDC fill between two preresolve passes.

## 4. F2 - the registrar rules a batch from a dossier

### 4.1 The measured defect, and one stale claim corrected

jc1: 10 turns and 81,929 raw to rule ONE proposal (prosciutto), with the evidence block already in
the prompt. 6b: 12 dispatches, 12.0 min of wall. The eval's F2 sentence "dispatched once per
proposal, serially, inside assemble" is STALE: pass-1 concurrency landed with c36879cd and 6b
predates it. The remaining defect is TURN ECONOMY (10 turns of self-directed greps and feed reads
per ruling) and SESSION COUNT (one dispatch per proposal, each paying ~7s + ~18k + cold cache).
EVAL-latency-cold-read-2026-08-25.md must carry a CORRECTED block for that sentence in the F2
commit.

### 4.2 The change

1. ONE DISPATCH PER SLUG-BATCH OF PROPOSALS, not one per proposal. registrar_rulings builds its
   `work` list as today, then dispatches the commodity-registrar ONCE with every proposal in a
   dossier. This is the decider's shape: 8 candidates, one dossier, one schema'd verdict array.
   - The collision re-check (pass 2) STAYS byte-for-byte. One session seeing its siblings makes
     the bread-crumbs/breadcrumbs pair visible IN-PROMPT (an improvement the plan should state in
     the prompt: "these proposals are siblings in one batch; two of them approving near-identical
     ids is the exact defect you exist to prevent"), but the mechanical check remains the
     backstop, per the belt-and-braces rule the changed-nothing guard set.
   - A batch of ONE renders the same dossier with one entry - no special case, no second prompt.
2. THE EVIDENCE GROWS to cover what the agent currently greps for itself. Read
   commodity-registrar.md's checklist and pre-gather each item into the dossier per proposal:
   - the near-miss rows across all three namespaces (exists: registrar_evidence_block);
   - the declared-same-thing layer: matching rows from grocery\recipe-floor-id-map.json;
   - the LIVE FEED check: whether the proposed id or any near-miss id appears in
     grocery\out\smp-feed.json, with its price cell (the def says "ALWAYS check the live feed" -
     hand it the answer);
   - label grep results: catalog rows whose LABEL (not id) shares a stem with the term.
   Keep the NOT_EXHAUSTIVE language verbatim and the authority language: the registrar may still
   run every check itself; what is removed is the obligation, never the right. Its tools do not
   change. This is CHANGE A's exact recipe applied one gate over.
3. Schema: extend hunt_lib.REGISTRAR to an array form, or add REGISTRAR_BATCH with
   `rulings: [{proposed_bid, verdict, bid, reason}]` and required per-item fields matching the
   current single shape. Validate with a batch-aware validate_registrar that maps each item
   through the existing checks and names the item index in every problem (the dispatch re-ask
   must tell the model WHICH ruling was malformed). The single-item REGISTRAR schema and
   validator stay for any other caller until the drill proves the batch road, then retire them in
   the same commit IF nothing else references them (grep first; decide from the grep, not from
   memory).
4. Prompt: registrar_prompt becomes registrar_batch_prompt(slug, work_items) rendering per
   proposal: term, proposed id, the mapper's case, the near-miss block, the floor-map rows, the
   feed answer, the label greps. Keep the three-verdict contract and the "reason is the sentence a
   person reads" language verbatim.
5. Agent definition: commodity-registrar.md gains an ADDED paragraph mirroring the auditor's:
   in a daemon-driven run the sweep arrives pre-gathered in the dispatch; verify the shown work,
   re-derive what you distrust, spend your turns on the variant-vs-duplicate JUDGMENT. Then
   ops\audit-prompt-backup.ps1 -Sync, committed.

### 4.3 Fixtures

- MUST FIRE: three proposals produce ONE registrar dispatch whose prompt contains all three terms
  and ids (FakeDispatch prompt assertion), and the returned array lands as three rulings.
- MUST FIRE: the dossier carries the feed answer and the floor-map rows (assert a known marker
  from each source renders into the prompt, the render_audit_dossier fixture pattern).
- MUST FIRE: a malformed item in the array is refused with the ITEM INDEXED in the problem text,
  and no ruling from that payload is applied (never partial - the CHANGE W whole-payload rule).
- CLEAN TWIN: the collision re-check still fires on two sibling approvals colliding, exactly as
  its existing fixture proves - re-point that fixture at the batch road, do not duplicate it.
- MUST FIRE: a null batch payload = NO ruling for ANY proposal, assembler refuses the unapproved
  ids (silence is not consent - the existing fixture, re-pointed).
- Neuter proofs per the standing rule; 3+ proposals in every batch fixture.

### 4.4 Target to measure

<=3 turns and <=120k raw per proposal BATCH (vs 9-10 turns and 62k-233k per single proposal).
Wall: one session's startup instead of N.

## 5. F3 - QA rules from a dossier (the tail's judge contract)

### 5.1 The decision this plan takes, and the one it explicitly does NOT

The eval's F3 named the write->qa->repair->re-qa tail as four sessions over the same material and
flagged MERGING stages as a check-independence question for Brad. This plan does NOT merge any
stage: the writer writing and then QAing its own work is worth nothing, and source-qa's whole
value is an independent reader. What this plan takes is the smaller, proven move: source-qa keeps
its own session and gets its material INLINE, exactly as the auditor did in CHANGE A. Independence
is about WHO rules, not about who does the file I/O.

If Brad wants the larger collapse evaluated (one combined tail session, or QA folded into the
wave audit), that is a design conversation this plan leaves open deliberately - the eval's bound
(2 min serial needs F1+F2+F3-large) should be re-measured after this build lands, because F1 may
buy enough that the large collapse is not worth its independence cost.

### 5.2 The change

1. New daemon method `qa_dossier(self, slug)` modeled directly on writer_dossier (~2549): render
   inline (a) the transcription's ingredients and instructions from extracted\<slug>.json, (b)
   the BUILT SPEC's reader-facing view - ingredient lines with buy strings, the make_it steps,
   the stat block - read from SPECS_DIR\<slug>.json (respect self.specs_dir for drills), and (c)
   the QA battery report qa\<slug>.battery.json with each check's numbers, the
   render_audit_dossier flatten pattern.
2. qa_prompt embeds the dossier. KEEP verbatim: the anchor-on-the-transcription rule, the
   blocked-domain rule, the verdict-only contract, the re-QA framing on attempt 2. RECAST the
   file pointers as "also on disk at ... if you want the raw artifacts". The live-page fetch
   stays a RIGHT ("read the live page too when the domain is fetchable") - it is the one thing
   the dossier cannot carry and it is part of the fidelity check's value; expect QA turns to
   drop to ~2-3, not 1, and say so in the target.
3. The verdict file write moves to the daemon: source-qa currently writes qa\<slug>.json itself.
   Under the pen-ownership rule the daemon already holds every other bookkeeping pen; move this
   one the same way ONLY IF the auditor of the payload road is trivial - the QA schema already
   returns {slug, verdict, owner, findings}, and the daemon can write the file from the payload,
   retiring the agent's Write. Check first whether anything reads qa\<slug>.json expecting
   agent-authored extras beyond the schema (grep consumers; wave-preaudit and the auditor read
   it). If consumers only read schema fields, move the pen; if not, leave the write with the
   agent and record why in a comment. Do not guess - grep and decide.

   **CORRECTED 2026-08-25 (F3 build, from the grep this paragraph ordered).** "wave-preaudit and the
   auditor read it" is wrong: NOTHING in the estate reads qa\<slug>.json. Not the daemon (qa_lane
   rules off the payload and never opens the file), not wave-preaudit.ps1, not hunt-run.ps1, not
   coverage_check.py, not any agent definition. The only reference anywhere is qa_repair_prompt
   telling a repairing agent where the file is, and that pointer keeps working because the daemon
   writes the same path from the same fields. So the pen MOVED, with a further gain this paragraph
   did not name: a verdict file written from the payload cannot disagree with the verdict the run
   acted on, which a separately-authored file always could.
4. recipe-source-qa.md gains the same ADDED paragraph as the registrar (material arrives inline;
   verify, do not re-fetch by default; the live source page remains yours to read). -Sync,
   committed.

### 5.3 Fixtures

- MUST FIRE: the QA dispatch prompt contains the transcription lines, the spec's buy strings and
  the battery numbers (known-marker assertions), and the authority/anchor language verbatim.
- CLEAN TWIN: a missing battery report renders as ANNOUNCED-missing (the CHANGE A unreadable-
  dossier pattern), never as an empty section.
- MUST FIRE: if the pen moves per 5.2.3 - the daemon writes qa\<slug>.json from the payload and
  the file matches the schema fields; a payload with no verdict writes NOTHING and the recipe is
  STUCK (B5: no verdict is never a pass).
- Existing one-repair fixtures are untouched and must stay green unmodified - they are the proof
  the cycle did not change shape.

### 5.4 Target to measure

Source-QA: <=3 turns, <=120k per recipe (vs 6b's 6-8 turns / 104k-143k; the floor is ~2 because
the live-page read is legitimate). QA repair stays on its CHANGE A patch road, unchanged.

## 6. F4 - the scoped re-audit gets the repair delta

Small, one method touched. After a recipe-local patch repair, the scoped re-audit currently
receives the standard audit_prompt with the refreshed battery dossier (CHANGE A). Add to that
prompt, for re-audits only (the `why` parameter is non-empty exactly then): a rendered block
"WHAT THE REPAIR CHANGED", listing per repaired slug the fields the patch carried (the daemon has
the payload in repair_by_patch; thread the {slug: fields-keys+reason} map into run_wave's scoped
re-audit call) plus the repair's no_change reasons where returned. The auditor then verifies the
delta against the refreshed numbers instead of diffing blind.

Fixtures: MUST FIRE - the re-audit prompt names the patched fields for the repaired slug; CLEAN
TWIN - a first audit (why empty) carries no delta block. Neuter proof: empty the map and the
must-fire goes red. Target: scoped re-audit <=4 turns (vs wave-2's 28-turn full re-audit shape;
CHANGE A's <=10 remains the FULL-audit target).

## 7. F5 and F6 and F7 - measurement items, not builds

- F5 (mapper turn latency): the work item is F1's shelf-coverage log line (3.3.3). Nothing else.
  The drill report correlates mapper turns with shelf coverage; if turns stay high with a warm
  shelf, that is a NEW finding for Brad, not a build-time improvisation.
- F6 (pricer): NO CODE CHANGE. price_prompt already renders the evidence inline
  (price_evidence.render, verified at ~2156) and jc1 measured 6 turns / 12 s/turn, which is
  adjudication, not retrieval. Record the pricer's turns in the drill report against an
  informal <=8-turn expectation; the singleton and the attended-store reality stand. The plan
  states this so the implementer does not invent a pricer change looking for the 2 minutes there.
- F7: free floor, no work item, stated so nobody optimizes it.

## 8. H - hygiene defects from the jc1 drill, fixed in this build

### H1. The food-DB conflict rule learns the difference between disagreement and rounding

Measured: 5 conflict findings on jc1, of which 2 were pure rounding (Spinach protein 2.9 vs 2.86,
Fresh Parsley 3 vs 2.97 - same serving basis, hundredths apart) and 3 were real (Pork Chops 112g
vs 100g basis). At width the noise buries the saves. Rule for write_food_db_rows' conflict check:
if serving_grams, serving_qty and serving_unit match EXACTLY and every macro differs by <=5
calories (calories field) / <=0.5 g (protein_g, carbs_g, fat_g), treat as the identical-row case:
silent skip, no finding. Any serving-basis difference remains a full conflict regardless of macro
proximity - a different basis is a different claim about the food, which is precisely the Pork
Chops save. The 5-cal figure is the estate's macro-recompute tolerance; 0.5 g is tighter than the
2 g recompute tolerance ON PURPOSE (a DB row is a source of truth, not a derived figure - state
this in the comment). Fixtures: MUST FIRE rounding-noise twin skips silently (3+ rows); CLEAN
TWIN the Pork Chops shape (same macros ballpark, different basis) still refuses and quotes both;
neuter proof: zero the tolerances and the noise case goes red.

### H2. A no-publish drill must not write live grocery ledgers

Measured: the jc1 drill, with every seam engaged and publish dry, still wrote live
grocery\ingredient-queue.json, grocery\carriage.json and meal-prep\db\considered-dishes.json.
The queue rows are real evidence (kept, deliberately) but the SEAM GAP is a defect: the next
drill may not be so lucky. Work item: add scratch seams for the three, modeled exactly on
--ledger/--food-db. INVESTIGATION FIRST, and this is an explicit instruction not to guess: read
ingredient-queue.ps1, the carriage writer (grep grocery\ for carriage.json writers), and
considered-dishes.ps1 for an existing -File/-Path parameter; thread one through hunt-daemon
(--queue, --carriage, --considered args -> the ps() call sites) if present, add one modeled on
wave-publish's -LedgerPath where absent. Every touched script keeps its own selftest green.
Fixtures: MUST FIRE per seam - a daemon pointed at a scratch path never passes the live path to
the script (FakePS argument assertion, the costed_path pattern at spec_args ~2220).

### H3. The drill, this time reaching write and audit

The jc1 drill parked both recipes at pricing and CHANGE W / CHANGE A shipped unmeasured. This
build's drill MUST produce their numbers. Procedure, not improvisation:

1. Scratch seams: --pool/--ledger/--specs/--costed/--food-db plus the new H2 seams; SHORT root
   (C:\tmp\lf1); NO --publish; never headless against stores; the GPU card rules of
   ensure_local_model apply unchanged (hand-start serve.ps1 only outside the protected windows,
   or with Brad's say-so, and stop it after).
2. CANDIDATE SELECTION IS PRE-QUALIFIED, so nothing parks: before seeding the scratch pool, run
   map-preresolve standalone over candidate extractions (or reuse C:\tmp\jc1's two, whose only
   pending term was `part skim mozzarella slices`) and pick 2-3 candidates whose every line is
   resolved+bid or optional - zero absent_terms means the price lane is never entered and the
   tail runs. If no such candidate exists in the pool, take the jc1 pair and pre-answer the one
   pending term through ingredient-queue's normal attended road WITH BRAD, never by inventing a
   price.
3. Run all lanes through qa plus the wave; collect hunt-run.ps1 -LaneSummary and -StageSummary.
4. Report, verbatim tables: every changed lane's turns/raw against section targets (map <=6/300k,
   registrar <=3/120k per batch, write <=4/250k, QA <=3/120k, audit <=10 full / <=4 scoped,
   recipe-local repair <=5/200k), next to BOTH baselines (6b section 1 of the judge-contract
   plan, and jc1 from the eval). A miss is reported with its measurement and is a conversation
   with Brad - never a softened target, never a hidden number.

## 9. Build order, one verified unit per commit, push as each lands

1. F1 (fill + reorder + coverage line) with its plan corrections (3.6).
2. H1 (conflict tolerance) - small, unblocks clean F1 drill output.
3. F2 (registrar batch dossier) with the EVAL CORRECTED block (4.1).
4. F3 (QA dossier, and the pen decision from 5.2.3).
5. F4 (re-audit delta).
6. H2 (drill seams).
7. H3 (the drill), then the report, then STOP.

After every suite-touching unit: hunt-daemon.py --selftest (baseline 168 ok, growing), hunt_lib.py
--selftest and --parity (63/63 stays or grows), map-preresolve.ps1 -SelfTest and hunt-run.ps1
-SelfTest where touched, ops\audit-prompt-backup.ps1 -Sync after any agent-def edit, committed.
Estate mechanics, restated: PS 5.1; Python is C:\Codex\Python312\python.exe, never bare python;
no em dashes anywhere user-visible; exit 2 = blocked, never clean; collection fixtures use 3+
elements; concurrency fixtures PROVEN with the lock removed; git pull first; scoped adds only,
never git add -A; CRLF preserved on estate files; a multi-edit patch that fails partway means
re-verifying every edit it carried. Other sessions write grocery\* and graph\* - normal noise.

## 10. How this could backfire, named

- The FDC fill hammers api.data.gov at width: page_size 3, pause 0.5, fill-per-batch (not
  per-run-upfront) bounds it to ~residual-count calls per micro-batch. If Thursday's width makes
  the pause a wall-clock item, that is a measured conversation, not a reason to parallelize HTTP.
- The registrar batch dossier tempts a rubber stamp across siblings: the collision re-check stays,
  the authority language stays, and the drill reports the registrar's rulings against the same
  scrutiny the single road got. If it approves everything in one turn for several waves, that is
  a conversation with Brad (the CHANGE A auditor rule, applied here).
- The QA dossier could starve the live-page check: the fetch right is explicit in the prompt, and
  the drill report must note whether QA fetched at all. If QA stops fetching entirely, say so.
- A pre-qualified drill (H3.2) cannot catch pricing-path regressions: correct - it is not trying
  to. The price lane is measured by jc1 and by Thursday; H3 exists to measure the tail.
- cache_fill freezing a transient FDC outage as "asked, nothing there": already handled - a
  failed lookup is NOT stored (fdc_lookup's own rule, fixtured there). Do not re-implement it.

## 11. What DONE means

All new fixtures green with neuter proofs recorded in comments and the concurrency proofs run
with locks removed; suites at or above their baselines (daemon 168+, parity 63/63+); -Sync clean;
the H3 drill's -LaneSummary and -StageSummary reproduced verbatim in the final report next to
both baselines; every target met or its miss reported with the measurement; the four plan
documents carrying their CORRECTED/amendment blocks (this file included, for whatever the build
finds); everything committed and pushed. The Thursday wide proving run remains a separate session
and is not the implementer's to start. Anything beyond this scope - the F3-large tail collapse,
head-noun shelf keying, pricer changes, cap raises - is a proposal for Brad, never a follow-on
build.
