# EVAL: where the Recipe Hunter re-buys work it already paid for (2026-09-04)

Measured on `meal-prep\runs\hunt-2026-08-27-highprotein` (lane-log.jsonl token stamps plus the 238
headless transcripts under the project dir dated 08-27..08-29), cross-checked against
`hunt-2026-08-27-ten`. Scope: same agents, same roles, same lane model. Only the places where a stage
re-reads or re-derives something the daemon already holds, or is paid twice for one job.

## The run in one table

154.0M input-side tokens (in + cache_read + cache_creation), 3.1M output. 22 slugs published in 6
publishes; 33 recipes reached the write lane; 17 daemon starts.

| lane    | tokens | share | calls | turns | what the money is |
|---------|-------:|------:|------:|------:|---|
| audit   | 64.9M  | 42.2% | 24    | 615   | 15 auditor calls at 3.8M / 35 turns each, plus 9 repair calls |
| qa      | 31.9M  | 20.7% | 58    | 376   | 4 MAPPER-owned repairs = 25.5M (80% of the lane); source-qa itself ~6M |
| price   | 23.5M  | 15.3% | 30    | 379   | 62 terms, 2.1 terms per call against a cap of 10 |
| map     | 15.2M  |  9.8% | 33    | 368   | 16 mapper calls (2.4 recipes per call against a cap of 5), 17 registrar |
| write   | 11.7M  |  7.6% | 95    | 167   | 95 writer calls for 33 recipes; 9.3M is repeat calls |
| review  |  5.6M  |  3.6% | 1     | 22    | one post-publish review |
| select  |  1.2M  |  0.8% | 13    | 13    | one turn per call - the shape everything else should have |
| extract |  0.1M  |  0.1% | 1     | 3     | the local ladder settled 25 of 26 pages |

The ten-run has the same top three: mapper-owned repair 23%, audit 22%, price 21%.

## Findings, largest first

### 1. Audits are paid per WAVE, and the same recipes were audited up to eight times
- 50 slug-audits across 15 auditor calls; 36 of the 50 were a slug already audited in an earlier wave.
  butter-chicken-pasta was audited 8 times, ground-beef-cottage-cheese-bowl and chicken-rice-and-broccoli
  7 times each. Publish refusals (wave-4.publish-refusal.txt) and NO-GO churn re-waved the same slugs.
- Cost is fixed per audit, not per slug: a 1-slug wave cost 5.9M (wave 2) and 3.5M (wave 11); the 6-slug
  waves cost 3.3M to 4.4M. Small waves buy the whole overhead for one recipe.
