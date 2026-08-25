# PLAN: Finish the Judge Contract - map, write, audit stop exploring and start ruling

Date: 2026-08-25. Author: the 6b measurement session, from Brad's direction. Status: RATIFIED BY BRAD
for build; implement in the order given. This document amends PLAN-recipe-hunter-v3-2026-08-23.md
sections S4, S6 and S8; the implementing session fixes THAT document in the same commit as each code
change, marked CORRECTED with date, per the standing rule.

## 0. The verdict in one paragraph

Run hunt-2026-08-24-v3-phase6b burned 21.5M raw tokens to publish 2 recipes. Measured off
lane-log.jsonl's end-line stamps: context per turn is flat (25-60k) across every agent, so cost is
turns x ~50k, and the three expensive lanes are expensive because their agents still take 20-28
turns doing work the daemon could hand them or take back from them. The decider is the proof of the
alternative: 1 turn, 27k, 8 candidates ruled - because it receives a dossier and returns a schema'd
verdict. This plan applies that same contract to the mapper (turns are label hunts + food-DB edits),
the writer (turns are file I/O on the intake), and the auditor + repair agents (turns are re-deriving
arithmetic the battery already computed, and tree-walking repairs). No gate is weakened; no check is
removed; every reduction is "stop re-reading and re-deriving what the daemon already has."

## 1. The measured baseline (what the implementer compares against)

From meal-prep\runs\hunt-2026-08-24-v3-phase6b\lane-log.jsonl, end lines with api_turns:

| dispatch              | turns | raw tokens | ctx/turn |
|-----------------------|-------|-----------|----------|
| select decide:8x      | 1     | 27,379    | 27k      |
| map map:3x            | 22    | 1,084,231 | 49k      |
| write (one recipe)    | 23    | 1,169,531 | 51k      |
| audit wave-2:audit    | 28    | 1,006,166 | 36k      |
| audit wave-2:repair   | 20    | 1,223,492 | 61k      |
| qa repair             | 14    | 501,882   | 36k      |
| registrar (each)      | ~9    | ~94k      | 10k      |

Whole-run by stage (all 24 recipes): mapper 4.31M (20.0%), audit-lane repair writers 4.20M (19.6%),
writer 4.17M (19.4%), pricer 3.22M (15.0%), auditor 3.01M (14.0%), registrar 1.46M (6.8%),
QA repair 0.52M, source-qa 0.46M, decider 0.13M (0.6%), extract + all mechanical stages 0.

Repair writers across both lanes total 22.0% of the run - the single largest consumer - and one of
those repairs changed nothing at all (the daemon detected it and refused the re-audit; that guard
stays).

## 2. Scope - three changes, and what does not move

- CHANGE M (map): the mapper returns food-DB rows in its payload; the daemon writes the DB.
- CHANGE W (write): the writer returns its fillable fields in its payload; the daemon patches the
  intake. Locked-field drift becomes impossible by construction; the redrift re-ask class is deleted.
- CHANGE A (audit): the daemon renders the battery's already-computed arithmetic INTO the audit
  prompt; recipe-local repairs become field patches through the same intake-patch road; shared-data
  repairs keep the current full-agent road.
- Plus one instrument fix (section 7): mechanical lane-log end lines stamp -1 where the contract says 0.

NOT MOVING, restated so nobody relitigates: every gate and its threshold; the price lane singleton;
section 10 of PLAN v3; the registrar gate (and its new concurrency + collision re-check, commit
c36879cd); QA's one-repair rule; the auditor's authority and its TOOLS (it keeps Read/Grep/Bash etc.
for discretionary checks - what is removed is the OBLIGATION to fetch, never the right); the
"orchestrator checks mtimes before paying for a re-audit" guard; the mapper model pin (Opus, settled
37/37 - do NOT re-run the checkpoint); wave-publish.ps1 and everything downstream of GO.

## 3. CHANGE M - the mapper's pen moves to the daemon

