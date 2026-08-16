# PLAN: Recipe Hunter v2.1 - Serveability, Audit Economics, and the Proving Run

Date: 2026-08-15. Author: Fable, same-day retrospective of the v2 shakedown run. Implementer: a new session.
Status: APPROVED direction by Brad ("write an implementation plan I can hand a new session").
Prereq reading: design\PLAN-recipe-hunter-v2-2026-08-15.md (the v2 build), then
meal-prep\runs\hunt-2026-08-15-shakedown\report.md (what the shakedown found), then this file.

## 0. Context: what v2 proved and where it is blind

The 2026-08-15 shakedown carried 2 recipes end to end. Every internal gate worked: the batch auditor
returned NO-GO twice and caught 5 real blockers, the cost-basis gate stopped a half-price publish, and
wave-publish's preflight refused correctly in every drill. **No false number ever reached a reader.**

What DID reach readers: both pages went live with an EMPTY cost section and the literal text "current
release price loading" twice per page, because recipe cards fetch prices from
`www.thriftycrew.com/api/v2/recipe-feed/<slug>` (pipeline\tpl2-scaler-prefix.html line 152), served by
the V3 platform deleted 2026-08-14. That endpoint answers 200 for slugs that existed at its last stored
release and 404 for anything new. Both recipes are now DRAFTS in Ghost waiting on the fix.

The structural lesson: **every v2 gate validates data against other data (spec vs costed, spec vs
recipes-db, prose vs stat). Not one stage asks whether the published page will actually work for a
reader.** Both real-world failures this run (a hijacked board cell, a dead serving endpoint) were
external, and the second was discoverable with one HTTP request before publish. v2.1 adds that missing
category of check, fixes the audit economics, and schedules the run that proves the concurrency claims.

## 1. Coordination: work already in flight (do not redo, do not collide)

- **task_7a2c86fe "Repoint recipe cards from the dead V3 feed to smp-feed" has LANDED** (verified
  2026-08-15 ~16:00: tpl2-scaler-prefix.html line 159 reads `SMPFEED='https://feed.thriftycrew.com/smp-feed.json'`,
  all 544 cards republished, both shakedown pages live and pricing, no placeholder text, feed carries
  both new slugs). Improvement A stays endpoint-agnostic (parse the URL out of the template, never
  hardcode either endpoint) so the gate survives any future repoint. Build and test against the
  smp-feed endpoint.
- Already DONE this session, do not redo: writer + mapper agent prompts hardened (trace claims to cost
  lines; macro cross-check), scoped re-audit rule written into the skill, calorie floor removed from
  build-v2-spec (product decision, protein floor stays), wave-publish git handling and foreign-dirty
  counting fixed, ledger marshalling frozen as a must-fire fixture.
- Other open tasks that may touch shared files: fresh-spinach commodity rules, orphan Red Wine row,
  feed-freshness rule, board hijacks. None conflict with this plan's files except export-feed.ps1
  (owned by the repoint task; improvement A only READS its output).

## 2. Improvement A: THE SERVEABILITY GATE (highest value, build first)

**Principle: a wave may not publish unless every surface a NEW recipe depends on will actually resolve
for a new slug, and may not stay published unless it verifiably did.** Two halves, because the price
feed is regenerated FROM recipes-db and new slugs only enter recipes-db mid-publish (step E3), so full
verification is only possible after the publish - which means the gate needs a rollback arm.

### A1. Preflight (new P8 in wave-publish.ps1, after the dedup escape guard)

1. **Endpoint provenance.** Parse the price-fetch URL out of pipeline\tpl2-scaler-prefix.html (the
   `SMPFEED=` line - it is the single source of truth baked into every card). REFUSE if that URL's
   host+path is not one this estate produces. Concretely: maintain a small allowlist in the script of
   producible endpoints (today: the smp-feed URL that grocery\export-feed.ps1 writes to public\ and its
   feed.thriftycrew.com alias). The dead V3 `/api/v2/recipe-feed/` path must NOT be on the allowlist,
   so this check alone would have refused today's publish with zero HTTP calls. When the repoint task
   changes the template, the allowlist already contains the new URL.
2. **Liveness probe.** Fetch the endpoint for one KNOWN-LIVE slug (pick the first slug alphabetically
   from recipes-db that is not in this wave). Require HTTP 200 and parseable JSON. This proves the
   serving path is up before we commit to it. A non-200 or unparseable body = refuse; could-not-look is
   never a clean bill (same rule as P6).

