# PLAN: the map lane finishes its judge contract - M1 through M4, from the lf1 transcripts

Date: 2026-08-25. Author: the latency build session, after reading the lf1 drill's own agent
transcripts. Status: WRITTEN FOR A SINGLE IMPLEMENTING SESSION, ordered by Brad on 2026-08-25 ("build
all four in their entirety"). The implementer asks Brad for the weekly usage % before starting and at
each numbered unit boundary, and STOPS at 80%.

THIS DOCUMENT IS THE SPEC. Every anchor below was re-grepped against commit d754e610 and every
measurement was read out of the lf1 drill's own session transcripts, not inferred. Where this plan
and code reality disagree, fix THIS plan in the same commit, marked CORRECTED with date and
measurement - the standing rule that produced five corrections across the last two builds.

## 0. The verdict in one paragraph

The lf1 drill (EVAL-latency-lf1-drill-2026-08-25.md) reported that the mapper takes 22 turns whatever
you hand it, and left the diagnosis as future work. The transcripts settle it, and the answer is a
contract deadlock rather than a mystery: **the FDC shelf renders three of the six numbers a food-DB
row needs, and it does not render the fdc_id at all**, while map_prompt requires `source: fdc:<id>`
and write_food_db_rows REFUSES any row citing neither an id nor a URL. A mapper that obeys the
contract literally cannot build a row off the shelf, so it goes and re-acquires the same food - and
on round 1 it did that by querying api.nal.usda.gov directly with **DEMO_KEY**, which is the exact
throttling lie fdc_lookup's own header calls the worst possible one. That plus a partially-rendered
macro precheck and un-rendered food-DB rows accounts for roughly 20 of the 22 turns, measured call by
call in section 1. M1 closes the deadlock, M2 finishes the dossier, M3 fixes a park-forever routing
hole the drill hit, M4 is prompt-only hygiene.

## 1. The measurement this plan is built on

Read from the lf1 transcripts at `~/.claude/projects/C--Codex-ThriftyCrew/`:
`167dfff7-...jsonl` (round-1 mapper, 631 s, 22 turns) and `2694a670-...jsonl` (round-2 mapper, 368 s,
22 turns). Both sessions: **35 assistant messages, 21 tool calls, ZERO thinking blocks.** The wall is
tool round-trips plus generation, which is why no pin or effort change appears anywhere in this plan.

**Round 1, 21 tool calls.** 6 x WebFetch to `api.nal.usda.gov/fdc/v1/foods/search?...api_key=DEMO_KEY`
for chicken breast, mozzarella, parmesan, seasoned bread crumbs, all-purpose flour and whole-grain
mustard - five of which the shelf had already covered (the run logged `map shelf: 13 of 13`). Then 5
turns discovering the tool it was re-implementing: Grep for `api\.nal\.usda\.gov|FDC_API_KEY`, Read
`fdc_lookup.py`, Grep its argv, then three Bash loops shelling `fdc_lookup.py` itself. Then 4 more
web calls chasing one branded mustard label, and 3 extraction Reads.

**Round 2, 21 tool calls, on a batch where 2 of 3 recipes had ZERO residual lines.** 3 x Read of the
extractions; 1 Grep plus **4 full Reads of the LIVE `meal-prep\food-macros-db.json`** (the drill was
pointed at a scratch copy through --food-db, so those reads were against the wrong file); 4 turns
re-reading `mapped-pre\<slug>.json` for the `macro_precheck` block, three of them lost to environment
friction (bare `python` hitting the Windows Store shim, then an encoding ladder); and 9 web calls for
smoked sausage and shredded cheddar, which FDC genuinely lacks and the coverage line correctly said so.

**The deadlock, stated exactly.** `Get-FdcCandidates` (map-preresolve.ps1:962-966) renders each
candidate as `{description} [{data_type}] per 100 g: {cal} cal, {P} P, {C} C`. The cache row it is
rendering from carries `fdc_id`, `description`, `data_type`, `brand`, `basis`, `macros` (calories,
protein_g, carbs_g, **fat_g**, **fiber_g**) and `portions` (measure + grams). So the renderer drops
the id and both remaining macros. Meanwhile hunt-daemon.py's map_prompt requires
`item, serving_grams, calories, protein_g, carbs_g, fat_g` and asks for `fdc:<id>` in `source`, and
`write_food_db_rows` refuses a row with a missing macro AND refuses a row whose source is neither
`fdc:` nor a URL. Three of those six required fields and the citation itself are unobtainable from
the shelf as rendered.

## 2. What does not move, restated so nobody relitigates

Every gate and threshold; the Atwater gate, the provenance gate and H1's conflict tolerances; the
price lane singleton; the model pins and effort settings (PLAN v3 s11 - and section 1 shows tuning
them would buy nothing here); the registrar's existence, authority, batch road and collision
re-check; QA's one-repair rule; the auditor's authority and tools; the unbid hold (map-preresolve's
`holds` rows, ruled by the daemon, untouched by M3); the changed-nothing repair guard; never-auto-
coerce; ps_invoke / py_invoke as the only marshalling roads; the daemon holds every pen. No fuzzy or
head-noun cache keying - that fork stayed closed in PLAN-latency 3.2 and stays closed here.

## 3. M1 - the shelf renders a whole row, and the id that cites it

### 3.1 The change, in one function

`meal-prep\pipeline\map-preresolve.ps1`, `Get-FdcCandidates` (declared line 942, render loop 962-966).

1. Render **4** candidates, not 3 (`Select-Object -First 4`). Four is the shelf's whole job: FDC's
   curated tiers rarely return more than a handful and the fourth row is often the right form.

   **CORRECTED 2026-08-25 (M1 build, measured against the live meal-prep\db\fdc-cache.json).** The
   cache could not hold a fourth row. `cache_fill` defaulted to `page_size=3` and `fill_fdc_shelf`
   passed `page_size=3` explicitly, with its own docstring calling that deliberate for api.data.gov's
   rate limit. Measured over the 170 cached terms: 109 carry 3 candidates, 45 carry 2, 15 carry 1, 1
   carries 0, and NOTHING carries 4. `-First 4` would have rendered three rows forever. Brad ruled on
   2026-08-25: bump the fill to 4. It costs ZERO extra requests - one search returns N rows - so the
   rate-limit reasoning is untouched, and the docstring at hunt-daemon.py:1204 was corrected in the
   same commit. The 170 terms already cached KEEP their 3, because cache_fill never re-asks a term it
   has seen; only terms new to the cache render four.
2. Render, per candidate, in this order and with these exact labels:
   `fdc:{fdc_id} {description} [{data_type}] per 100 g: {cal} cal, {P} P, {C} C, {F} F, {fiber} fiber`
   - `fdc:{fdc_id}` FIRST and rendered as the literal citation string the mapper must copy into
     `source`. It is the whole point of the change: the prompt asks for `fdc:<id>` and the shelf has
     never once shown one.
   - fibre is rendered because `atwater_check` credits it at 2 kcal/g and a legitimate high-fibre row
     FAILS the gate without it (fdc_lookup.py:196-203 says so in its own comment).
   - A macro FDC did not state renders as `?`, never as 0. A missing number and a zero are different
     claims about a food, and the row schema treats them differently.
3. Append the stated household portions when FDC carries them, as
   `portions: 1 tbsp=3.8g, 1 cup chopped=60g` (cap at 3). The food DB wants a serving in BOTH a
   household measure and grams (fdc_lookup.py:102-112 exists for exactly this), and without them the
   mapper must invent `serving_qty`/`serving_unit` or go find a label.

   **CORRECTED 2026-08-25 (M1 build, measured against the live cache).** This clause is BUILT and
   FIXTURED but DORMANT, and the reason is upstream of the renderer: `_portions` reads `foodPortions`,
   which the `/foods/search` endpoint fdc_lookup calls does not return - only the `/food/{id}` detail
   endpoint does. Measured: **0 of 170 cached terms, across roughly 420 candidates, carry a single
   portion.** So the justification stated here - that without portions the mapper must invent
   `serving_qty`/`serving_unit` or go find a label - STANDS AS A GAP, and M1 does not close it. Brad
   ruled on 2026-08-25: build the clause with its fixture so the shelf carries portions the day the
   data exists, report the dormancy, and leave the detail-fetch road (3-4x the API calls per term, a
   new fetch nobody specced) as a proposal rather than an M1 improvisation.

4. Nothing else in the file changes. The `$evidence.Add(...)` wording at 512-515 stays verbatim - it
   is the marker `Daemon.FDC_SHELF_MARKER` matches on, and changing it silently breaks
   `shelf_coverage`. If you must touch it, change the constant in the same commit and say so.

### 3.2 Fixtures (map-preresolve.ps1's own -SelfTest)

- MUST FIRE: a stub cache with 4+ candidates renders all four, each carrying `fdc:<id>`, five macro
  numbers and its portions. Assert on the `fdc:` prefix explicitly - that string is the contract.
- MUST FIRE: a candidate missing `fat_g` renders `?` in that slot and NOT `0`.
- CLEAN TWIN: a term with no cache entry still returns empty string and the row carries no shelf line
  (a cold cache must still look exactly like a cold cache).
- MUST FIRE: the shelf line still begins with the `USDA FDC rows that MENTION this term` marker, so
  `Daemon.shelf_coverage` keeps counting. Drive it through the real evidence assembly, not the
  renderer alone.
- NEUTER PROOF, to be RUN and recorded: revert the render to the three-number form and watch the
  first two go red.
- 3+ elements per collection fixture, per the estate rule.

### 3.3 Target

The round-1 class - 6 direct FDC queries plus 5 turns of tool archaeology - disappears entirely. That
is 11 of 22 turns on round 1's shape. Measure it in the drill (section 7), do not assert it here.

**MEASURED 2026-08-25 (EVAL-map-lane-latency-m1-drill).** It disappeared entirely, exactly as
written: the batch-B mapper transcript carries ZERO queries to api.nal.usda.gov, ZERO uses of
DEMO_KEY and ZERO turns of fdc_lookup archaeology, and the batch came in at 13 turns against
round 1's 22. Two food-DB rows written by the drill cite `fdc:2067385` and `fdc:171241`, a
source that was unobtainable before this change.

## 4. M2 - the map dossier carries what the contract forces the mapper to fetch

Same move CHANGE W made for the writer and CHANGE A made for the auditor, applied to the three things
round 2 measurably went to disk for. New daemon method `map_dossier_extras(self, slug, table)` in
hunt-daemon.py, rendered by `map_prompt` (line 2136) per slug, directly after that slug's existing
block.

### 4.1 The three sections, exactly

1. **THE FOOD-DB ROWS THIS BATCH ALREADY HAS.** For every row in the table where `fooddb_known` is
   true, look the food up in `self.food_db_path` (the seam, NOT the live path - round 2 read the live
   file while pointed at a scratch copy) and render one line per food:
   `{item}: {serving_qty} {serving_unit} = {serving_grams} g, {cal} cal, {P} P, {C} C, {F} F`.
   Read the DB ONCE per dispatch and cache it on the instance for the run, the `commodity_rows`
   pattern at hunt-daemon.py:1436. A food whose row cannot be found renders as
   `{item}: the table says a row exists and it could not be read - check it yourself`, which is the
   announced-unreadable rule, never silence.
2. **THE MACRO PRECHECK, WHOLE.** map_prompt currently renders `computed_per_serving` and the source
   figures and stops. Render also, from the same `macro_precheck` block map-preresolve writes
   (map-preresolve.ps1:660-666): `state`, `reason`, `lines_covered` / `lines_total`,
   `portion_factor`, every `tuning` line verbatim, `uncovered_lines`, and `missing_db_items`. The
   tuning lines are what round 2 spent four turns digging for - one of them read
   "added Rice base 200g (src scale)" and was the entire explanation for a 591-vs-468 calorie
   disagreement the mapper was otherwise going to litigate by hand.
3. **THE SOURCE'S OWN YIELD.** From `extracted\<slug>.json`: `servings`, plus `title` and
   `source_url`. Round 2 read all three extractions and this is what it needed from them; the raw
   ingredient lines are already in the table (`raw` per row) and must NOT be duplicated - a second
   copy of the lines is a second thing to disagree with the first.

### 4.2 Bound it, and say so

Cap the whole extras block at ~4,000 characters per slug, exactly as `render_audit_dossier` caps
itself, and when the cap bites say so in the block ("N more food-DB rows not shown - read the DB for
those") rather than cutting quietly. A quietly cut dossier has the mapper believe it saw everything.

### 4.3 Fixtures (hunt_daemon_selftest.py, new section "M2 - the map dossier carries the estate")

- MUST FIRE: the map prompt contains a known food-DB row's numbers for a `fooddb_known` food (3+
  foods in the fixture), and they come from the `--food-db` SEAM path, not the live DB. Point the
  fixture's seam at a scratch file whose numbers exist nowhere else, and assert those numbers.
- MUST FIRE: the prompt carries every `tuning` line and the `missing_db_items` list verbatim.
- MUST FIRE: the prompt carries the extraction's `servings`, and does NOT re-render the raw
  ingredient lines a second time (assert one occurrence of a known raw string, not two).
- CLEAN TWIN: an unreadable food DB or a missing extraction renders as ANNOUNCED-missing, and the
  rest of the prompt still builds.
- MUST FIRE: the cap announces itself when it bites.
- NEUTER PROOFS, RUN and recorded: drop each of the three sections in turn and watch its case go red;
  point the DB read back at the live path and watch the seam case go red.

### 4.4 Target

Round 2's shape loses 3 extraction Reads, 1 Grep, 4 DB Reads and 4 precheck-hunting turns: 12 of its
21 tool calls. The standing target from PLAN-latency 3.5 is **<=6 turns and <=300k raw per batch** and
it does NOT move. If M1+M2 land the mapper at 8-12 turns rather than 6, that is a MEASUREMENT to
bring to Brad with the transcript, not a target to adjust.

**MEASURED 2026-08-25 (EVAL-map-lane-latency-m1-drill).** The like-for-like batch came in at **4
turns / 115,898 raw**, against lf1 round 2's 22 / 643,565 on the same three slugs - the target
MET for the first time. The transcript is 3 tool calls against 21, and every class this section
names is absent: 0 extraction Reads, 0 DB Greps, 0 re-reads of mapped-pre, 0 environment-friction
turns, and the one food-DB read went to the SCRATCH file. The residual-heavy batch came in at 13
turns / 295,972 raw: raw inside target, turns twice over it, and the residue is label acquisition
for foods FDC does not carry. Both numbers and their decomposition are in the EVAL, and the
registrar's first N>1 measurement (12 turns / 123,401 on a batch of two) is a MISS reported there
with its own numbers.

## 5. M3 - a recipe with nothing to price stops going to the price lane

### 5.1 The measured defect

hunt-daemon.py:2099 reads:

```python
if not absent and hunt_lib.norm_state(res.get("state")) == "priced":
```

so a recipe whose `absent_terms` is EMPTY still routes to `pricing` unless the mapper also names its
own state "priced". On lf1 round 2 both fully-resolved recipes did exactly that: they advanced
`mapped` -> `pricing` carrying an EMPTY term list, enqueued nothing, and sat. The price lane had
nothing to answer for them and no wake could ever clear them. The drill only reached the write lane
because a SECOND daemon start ran `hunt-run -Derive` at seed time, which moved them to `priced`.

On an attended drill that is a restart. On an unattended run it is a park with no exit, and it is
invisible: the state file says `pricing`, which reads like a recipe legitimately waiting on a price.

### 5.2 The change

1. The branch condition becomes `if not absent:` - the mapper's `state` field stops gating it. Zero
   absent terms means the board answered every line; there is nothing for the price lane to do.
2. The unbid hold is UNTOUCHED and still returns before this branch (the `holds` block above it):
   nothing unbid reaches the writer, exactly as before. This changes only what happens to a recipe
   the pre-resolve and the mapper BOTH settled.
3. `optional_absent` terms, when `absent` is empty, are still enqueued through the existing
   `ingredient-queue -Add` call so the estate learns of them, and the recipe still advances. Optional
   never blocked and must not start blocking here.

   **CORRECTED 2026-08-25 (M3 build, read off hunt-daemon.py's map_lane at d754e610).** There was no
   existing `-Add` call for optional terms to be enqueued through. Today `optional_absent` is passed
   to `advance(... optional_terms=optional)`, which records it in the STATE FILE through hunt-run's
   `-OptionalTerms`, and nothing anywhere calls `ingredient-queue -Add` for an optional term - not in
   the pricing branch, not in the unhold road. So the fixture this section pins ("the optional term
   still reaches the queue") is NEW behaviour, and it was built as specced: the priced branch now
   enqueues each optional term with `-Why "<slug> lists it as optional"`. It does NOT wake the price
   lane and does NOT enter `self.absent_terms`, so optional still blocks nothing. The PRICING branch
   is untouched, because 5.3's clean twin pins it byte for byte.

4. Log the disagreement rather than swallowing it: when `absent` is empty and the mapper's state is
   NOT "priced", `self.log` one line naming the slug and the state it claimed. A contract the model
   keeps missing is worth seeing at width.

4b. **THE SIBLING SITE, NAMED AND DELIBERATELY LEFT.** The unhold road carries the identical
   condition at hunt-daemon.py:1355: `if not absent and rec.get("mapper_state") == "priced"`, with
   the same park-forever consequence for a recipe whose bid gets wired and whose mapper called its
   state anything but "priced". It was NOT changed, because it sits inside the unbid HOLD road and
   section 2 of this plan lists that road among the things M3 does not touch. It is a finding for
   Brad and it is recorded in the M3 fixture section's own header.

### 5.3 Fixtures

- MUST FIRE: a mapper result with `absent_terms: []` and `state: "mapped"` lands the recipe on the
  WRITE channel at state `priced`, and no `-Add` reaches the queue.
- MUST FIRE: ...and the disagreement is logged, naming the claimed state.
- CLEAN TWIN: `absent_terms: ["saffron", "harissa", "tteok"]` still routes to `pricing`, still
  enqueues all three, still wakes the price lane - byte for byte as today.
- CLEAN TWIN: a table with `holds` rows still HOLDS at `mapped` and never reaches either branch.
- MUST FIRE: `absent_terms: []` with `optional_absent: ["fresh dill"]` advances to `priced` AND the
  optional term still reaches the queue.
- NEUTER PROOF: restore the `and ... == "priced"` clause and watch the first case go red.

## 6. M4 - four prompt-only patches, no schema change

All in hunt-daemon.py's `map_prompt` unless stated. Keep every existing sentence; these are additions
and two replacements.

1. **Ban the direct FDC query.** Add, in the licensed-read paragraph: "The shelf IS fdc_lookup's own
   output, already fetched for this run. Do NOT query api.nal.usda.gov yourself and NEVER with
   DEMO_KEY - a demo key silently throttles and reads as 'FDC has no data for this food', which is
   the worst lie a nutrition lookup can tell. If the shelf has no candidate for a food, FDC was asked
   and lacks it: go to the open web."
2. **Cap the hunt.** "ONE fetch and ONE fallback per food. If two reads have not produced a printed
   label you can transcribe, return NO row for that food and say why in `detail` - a missing row is a
   finding a person can act on, and a fifth fetch is a turn that re-reads this whole session."
   Measured: round 2 spent 9 web calls on 2 foods.
3. **Name the scratch food DB on seamed runs.** New method `food_db_seam_note(self)` modelled exactly
   on `queue_seam_note` (hunt-daemon.py:349): returns "" when `self.food_db_path` is the live path,
   and otherwise "THIS IS A DRILL ON A SCRATCH FOOD DB at {path}. Verify against THAT file, not
   meal-prep\food-macros-db.json." Render it in map_prompt. Round 2 verified against the live DB
   while the drill was pointed elsewhere; on an unseamed run the note must be absent entirely and the
   prompt byte-identical to today.
4. **Say the precheck is complete.** Replace the current "VERIFY it, do not re-derive it" sentence
   with "VERIFY it, do not re-derive it. The precheck block above is rendered WHOLE - its tuning
   lines, its uncovered lines and its missing DB rows are all shown - so there is nothing to go and
   read in mapped-pre\<slug>.json."

Fixtures: one MUST FIRE per patch asserting the sentence is in the prompt; one CLEAN TWIN asserting
`food_db_seam_note` is empty and the prompt carries no drill sentence on an unseamed daemon. Neuter
proof: remove each sentence and watch its case go red.

**NOTED, NOT ORDERED.** `.claude\agents\recipe-ingredient-mapper.md` line 6 still grants `Edit` and
`Write`, though CHANGE M moved both of the mapper's pens to the daemon and map_prompt now says "no
file access to it". The tools are the last thing that could still put an unchecked row in the live DB.
Removing them is a gate decision and is Brad's to make, not this plan's - raise it, do not build it.

## 7. Build order, suites, and the drill

Order, one verified unit per commit, pushed as each lands:

1. **M1** (shelf render) - map-preresolve.ps1 + its -SelfTest.
2. **M3** (routing) - small, and it is what lets a drill reach the tail without a restart.
3. **M2** (map dossier) - the largest unit.
4. **M4** (prompt patches) - last, so its assertions run against the final prompt.

After every suite-touching unit: `C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py
--selftest` (baseline **192 ok**, growing), `hunt_lib.py --selftest` and `--parity` (**63/63** stays
or grows), `map-preresolve.ps1 -SelfTest`, and `ops\audit-prompt-backup.ps1 -Sync` if any agent
definition is touched. Estate mechanics: PS 5.1; Python is `C:\Codex\Python312\python.exe`, never
bare `python` (the Store shim exits 49 without running - it cost the lf1 mapper three turns);
ps_invoke / py_invoke only; no em dashes anywhere user-visible; exit 2 = blocked, never clean;
collection fixtures 3+ elements; CRLF preserved; git pull first; scoped adds only, never `git add -A`
- and commit in ONE step rather than staging and continuing, because the daily pipeline bot commits
the whole working tree around 07:00 and swept a staged unit into its own commit on 2026-08-25. Other
sessions write grocery\* and graph\* - normal noise, never chase it.

### 7.1 The drill

The corpus already exists and re-using it is the point - it is the only way these numbers compare.

1. `C:\tmp\lf1scan\run` holds 51 pre-resolved extractions. `C:\tmp\lf1\run2` holds the three
   pre-qualified slugs (baked-cauliflower-mac-smoked-sausage, philly-cheesesteak-stuffed-peppers,
   sheet-pan-smoked-sausage-broccoli-cheddar). Build a FRESH scratch root (`C:\tmp\m1`), seeded from
   the same three extractions at state `extracted`, with every seam engaged: --pool --ledger --specs
   --costed --food-db --queue --carriage --considered, SHORT root, **NO --publish**, never headless
   against stores, `--lanes map,write,qa`.
   - **Seed the state files with a `reject_reason` property present** (empty string is fine). The lf1
     drill's hand-written state files lacked it and `hunt-run -Advance` threw when the wave trimmed.
2. Run the SAME three slugs so the mapper's 22 turns / 643,565 raw / 368 s has a like-for-like twin.
   Then run a second batch from the lf1scan corpus (3 slugs with 5-8 residual lines each) so the
   round-1 acquisition shape is measured too.
3. Report `hunt-run.ps1 -LaneSummary` and `-StageSummary` verbatim beside the three baselines that
   now exist: 6b (PLAN-hunter-judge-contract section 1), jc1 (EVAL-latency-cold-read 1.1) and **lf1
   (EVAL-latency-lf1-drill sections 3-5)**. Report turns, raw, and sec/turn per changed lane against
   the standing targets: map <=6/300k per batch, registrar <=3/120k per batch, write <=4/250k, QA
   <=3/120k, audit <=10 full / <=4 scoped, recipe-local repair <=5/200k.
4. **Re-read the new mapper transcript the same way this plan was written** - count the tool calls by
   name and say what each one was for. A turn count without a decomposition is how the last drill
   left the diagnosis for somebody else.
5. Any target missed is reported WITH its measurement and is a conversation with Brad. Never a
   softened target, never a hidden number.

## 8. How this could backfire, named

- **A four-candidate shelf with five macros each bloats the prompt.** Bounded: ~140 characters per
  candidate, 4 candidates, only on rows with no food-DB row. lf1 round 2 had 4 such rows in a
  3-recipe batch. If a batch ever renders more than ~6k characters of shelf, report it rather than
  shipping blind.
- **A richer shelf tempts the mapper to transcribe a wrong-food row it can now fill in completely.**
  The shelf wording stays verbatim ("a shelf, not an answer... all of these can be the wrong food"),
  the Atwater gate and the provenance gate are untouched, and the drill reports how many rows were
  refused. If refusals rise, that is the conversation.
- **M2's food-DB rows could go stale mid-run** if another session writes the DB. It is a per-run
  cache, the same bet `commodity_rows` already makes, and the daemon is the only writer during a run.
- **M3 could advance a recipe the price lane should have seen.** It cannot advance one with an unbid
  line (the hold returns first) or one with a blocking term (`absent` non-empty). The only recipes it
  moves are ones where every line resolved AND the board answered.
- **M4's cap could stop a legitimate third read** for a genuinely obscure branded food. That is the
  trade: a missing row is a finding a person can act on, and 9 fetches for 2 foods is not.

## 9. What DONE means

All new fixtures green with neuter proofs RUN and recorded in their section comments; suites at or
above baseline (daemon 192+, parity 63/63, map-preresolve -SelfTest green); -Sync clean if any agent
definition was touched; the drill's -LaneSummary and -StageSummary reproduced verbatim beside all
three baselines; the new mapper transcript decomposed tool-call by tool-call; every target met or its
miss reported with the measurement; this file carrying CORRECTED blocks for whatever the build finds;
everything committed and pushed. Anything beyond this scope - removing the mapper's Edit/Write tools,
the F3-large tail collapse, head-noun shelf keying, pricer changes, the --specs seam not covering the
audit path (lf1 finding 4), the FDC-basis conflict class (lf1 finding 2) - is a proposal for Brad,
never a follow-on build.