### 3.1 What the turns are today

The map prompt (hunt-daemon.py, map_prompt, ~line 1556) already forbids re-reads: "The table above
is the estate, already read for you." Its one licensed read is "a nutrition LABEL for a food the
table marks as having no food-macros-db row", and it says "Add those rows as you always have" - i.e.
the mapper EDITS meal-prep\food-macros-db.json itself with the Edit tool. The 22 turns of map:3x are
label acquisition plus Edit/verify round-trips on that file. Note the FDC shelf (commit f8b22de3) is
ALREADY in the dossier: map-preresolve.ps1 lines ~500-514 attach FDC candidate rows per unresolved
term from meal-prep\db\fdc-cache.json (filled by meal-prep\pipeline\fdc_lookup.py). So candidates
arrive; the residual agent work is choosing/transcribing and the file edits.

### 3.2 The change

1. Extend hunt_lib.MAPPED (hunt_lib.py line ~736): inside each `results` item, ADD:

```
"food_db_rows": {"type": "array", "description":
    "Label-accurate food-macros-db rows for foods the table marks as having NO row. The "
    "ORCHESTRATOR writes the DB; you never edit it. Same shape as the DB's own entries.",
    "items": {"type": "object", "properties": {
        "item": {"type": "string"}, "brand": {"type": "string"},
        "serving_grams": {"type": "number"}, "serving_qty": {"type": "number"},
        "serving_unit": {"type": "string"}, "calories": {"type": "number"},
        "protein_g": {"type": "number"}, "carbs_g": {"type": "number"},
        "fat_g": {"type": "number"}, "notes": {"type": "string"},
        "source": {"type": "string", "description":
            "where the label came from: 'fdc:<fdcId>' when chosen off the shelf, else the URL"}},
        "required": ["item", "serving_grams", "calories", "protein_g", "carbs_g", "fat_g"]}}
```

   RETIRE `db_entries_added` (names-only array) from the schema in the same edit - it reported what
   the mapper claimed to have written; the daemon now knows exactly what it wrote.

2. New daemon method `write_food_db_rows(self, slug, rows)` in hunt-daemon.py, called from
   `assemble_mapped` (the daemon already holds the pen on mapped\<slug>.json there - this extends
   the same 6a decision to the second file the mapper used to touch). Behavior, in order per row:
   - Validate with fdc_lookup.atwater_check (it exists, ~line 187): calories vs 4/4/9 derivation
     within its tolerance. A failing row is NOT written; it becomes a finding naming the row and the
     recipe holds at `mapped` (the existing hold road) - a fabricated label is the worse-than-no-gate
     case.
   - CONFLICT RULE (from the meal-macro skill's standing rule: never overwrite the DB on a conflict
     without asking): if the `item` key already exists and any macro field differs, do NOT write,
     record a finding quoting both rows, and leave the existing row standing. The recipe proceeds on
     the existing row. If the key exists and fields match, silently skip.
   - Writes are serialized under an asyncio.Lock (map cap is 2 - two batches can land together).
     Model it on the existing cost-engine mutex (section 4.5 of PLAN v3; the selftest has
     `_cost_mutex` as the pattern). Read with encoding utf-8-sig, write compact like the daemon's
     other JSON writes in assemble_mapped. The DB is a DICT keyed by item name - preserve that shape.

     **CORRECTED 2026-08-25 (build session, measured on the live meal-prep\food-macros-db.json).**
     The DB is NOT a dict keyed by item name. It is `{"readme": "<string>", "items": [ ...row
     objects... ]}` - `items` is a LIST, and each row carries its own `item` field. Writing the shape
     this paragraph describes would have produced a DB that recipe-macros.ps1 and the meal-macro
     skill both read as empty, silently. `write_food_db_rows` refuses to write at all unless the file
     parses as `{readme, items:[...]}`, appends to that list, and a fixture asserts the shape
     survives the write. Two additions the paragraph did not call for, both built: `fiber_g` is in
     the row schema (atwater_check credits fibre at 2 kcal/g and without the field a legitimate
     high-fibre row fails the gate), and a row citing no `source` is refused outright per section 9's
     named backfire rather than merely noted.