### A2. Post-publish verification with rollback (new E7 in wave-publish.ps1, after git push)

1. Re-run grocery\export-feed.ps1 so the feed picks up the recipes-db rows E3 just wrote. (After the
   repoint this is what makes new slugs serveable at all. It also closes the gap the reviewer found
   where smp-feed's recipes map was 2 slugs short because it was generated minutes before the rows
   landed.) Commit+push the regenerated public\ feed files as part of the wave's scoped path list.
2. Fetch the card's actual price source ONCE (the URL parsed in A1 - smp-feed is a single whole-feed
   document, not a per-slug endpoint, so there is nothing to substitute) and require 200 + JSON; then
   for EACH wave slug require its key present in the feed's `recipes` map. Then fetch each live page,
   cache-busted, and require: HTTP 200, and the page does NOT contain any hydration placeholder text.
   The placeholder strings to scan for live in the template; extract them at build time rather than
   hardcoding (today: "current release price loading").
3. **On ANY failure: roll the failing slugs back to draft automatically** via the Ghost Admin API
   (lib\ghost-lib.ps1, the same id+updated_at PUT the manual remediation used on 2026-08-15), advance
   their hunt-run state to `held` (see A3), stamp the ledger
   (`-Stamp -Stage publish -Detail 'ROLLED BACK: <slugs> - serveability failed'`), and exit 1. A page
   that cannot price is drafted in seconds instead of waiting an hour for the post-publish reviewer to
   find it. Slugs that passed stay live; the rollback is per-slug, not per-wave.

### A3. New state: `held`

hunt-run.ps1 state graph gains `held`: legal transitions `published -> held` (serveability rollback or
any deliberate takedown) and `held -> published` (the flip back once the dependency is fixed). Terminal
states unchanged. Self-test gains: MUST FIRE `published -> held -> published` legal both ways; MUST FIRE
`held -> verified` refused (it must go back through published). NO backfill needed: the repoint landed
and both shakedown recipes are live again, so their state files (`published`) and Ghost now AGREE -
verify that with two page fetches, then leave them alone. `held` ships for future takedowns only.

### A4. Fixtures (guard-fixture rule, non-negotiable)

**Implementation constraint that is easy to get wrong: provenance must PARSE the `SMPFEED='...'`
assignment, never grep the template for a path.** The live, correct template still contains the literal
strings `/api/v2/recipe-feed/` (line 150) and "current release price loading" (line 154) inside
COMMENTS documenting the founding bug. A grep-based gate would refuse today's correct template because
of its own history lesson - the guard-re-parses-prose trap, with the prose being a comment about the
very bug the guard exists to catch. Same rule for the placeholder check: the placeholder strings are
extracted from the template's placeholder MARKUP (or, if the markup no longer carries any, a frozen
list in the script), never by scanning comments.

wave-publish -SelfTest gains, all as pure predicates plus one parse test against a frozen template
snippet: MUST FIRE a template whose `SMPFEED=` assignment points at `/api/v2/recipe-feed/` (the frozen
founding bug) is refused by the allowlist; CLEAN TWIN the smp-feed URL passes; **CLEAN TWIN a template
whose `SMPFEED=` is correct but whose COMMENTS mention the dead path still passes** (freeze a snippet of
the real post-repoint template for this); MUST FIRE a feed payload missing a wave slug's key fails the
per-slug check; MUST FIRE a page body containing the placeholder string fails; CLEAN TWIN a clean body
passes. The placeholder-extraction gets its own fixture so a template rewrite that renames the
placeholder cannot silently disarm the check.

## 3. Improvement B: AUDIT ECONOMICS

The shakedown spent 31% of its tokens on three whole-wave audits; the third round re-verified a wave in
which one prose field of one spec had changed. Two mechanical changes and one policy change:

### B1. Audit freshness gate (new P1b in wave-publish.ps1)

Refuse when the audit file's LastWriteTime is older than the newest LastWriteTime of any wave slug's
spec in db\recipes. A GO that predates a spec edit is a GO for bytes that no longer exist - today
nothing catches that, and it is the exact reanchor-pair-or-corrupt shape applied to the audit itself.
Fixture: MUST FIRE audit older than a spec edit refuses; CLEAN TWIN audit newer passes. (Implementation
note: compare file mtimes, not content; the spec hash already changes for legitimate machine re-anchors,
and the point is "the auditor saw the current bytes", which mtime ordering captures honestly.)