- Inside one audit (wave 8, 9.4M, 92 turns): turns 1-2 Read `wave-8.preaudit.json` and `wave-8.json`,
  both already rendered in the prompt; turns 3-6 Glob and Grep to FIND the spec files (the prompt names
  the run dir and wave file, never `db\recipes`); then every spec is Read, `update-recipes-db.ps1` is
  Read and re-run `-DryRun` (the battery's `recipes-db-dryrun` check had already run it), and
  `recipes-db.json` and `food-macros-db.json` are parsed in PowerShell three times each to recompute
  macros the battery had already computed. `update-recipes-db.ps1` was Read in 7 of the 15 sessions.
- `AUDIT_DOSSIER_CAP = 6000` chars truncates every 6-slug wave (waves 4, 5, 9 rendered 7.3-7.6k chars),
  ending with "read the report file" - so the auditor reads the file it was meant not to need.

### 2. A mapper-owned QA repair has no dossier and no contract, so the mapper re-learns the pipeline
`qa_repair_prompt` hands the mapper the findings and a file pointer; the writer's road (`qa_repair_by_patch`)
hands it the fields inline and takes 1-2 turns at ~80k. The four mapper repairs cost 25.5M (6.4M each,
50 turns). The 14.4M honey-bbq session: Read `build-intake-skeleton.ps1` three times, `spec-guards.ps1`
twice, `coverage_check.py` twice, grepped `hunt-daemon.py` six times to learn how the mapper stamp works,
ran git log/status, wrote its own fix script, rebuilt the spec by hand. 84 tool calls for one recipe. The
map lane already has the machinery to avoid all of it: a one-slug `map_prompt` with the QA findings on top,
the same `lines`/`rulings` return, and the daemon re-assembling `mapped\<slug>.json`.

### 3. The write lane re-pays the writer on every daemon restart for a recipe it cannot fix
`write_lane` keeps an intake that already carries current prose ("keeping the intake it already has")
and then dispatches the writer anyway; `build-v2-spec` then refuses on `UNKNOWN INGREDIENT NAME: Cotija
Cheese; Lime Zest` and the recipe is STUCK. The next restart repeats it byte for byte. street-corn,
no-boil-casserole and alfredo-lasagna each got 15 writer calls and 12 identical refusals; 62 of the 95
writer calls (9.3M of 11.7M) were repeats. The refusal is a vocabulary/mapping question no writer pass can
answer.

### 4. The price lane drains 2 terms at a time, and the pricer re-runs the pre-pass
- `price_lane` wakes on every mapper micro-batch and drains immediately (by design: a wait-for-full-batch
  deadlocked against WIP). But the extract lane already solved the same problem for map with a
  producer-side hold and three flush conditions (batch full / nothing queued behind / draining). The price
  lane has no equivalent, so 62 terms took 30 calls (2.1 per call) instead of ~7-10. Each call carries the
  23KB agent body, the prompt and the evidence, and 12.6 turns on average.
- Inside a call: `probe-ingredient.ps1` was re-run 46 times across the 30 sessions for stores the pre-pass
  had already probed and inlined; one session re-ran the same probe seven times fighting `-Json` output;
  and `commodities.json` is parsed 3-4 times per session to find the bid `-Promote` needs. The daemon
  knows that bid from the mapper's rulings and does not put it in the prompt.

### 5. A schema re-ask is a COLD session with the prior answer cut at 4,000 chars
`hunt_dispatch.dispatch` re-asks by starting a fresh `claude -p` with the original prompt plus
`res.text[:4000]`. 14 re-ask sessions cost 4.0M and made 37 web calls: a mapper answer runs far past
4,000 chars, so the re-ask re-fetches every label it had already read. The envelope carries `session_id`
and the CLI supports `--resume`; the re-ask should continue the warm session.

### 6. The QA dossier renders "the 0 ingredient lines"
`qa_dossier` reads `spec.get("ingredients")`; v2 specs carry `ingredients_display`, `ingredients_grams`
and `head.recipeIngredient` (checked on street-corn: 20 lines under those keys, none under `ingredients`).
Every one of the 34 QA sessions therefore Greps the spec 5-8 times and Reads it, and 3 re-ran the battery
the daemon had already run. Small in tokens (~7M lane), but it is the dossier's central section, empty.

### 7. The registrar re-sweeps the four files its dossier was built from
`commodities.json` was Read whole in 12 of 17 registrar sessions (and re-read within a session 5 times);
greps of smp-feed 23, commodities 22, recipe-board 10, recipe-commodities 9. The agent definition tells it
to distrust the empty result and keep sweeping, and GREP_HARNESS_NOTE rides on every prompt. 2.7M total.

### 8. Minor
- The mapper Reads all five `extracted\<slug>.json` files on turn 1 because the prompt names the path
  "if you need a line's full context". Either inline the transcription lines or drop the pointer.
- The post-publish reviewer gets no dossier at all and parsed `recipes-db.json` 7 times and the triage
  queue 6 times in one 5.6M session. By design independent; noted, not counted.

## What would close each, inside the existing design
1. Audit: raise `AUDIT_DOSSIER_CAP`; inline spec paths, the card dir, and the wave's mapped rulings +
   food-DB rows (the daemon already renders both for the mapper); state which battery checks already ran
   scripts (`recipes-db-dryrun`, P8) so they are not re-run. The wave-repeat cost is a policy question:
   a refused publish re-buys a whole audit today.
2. Mapper repair road: one-slug `map_prompt` + QA findings, same return contract, daemon reassembles.
3. Write lane: skip the writer when `intake_is_current` and the prose fields are present; do not re-enter
   a STUCK recipe whose mapped-file hash is unchanged since an identical refusal.
4. Price lane: producer-side hold mirroring `extract_lane`'s three conditions; put term -> bid in the
   prompt; say the server-tier probe is done and inlined.
5. Re-ask via `--resume <session_id>`.
6. `qa_dossier`: read the v2 keys.
7. Registrar prompt: the dossier IS the sweep of those four files; greps are for spellings it did not cover.
