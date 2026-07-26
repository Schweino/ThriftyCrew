# Recipe expansion run playbook (model-routed, zero /model flips)

Brad's requirement (2026-07-25): he should never have to remember to flip models mid-run. The routing
lives in the AGENT definitions (C:\Codex\.claude\agents\), each pinned to its model. Whatever model the
main session is on, the orchestrator dispatches stages to these agents and each runs on its own brain.

No seafood recipes: seafood is expensive per serving and nobody has asked (Brad, 2026-07-25).

## Stage routing

| Stage | Who runs it | Model | Why |
|---|---|---|---|
| 1. Source candidates from the internet (fan out N slices by cuisine/protein/method) | **recipe-sourcer** (parallel) | **opus** | breadth research; returns structured candidates + source URLs; selector culls |
| 2. DEDUP + select final batch to protein targets | **recipe-dedup-selector** | **opus 4.8** | judges the DISH not the name, vs catalog AND pool; Brad's rule: no duplicates or darn-near |
| 2.5 Normalize ingredients -> canonical worklist | scripts + main session | any | mechanical (normalize-recipe-ids.ps1 is idempotent) |
| 3. NEW ingredient mapping + food-DB entries | **recipe-ingredient-mapper** | **fable** | accuracy-critical; evidence-gate judgment; label transcription |
| 4. Scale to 14 servings, macros, 550 gate, pricing | scripts (r100 pipeline) | any | the gates do the checking |
| 5. Prose + card assembly (fan out slices) | **recipe-writer** (N in parallel) | **opus** | volume; numbers are transcribed, never computed |
| 6. Pre-publish batch audit | **recipe-batch-auditor** | **fable** | adversarial full-batch review; GO / NO-GO |
| 7. Publish + verify live + push + memory | main session | any | scripted, verified |
| 8. POST-publish independent review | **post-publish-reviewer** | **fable** | trusts artifacts not summaries; fixes via gates or files needs-brad; CLEAN / FIXED / NEEDS-BRAD verdict |

### Stage 2 speed note (learned on r300, 2026-07-25)
One selector adjudicating a 450-candidate pool serially takes ~45-60 min (reads ~650KB of candidates +
the full catalog, rules on every dish with a written reason). For pools this size, split stage 2 by
PROTEIN into parallel selectors (each gets its protein's slices + the full live catalog + that protein's
target), then run a short final merge pass in the main session for the only cross-protein risk:
same-dish-different-protein twins (e.g. a turkey chili vs a beef chili candidate). Cross-protein twins
vs the LIVE catalog are already each selector's job; only candidate-vs-candidate twins need the merge pass.

### Stage 2.5 speed note (learned on r300, 2026-07-25) - REVIEW NEXT RUN
Candidate optimizations for the normalize/rule-writing stage, none applied yet - evaluate before the
next run, and only keep what costs zero accuracy:
1. Rules COMPOUND across runs: r300-canon-rules.json + r100's become the standing base, so each run's
   unmapped list shrinks. Promote run-specific rule files into one canonical canon-rules file after the
   run's audit passes (audit first - never promote unaudited rules).
2. Start normalize DURING harvest: run the splitter + normalizer per harvest chunk as each lands
   (incremental unmapped inventory) instead of waiting for all chunks. The rule agent can start on the
   first ~80% of the inventory while the last chunks finish.
3. Parallelize rule DRAFTING by ingredient family (spices/condiments vs produce vs proteins vs
   packaged) across 2-3 agents - BUT rules are order-sensitive and first-match-wins, so drafts must
   merge through ONE serial integrator that owns ordering, then the full hijack audit runs exactly as
   today. The audit is the non-negotiable part; never split or skip it.
4. Cheap mechanical win: extend the splitter's prep-word stripping (CleanItem) with the highest-volume
   noise seen in r300 ("minced", "tsp." units, trailing "to taste") so fewer distinct unmapped strings
   reach the agent at all.

### Pre-launch efficiency checklist (r300 retrospective, 2026-07-25)
What we'd do differently BEFORE dispatching the next big run:
1. CAPTURE-AT-VERIFY (biggest win): sourcers already fetch every candidate page to verify it is a real
   recipe, then a separate harvest wave re-fetched all selected pages. Require sourcers to transcribe
   ingredients/servings/nutrition INTO the candidate record at verification time. Kills an entire stage
   (~8 agents / ~45 min / ~730k tokens on r300) for the cost of slightly fatter candidate files; capture
   on cut candidates is cheap because the page text is already in the sourcer's context.
2. WEB-SEARCH BUDGET: 10 parallel sourcers burned the session's 200 WebSearch calls in minutes; every
   agent hit the wall mid-slice and independently rediscovered the fallback. Before the wave: raise
   CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION, and put the fallback (site category indexes, WordPress
   /wp-json/wp/v2/search and ?s= search, known 403 domain list) in the dispatch prompt from the start.
   Discovery bias was real (one slice went 13/40 Chinese because index-crawling replaced search).
3. SHARED PRE-DIGESTS: write ONE catalog digest (slugs+names by protein) and ONE merged candidate pool
   file before dispatch, instead of 10 sourcers each re-reading recipes-db.json and the selector
   re-reading 10 files. Same for any common brief: put it in a file agents Read, not 10x in prompts.
4. SIZE SLICES BY DUPE PRESSURE: chicken had the thinnest candidate margin (92 for 59) exactly where
   the live catalog was densest (69 live = highest dedup kill-rate). Oversupply should scale with
   existing-catalog density, not be uniform.
5. KNOWN-BLOCKED DOMAINS: route candidates whose source is on the 403 list straight to the browser
   capture lane instead of letting fetch agents retry them.
6. AGENT REGISTRY: verify the custom agent list loaded (one cheap dispatch) BEFORE composing the wave;
   if missing, fix the registry rather than inlining instructions, so agent defs and prompts cannot drift.

## How to start a run

Tell the session: "start a recipe run for N recipes" (optionally: theme/constraints). The session follows
this playbook, reuses the r100 pipeline in meal-prep\r100\ (see recipe-r100-expansion memory for the
engine gotchas: $Matches clobber, rule order), and dispatches stages 3/5/6 to the pinned agents by name.
Stage 6's NO-GO blocks publish, full stop. Stage 8 runs UNCONDITIONALLY after every publish of the run
(and is reusable after any other site publish, not just recipes).

After ANY batch lands in recipes-db: run meal-prep\normalize-recipe-ids.ps1 (stamps item_id + protein;
the free-dinner rotation and the hub Top 5 read the protein field and must stay set-identical).