### B2. Scoped re-audit, enforced by the dispatch

The skill already states the rule (recipe-local blockers re-audit only the repaired slugs; shared-data
blockers re-audit the whole wave). Make it structural: the orchestrator's re-audit dispatch MUST name
`scope: <slugs>` or `scope: whole-wave` with one sentence saying which kind of blocker was fixed, and
the auditor's report must echo the scope on its second line so wave-publish's P1 parse can log it.
No code gate can decide the scope (that judgment is the orchestrator's), but forcing the declaration
makes an unscoped full re-run a visible choice instead of a default.

### B3. Wave-size policy for the audit unit

hunt-run -WaveClose already refuses a short wave without -Drain. Add one refinement: `-Drain` with
fewer than 3 qa-passed recipes prints a warning naming the per-recipe audit overhead ("a 1-recipe wave
pays the whole-wave audit alone; hold for the next run unless these recipes are time-sensitive") but
still proceeds, because drain means drain. The default wave size stays 10. No other change; the
economics fix is mostly B1+B2 plus the already-landed skill text.

## 4. Improvement C: COLLATERAL ACCOUNTING (decide propagate's role, then stop relitigating it)

DECISION RECORDED: **do not fork or scope propagate.** It is THE one command that makes the site match
the specs, its whole-dirty behaviour is correct (the 359-recipe carry shipped a real fix), and a
wave-scoped variant would be a second copy of the rule. Instead, make the collateral honest in the
record:

1. wave-publish already computes `$dirtyTotal` from propagate's header line. Carry it into the ledger:
   the publish stamp detail becomes `"<n>/<n> wave slugs ok + <m> collateral specs carried by propagate"`.
2. The run report template (see the shakedown's report.md) keeps its Collateral section; the skill gains
   one line telling the orchestrator to dispatch the post-publish reviewer with BOTH numbers so it
   samples the collateral, as the 2026-08-15 reviewer correctly did.

## 5. Improvement D: THE PROVING RUN (schedule after A and B land)

The shakedown validated the gates, not the throughput. The streaming concurrency and the singleton
pricer lane have still never run in anger (the board answered every shakedown ingredient from disk).
Before trusting any throughput or cost claim:

1. Run the skill for real at Brad's direction: ~20 recipes, wave size 10, with conditions chosen to
   FORCE the pricer lane - include at least one cuisine slice whose signature ingredients are plausibly
   absent from the board (the sourcer's unmapped-ingredient flags identify these candidates; pick a few
   INSTEAD of avoiding them, the opposite of the shakedown's selection bias).
2. Instrument: record per-stage subagent token totals in the run dir (the orchestrator sees them in
   every Agent result; append to runs\<id>\usage.jsonl as they arrive). Target from the retrospective:
   200-250k tokens per recipe at wave size 10, against the shakedown's 786k.
   **LANDED 2026-08-15, and it is the substrate for both this and 5.3 below:** `hunt-run.ps1 -Lane` writes
   append-only `runs\<id>\lane-log.jsonl`, one line per agent invocation `{at, lane, label, count, items}`.
   usage.jsonl is now a per-line join onto that log rather than a second reconstruction of the same events,
   and neither has to be recovered by re-reading workflow transcripts.
3. Specifically verify during the run: (a) the pricer lane stays a singleton and its per-store tabs
   behave per its definition; (b) hunt-run -Derive moves recipes parked/priced correctly off REAL queue
   verdicts, not just the self-test fixtures; (c) a mid-run resume via -Status after killing the session.
   (a) is now mechanical: `pipeline\audit-lane-shape.ps1 -RunDir <p>` reads the lane log and reports
   pricer invocations against ceil(distinct terms / 10) and mapper invocations against ceil(recipes / 5).

### D-bis. THE LANE SHAPE GATE (landed 2026-08-15, ahead of the proving run)

Founding bug: a session built the hunt orchestration from SKILL.md alone instead of v2 section 2.4 and made
pricing a per-recipe pipeline stage. The PRICE lane is a singleton queue drainer batching up to 10 terms
ACROSS recipes (ingredient-queue.ps1 is keyed by TERM), so per-recipe pricing discards the cross-recipe
dedup and opens 7 store sessions per recipe instead of per 10-term batch - the sweep shape that walled
Walmart at 55 of 526. SKILL.md was corrected the same day, but no gate would have caught the run, and a
correction with no mechanical check behind it is documentation.

`audit-lane-shape.ps1` reports the shape the run actually used and exits 1 on:
- `<lane>-lane-not-batched`: invocations exceed ceil(distinct items / batch size) AND the mean items per
  invocation is under half the batch size. Both clauses matter - a streamed drainer legitimately runs many
  times, so only under-filled batches convict. Small-n noise (under 3 invocations) never fires.
- `<lane>-lane-duplicate-items`: a term went to the pricer in two invocations, i.e. the queue's term-level
  dedup was discarded. No threshold needed; this one is direct evidence.
- `price-lane-per-recipe`: every attributable invocation stayed inside one recipe across 3+ recipes. Two
  recipes is reported as suspect and NOT ruled on, because two can arrive far enough apart to drain
  separately - never convict on evidence with an innocent reading.
- `price-lane-unlogged`: the run priced and recorded no invocation at all. This is what stops the check
  being opt-in; an orchestrator that ignores `-Lane` fails rather than passes.

Fixtures shipped in the same commit per section 8: 8 invocations for 9 terms MUST FIRE, 1 invocation for the
same 9 terms is the clean twin; the same pair at the mapper's size of 5; four FULL 10-term batches and four
half-full ones are clean twins that prove the gate does not fire on a correct streamed drainer; and an
end-to-end pair over real temp run dirs, because a pure predicate cannot catch a mis-parsed file.
4. Success criteria, written before the run starts: 2 waves published with zero rolled-back slugs,
   pricer verdicts recorded with evidence for every absent term, per-recipe token cost measured, and
   any new defect class frozen as a fixture the same day.

## 6. Also in scope for the new session (small, do while in the files)

- **Reconcile the shakedown run**: DONE by the repoint task - both recipes are live and pricing, state
  files already read `published` and now match Ghost. Remaining: verify both pages once with the A2
  per-slug check when it exists, then hunt-run -Advance both to verified (the ledger batch is closed
  and stays closed).
- **wave-publish step renumbering**: adding P1b/P8/E7 shifts labels; keep the printed labels sequential
  and update the dry-run listing to match (the labels are load-bearing for humans reading transcripts,
  nothing parses them except the humans).
- **SKILL.md**: add the serveability gate and the held state to the pipeline description and the
  "stage notes" section; add the B2 scope-declaration requirement to the wave-gate section.
- **Memory**: update the recipe-hunter-v2 memory (auto-memory dir) noting v2.1 landed and what remains.

## 7. Explicitly out of scope

- The repoint itself (task_7a2c86fe - LANDED, see section 1). Nothing left to wait on. The standing
  rule survives it: if the serveability gate ever refuses every publish because a template points
  somewhere this estate does not produce, that refusal is CORRECT - do not weaken the gate to unblock;
  say so in your report.
- Reviving anything from the deleted V3 platform. Decision made 2026-08-15, recorded in the shakedown
  report and the triage queue item 2026-08-15-d933eb.
- propagate changes beyond the stamp detail (section 4 decision).
- Any board/commodity work (spinach, shallots, hijacks - all have their own tasks or standing rulings).

## 8. Build order and acceptance

1. A3 (held state + reconcile) -> hunt-run self-test green including the two new fixtures.
2. A1 + A4 preflight -> wave-publish self-test green; drill: point the parser at the frozen
   dead-endpoint template snippet (the A4 must-fire fixture) and confirm a -DryRun against a scratch
   wave REFUSES at P8 naming the provenance rule; then against the real template it must pass P8.
3. B1 freshness gate + fixture; B3 warning; C stamp detail. Self-tests green.
4. A2 rollback arm. Live drill for the rollback needs care: use a scratch Ghost draft (create a
   throwaway draft post via the API, run the per-slug page check against its preview state, prove the
   rollback PUT works, delete it). Never drill against a live recipe page.
5. SKILL.md + memory updates. Commit and push per estate rules (scoped adds, never -A; push immediately).
6. D is a separate session/run, dispatched by Brad when A-C are green and the repoint has landed.

Every new gate ships its must-fire fixture and clean twin in the same commit as the gate. A gate whose
founding bug is not frozen next to it will drift back into the estate's dead-guard pile, and this run
already paid the tuition on that lesson three times.