3. map_prompt edits: replace "Add those rows as you always have" with: return them in
   `food_db_rows`; you no longer have (or need) file access to the DB; prefer an FDC shelf candidate
   when one matches (cite `fdc:<id>` in `source`); fetch an open-web label ONLY when the shelf has
   no match for that food, and cite the URL. State plainly: the orchestrator Atwater-checks every
   row and refuses conflicts, so give the label as printed, never a reconstruction.
4. Agent definition: .claude\agents\recipe-ingredient-mapper.md lines ~48 and ~73 say "You still
   write food-macros-db rows... it is still yours" - change to the return-contract wording. Then run
   `powershell -File ops\audit-prompt-backup.ps1 -Sync` and commit the sync, per the standing rule.

### 3.3 Fixtures (hunt_daemon_selftest.py, same suite section as the 6a assembler fixtures)

- MUST FIRE: a payload carrying `food_db_rows` results in the DAEMON writing the row; the file gains
  exactly that key; shape preserved (dict, not array).
- MUST FIRE: a row failing the Atwater check is NOT written and the finding names it.
- MUST FIRE: a row whose `item` exists with DIFFERENT macros is not written, both rows quoted in the
  finding, existing row untouched.
- CLEAN TWIN: an identical existing row is skipped silently, no finding.
- CONCURRENCY, with the neuter proof the standing rule requires: two concurrent assemble calls each
  carrying one new row -> both rows present. PROVE the fixture fails with the lock removed (comment
  the acquire in a copied function or monkeypatch the lock to a no-op) before counting it.
- 3+ elements in any collection fixture, per estate rule.

### 3.4 Target to measure (not a promise)

Mapper batch of 3-5: <=6 turns, <=300k raw. Compare against 22 turns / 1.08M.

## 4. CHANGE W - the writer returns fields; the daemon patches the intake

### 4.1 What the turns are today

write_prompt (~line 2305) says "COMPLETE its intake IN PLACE": the writer Reads
runs\...\extracted\<slug>.json, mapped\<slug>.json and intake\<slug>.json, then Edits the intake
field by field. The daemon then diffs against intake\<slug>.skeleton.json (verify_skeleton, called
~line 2209) and re-asks once on drift (redrift_prompt). 23 turns, 1.17M, and a whole re-ask class
policing what construction can simply prevent.

### 4.2 The change

1. Extend hunt_lib.WRITE (line ~853) with a `fields` object. The writable set is exactly
   Daemon.WRITER_FILLABLE (line ~2301): prose.intro_html, prose.shop_smart, prose.make_it,
   prose.portion_html, prose.cost_closing_html, prose.upsell_html, cuisine, head.description,
   head.keywords, head.steps, head.step_names, writer_notes, forbidden_prose_terms. Schema those
   loosely - heed the 6a lesson pinned in hunt_lib (~line 776): an over-constrained type caused a
   whole-session re-ask when the model was right and the schema wrong. head.steps and
   head.step_names are ARRAYS of strings; keys use the dotted names as literal JSON keys
   ("prose.intro_html": ...) so the payload is flat and the patcher owns the nesting.
2. New daemon method `apply_writer_fields(self, slug, fields)`:
   - Load intake\<slug>.json; for each key, split on the FIRST dot only and set into the nested
     dict, creating the prose/head sub-dicts if absent.
   - REFUSE (do not write anything) if `fields` contains any key outside WRITER_FILLABLE - that is
     an orchestrator-contract violation by the model; refusal routes through the existing dispatch
     re-ask machinery (validator), not a new mechanism: add a validator function
     `validate_writer_fields` in hunt_lib that returns problems for unknown keys, and pass it to the
     dispatch like validate_registrar is.
   - Write the file; keep the skeleton snapshot exactly as today.
3. verify_skeleton STAYS, but its meaning inverts: post-patch, a locked-field difference can only be
   an ORCHESTRATOR defect, so on failure the recipe is STUCK with the detail (never re-asked) and
   the finding says "the patcher touched a locked field - daemon bug". DELETE the redrift path: the
   redrift_prompt method, the r2 re-dispatch block in write_lane (~lines 2213-2228), and the
   "drifted twice" rejected-qa branch. The one-correction discipline is preserved where it still
   applies (QA); here the defect class is dead by construction.
4. write_prompt rewrite. The writer gets the CONTENT INLINE - no file reads at all:
   - the transcription's ingredients + instructions (from extracted\<slug>.json, which the daemon
     already parses),
   - the intake skeleton's locked view: name, servings, macros_per_serving, every ingredient line's
     buy string, times (the daemon has just built this file - render the relevant fields),
   - the fillable field list with one-line guidance each (keep the current voice rails verbatim: no
     em dashes, Brad's tone, 14 servings, compute NO number - numbers appear in prose only as the
     engine's own figures shown in the skeleton view),
   - "Return `fields` in your payload. You have no files to read or write. Your entire deliverable
     is the payload."
   The writer agent keeps its tools in the agent def (it serves repairs elsewhere) - the contract
   lives in the prompt + schema + patcher.
5. build-v2-spec, the cost pass, the band read: all unchanged - they run off the patched intake
   exactly as they ran off the edited one.

### 4.3 Fixtures

- MUST FIRE: a `fields` payload patches exactly those fields; every other skeleton byte identical
  (compare whole dicts minus the fillable paths).
- MUST FIRE: an unknown key in `fields` is refused by the validator (dispatch-level, so the model
  gets the re-ask with the key named), and the intake file is untouched.
- MUST FIRE: verify_skeleton failing post-patch marks the recipe STUCK - grep the outcome for
  status stuck, state None, and NO second writer dispatch (the FakeDispatch call count is the
  proof the redrift road is gone).
- CLEAN TWIN: dotted keys nest correctly - prose.intro_html lands under intake["prose"]["intro_html"],
  head.steps under intake["head"]["steps"], arrays surviving as arrays.
- 3+ fields in every patch fixture.

### 4.4 Target to measure

Writer per recipe: <=4 turns, <=250k raw (the prose itself is the payload and output tokens are the
irreducible part). Compare against 23 turns / 1.17M. Also: zero redrift dispatches by construction.

## 5. CHANGE A - the battery shows its arithmetic; repairs are patches

### 5.1 What the turns are today

wave-preaudit.ps1 already COMPUTES the chains - its per-slug checks carry numbers (macro-recompute:
recompute vs stat per macro; cost-engine-consistency: cost_batch/cost_batch_true/cost_first_run/
cost_per_serving/lines/lines_unpriced; protein-derivation: claimed vs derived vs tally; voice-sweep
hits; card-rebuild) plus 8 shared checks. But audit_prompt (~line 2709) only POINTS at the report
file. The 6b re-audit's own report says it "re-summed both engine rows by hand" and hand-recomputed
macros: 28 turns re-deriving what the battery had already derived, because pass/fail without shown
work is (rightly) not taken on faith. Repairs then get "read the audit file and repair EXACTLY what
it blocks on" plus tools: 20 turns at 61k/turn.

### 5.2 The change - audit dossier

1. New daemon method `render_audit_dossier(self, wk)`: read waves\wave-<wk>.preaudit.json and render
   a compact text block - per slug, each check's name, verdict, and its `numbers` dict as
   "key=value" pairs on one line; then the 8 shared checks' name + verdict + detail line. Cap the
   whole block at ~6,000 chars (it is numbers, not prose; the 6b battery output fits easily).
2. audit_prompt embeds that block inline, replacing only the pointer sentence. Keep, verbatim, the
   existing authority language ("It does not audit and it cannot issue a GO - you remain the
   authority and may re-derive anything in it") and ADD: "The arithmetic is shown so you can verify
   the CHAINS rather than rebuild them; spend your turns where a chain is absent, suspicious, or
   where external reality (a price that smells wrong, a claim no gate covers) needs eyes. That
   discretionary look is the half of your job no battery can do." The auditor's tools do not change.
3. The report file, GO/NO-GO first line, scope second line, ledger stamping, P1b freshness, the
   REPAIRCHECK mtime guard: all byte-for-byte unchanged.

### 5.3 The change - repair routing

The AUDIT schema already returns `blocker_kind` (recipe-local | shared-data) and `owner`. Route on it:

- `shared-data` -> the CURRENT road, unchanged (full agent, tools, repair_prompt as-is). A moved cost
  basis or a lib defect is genuinely not patch-shaped.
- `recipe-local` -> a new `repair_patch_prompt(wk, slug, findings)`: the agent receives the auditor's
  findings for that slug plus the intake's CURRENT fillable-field values inline, and returns the
  SAME `fields` payload shape as the writer (validated by the same validate_writer_fields). The
  daemon applies it through apply_writer_fields, re-runs build-v2-spec for that slug, and proceeds
  to the existing scoped re-audit. `no_change: true` with a reason is a legal return and feeds the
  existing changed-nothing guard (which stays: it just gets its answer from the payload AND the
  mtime check, belt and braces).
- QA repairs (qa_repair_prompt, ~line 2429): same split. A QA finding that names prose/fields ->
  patch road; a finding that requires re-extraction or re-mapping keeps its current owner routing.
  If the owner is extractor or mapper, nothing changes.

### 5.4 Fixtures

- MUST FIRE: the audit dispatch prompt CONTAINS the battery numbers (assert a known numbers key like
  cost_per_serving renders into the prompt string) - the dossier is not a pointer.
- MUST FIRE: blocker_kind recipe-local routes to the patch road (FakeDispatch sees repair_patch
  prompt, apply path invoked, build-v2-spec called for exactly the blocked slugs).
- MUST FIRE: blocker_kind shared-data routes to the UNCHANGED road (old repair_prompt text).
- MUST FIRE: a patch-road `no_change: true` still triggers the changed-nothing guard outcome (no
  re-audit paid).
- CLEAN TWIN: a missing/unknown blocker_kind defaults to the SHARED-DATA road - the conservative
  direction (whole-wave re-audit is the expensive-but-safe default, per the skill's scope rules).

### 5.5 Target to measure

Auditor dispatch: <=10 turns. Recipe-local repair: <=5 turns, <=200k. Compare against 28 and 20
turns. The auditor's DISCRETIONARY spot-checks are expected and welcome - the target is a median,
not a cap, and a NO-GO that spent 20 turns finding a real defect is a good spend.

## 6. Plan-document amendments (same commits as the code)

- S4 (PLAN v3 ~line 426): CORRECTED 2026-08-25 - the mapper returns `food_db_rows`; the daemon is
  the sole writer of food-macros-db.json, with the Atwater and conflict rules stated.
- S6 (~line 510): CORRECTED - the writer returns `fields`; the daemon patches the intake; the
  locked-field drift class and the redrift re-ask are deleted by construction.
- S8 (~line 571): CORRECTED - the battery's arithmetic is rendered into the audit dispatch;
  recipe-local repairs are field patches; shared-data repairs unchanged.
- Each CORRECTED block cites this file and the 6b measurements (section 1 table).

## 7. The instrument fix (small, do FIRST - it is what Thursday gets measured with)

Every mechanical end line in the 6b lane log stamps tokens -1 (cache_read=-1, api_turns=-1) where
the G-suite fixture asserts mechanical stages report 0 ("a mechanical stage burned nothing, which is
not the same as nobody having looked"). The fixture passes while production writes -1, so the
fixture is exercising a different code path than ps_timed/py-road mechanical stages take. Find the
divergence (start at ps_timed and the lane() end-line writer), make production stamp 0 on the
mechanical roads, and EXTEND the fixture to drive the road production actually takes - the neuter
proof is reverting the production change and watching the extended fixture fail. Also correct
audit-lane-shape.ps1's counted-not-judged lanes to count INVOCATIONS (start/end pairs), not raw
lines - it currently reports extract 18 where 9 invocations exist.

**CORRECTED 2026-08-25 (build session, measured on `meal-prep
uns\hunt-2026-08-24-v3-phase6b`).**
Three claims in the paragraphs above were wrong or short, and the fix is wider than they describe.

1. *"the fixture is exercising a different code path than ps_timed/py-road mechanical stages take"* -
   **it is not.** `_mechanical_lane_events` in hunt_daemon_selftest.py drives `ps_timed` directly and
   always did. The divergence is narrower and duller: the fixture asserted `-InputTokens` and
   `-OutputTokens` only, and `lane()` carries EIGHT token fields. Production passed 0 for the two
   that were asserted and defaulted the other six to -1. Measured end line, `by=mechanical`:
   `in=0 out=0 cache_read=-1 cache_creation=-1 calls=-1 api_turns=-1 all_in=-1 all_out=-1`. There
   was no second code path to find. FIXED by a single free road, `Daemon.lane_free_end`, used by
   `ps_timed`, `py_timed`, the local extraction ladder and the price pre-pass, plus a source-scan
   fixture in the `_one_marshalling_road` idiom asserting no other call site writes an end line.
2. *"the mechanical roads"* undercounts who was affected. The price pre-pass (`by=pre-pass`) stamped
   -1 in ALL EIGHT fields including `in`/`out`, and the local ladder (`by=local`) matched the
   mechanical shape. All three roads are on the free road now.
3. *"extract 18 where 9 invocations exist"* - the ratio is right, the numbers are from another
   snapshot. On 6b, BEFORE the fix: header `161 lane invocation(s)` over a log holding 72, and
   `extract 24, write 22, audit 14, qa 10, select 8` where 12, 11, 8, 5 and 4 invocations exist.
   AFTER: header 72, `extract 12, write 11, audit 8, qa 5, select 4`. The defect was also wider than
   "the counted-not-judged lanes": the headline total and the `-Json` `invocations` field counted
   raw lines too, and both are fixed through one predicate, `Get-InvocationCount`.

**One defect found in passing, fixed in the same commit.** `Get-Invocations` over `$null` returned
ONE invocation, because PS 5.1 delivers an empty array through an if-expression or a pipeline as
`$null` and `foreach ($l in @($null))` iterates once. That phantom invocation sat directly under the
`price-lane-unlogged` catch, which asks `-not $priceInv.Count` - the catch would have passed on
exactly the run it exists to fail. Guarded in `Get-Invocations` itself, with a MUST FIRE case. It
was the new zero-lane CLEAN TWIN that surfaced it.

**A third defect, found while fixing the first two, and FIXED 2026-08-25 on Brad's instruction.** A
LANE NAME IS NOT A STAGE. The map lane files three kinds of line under one name - `mapper` batches,
`registrar` gates, `mechanical` pre-resolve passes - and the price lane files two (`pricer`,
`pre-pass`), while the plan numbers behind `LANE_BATCH` are about ONE stage each: S4's micro-batch of
5 is five recipes to one MAPPER, and 2.4's batch of 10 is ten terms to one PRICER. Shaping the whole
lane measured a mixed population. On 6b that fired `map-lane-duplicate-items` over 9 slugs, every one
of which had simply taken a pre-resolve, a mapper and a registrar; not one was real. Same class as
the 2026-08-24 pairing fix, one level up: counting things that are not the thing.

`Select-JudgeInvocations` narrows each shape-judged lane to its own judgment stage via a new
`LANE_JUDGE` table, and the printed line now names whose invocations it judged. A line carrying no
`by` is kept, and a lane where NOTHING carries a `by` is treated as a historical log and judged
whole - filtering there would report a real run as having made no invocations, which is the vacuity
failure this script already refuses elsewhere.

Measured on 6b, before and after: map read as 22 invocations with 9 duplicate slugs and now reads as
5 mapper invocations with none; price read as 10 invocations with 12 duplicate terms and now reads as
5 pricer invocations with ONE - `golden beets`, which really did go to the pricer twice and is the
kind of finding this script exists for. Whole-run findings 4 to 3. Leaving nine false findings
standing is how a gate gets turned off.

## 8. Build order, gates, and the drill

Order: 7 (instrument) -> M -> W -> A. One verified unit per commit; commit and push as each lands.

After each change: `C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py --selftest`
(baseline 142 ok, growing), `hunt_lib.py --selftest` and `--parity` (63/63), and for agent-def
edits `ops\audit-prompt-backup.ps1 -Sync`.

End-to-end drill BEFORE declaring done: a 2-3 recipe scratch run using the drill seams
(--pool scratch copy, --ledger/--specs/--costed scratch, SHORT root like C:\tmp\jc1, NO --publish,
never headless against stores) driving all three changed lanes, then hunt-run.ps1 -LaneSummary on
it. Report the turns/tokens per changed lane against the targets in 3.4 / 4.4 / 5.5 and against the
section 1 baseline. The drill's food-DB writes go to a SCRATCH copy - add a --food-db seam if none
exists (same pattern as --costed), because the live DB must not take drill rows.

Estate mechanics, restated: PS 5.1; Python is C:\Codex\Python312\python.exe, never bare python;
ps_invoke/py_invoke are the only marshalling roads (the _one_marshalling_road fixture greps for
violations and caught the last session's inline powershell - put new invocation styles in hunt_lib
beside ps_invoke); no em dashes anywhere user-visible; exit 2 = blocked, never clean; fixtures over
collections use 3+ elements; a multi-edit patch that fails partway means re-verifying EVERY edit it
carried; git pull first; scoped adds only, never git add -A.

## 9. How this could backfire, named

- The mapper stops transcribing carefully because "the daemon checks it": the Atwater gate catches
  arithmetic fabrication but not a wrong-but-consistent label. Mitigation: `source` is required in
  spirit - a row with neither fdc id nor URL is a finding (add that to write_food_db_rows).
- The writer's inline dossier bloats the prompt past what Edit-roundtrips cost: bounded - the
  transcription + skeleton view is ~10-20k chars; 23 turns at 51k each was 1.17M. Measure in the
  drill; if the dossier exceeds ~30k chars for a normal recipe, report it, do not ship blind.
- The audit dossier tempts the auditor to rubber-stamp: the authority language stays, the
  discretionary mandate is explicit, and the NO-GO rate across the next runs is the check - report
  it. If the auditor stops finding anything the battery missed for several waves, that is a
  conversation with Brad, not proof of health.
- A patch-road repair cannot fix what it cannot touch (a bad grams_source, a mapping error):
  blocker_kind routing covers it - those are shared-data or owner=mapper findings and take the old
  roads. The CLEAN TWIN fixture (unknown kind -> shared-data road) is the backstop.

## 10. What DONE means

All fixtures green with neuter proofs recorded in their comments; parity 63/63; -Sync clean; the
drill's -LaneSummary shows every changed lane at or under target (or the miss reported with the
measurement, not hidden); PLAN v3 S4/S6/S8 carry CORRECTED blocks; this file's section 1 baseline
reproduced in the final report next to the drill numbers; everything committed and pushed. Anything
beyond this scope - C4, C6, effort tuning, new lanes - is a proposal for Brad, not a follow-on build.
