# Adapter drill: what the measurement said (2026-08-24)

Section 4.1a asked the phase-3 drill to dispatch every agent type once against scratch inputs, diff
its behavior against a Workflow-dispatched twin, and measure the fixed per-call overhead. It did.
The numbers live in `adapter-drill.json`; this is what they mean.

## 1. The premise section 4.1a was written on is false on CLI 2.1.173

The plan says, in as many words: "`claude -p` cannot invoke a named subagent as its top-level agent -
subagents in `.claude\agents\` are things a running session delegates to, not entry points", and on
that basis it ordered the adapter to RECONSTRUCT each agent from its definition file.

Measured:

    $ echo "List the exact names of every tool available to you right now, comma separated on one
      line, nothing else." | claude -p --agent recipe-source-qa --output-format json
    result:      "WebFetch, Read, Grep, Glob, Bash, PowerShell"
    modelUsage:  claude-fable-5 (plus a ~450-token haiku housekeeping call)
    num_turns:   1

That tool list is `recipe-source-qa`'s frontmatter list exactly, and `claude-fable-5` is its
frontmatter model. One context, nothing delegated to anything.

So `--agent` is the primary road, and it is better than the reconstruction the plan ordered for a
reason beyond convenience: reconstruction would make `hunt_dispatch.py` a SECOND reader of the
frontmatter, and two readers of one authority is how this estate's forked-taxonomy defects start.
With `--agent`, the CLI reads the file and the adapter cannot disagree with it. Section 4.4a's
"the frontmatter is the single authority" is satisfied by construction rather than by care.

The reconstruction road is still built and still fixtured (`reconstruct=True`), as the fallback if a
future CLI drops `--agent`.

## 2. `effort` HAS a CLI flag, so there is no gap to record

Section 4.1a: "Where a frontmatter field has no CLI flag (e.g. `effort`), record the gap in the drill
report." `claude --help` on 2.1.173 carries `--effort <level>` (low, medium, high, xhigh, max). The
adapter parses the frontmatter's `effort` and passes it explicitly. **There is no dropped-field gap
to report.** Every frontmatter field the estate's agents use - `model`, `effort`, `tools` - reaches
the dispatch.

## 3. The fixed per-dispatch overhead, both roads

Every drill prompt is deliberately tiny (~60 tokens), so the input token count IS the fixed overhead:
the project context a headless invocation loads whether the question is large or small.

| | headless (`--agent`) | Workflow twin |
|---|---|---|
| input tokens, min | 7,220 | 18,452 |
| input tokens, median | 15,470 | 49,624 |
| input tokens, mean | **18,050** | **46,572** |
| input tokens, max | 30,942 | 78,624 |
| output tokens, mean | 224 | 404 |
| wall clock, mean | 7.3 s | (10 in parallel, 12.7 s total) |
| cost, mean | $0.20 | not separately reported by the harness |

**The headless road costs about 2.6x LESS context per dispatch than a Workflow subagent.** Section
4.1a hedged the other way - "If measured overhead is large, the counter-move is bigger dossiers per
call" - and that counter-move is not needed. Batch sizes stay caps rather than becoming quotas for
overhead reasons.

Cache behaviour is worth knowing before anyone re-measures: three of the ten headless dispatches read
20,044-23,268 tokens from the prompt cache, and the other seven created 1,895-23,514. The cache is
shared across processes on the same account, so a re-measurement on a warm cache will read lower and
a cold one higher. The 18,050 mean is a mixed-cache figure and should be quoted as one.

## 4. The behavior diff: 10 of 10 agree

Every agent type returned a schema-conforming verdict on both roads, and every key the spec named as
load-bearing matched:

| agent | key | both roads |
|---|---|---|
| recipe-sourcer | unverified_macros | KEEP |
| recipe-dedup-selector | decisions.0.slug | drill-garlic-butter-chicken-thighs |
| recipe-hunter-extractor | state / ingredients / instructions | ok / 5 / 3 |
| recipe-ingredient-mapper | unbid_ingredient, no_match_item_id_is_null | HOLD, true |
| recipe-hunter-pricer | verdict | PENDING |
| recipe-writer | computes_numbers | false |
| recipe-source-qa | blocked_domain_is_a_finding, verdict | false, PASS |
| recipe-batch-auditor | verdict | NO-GO |
| post-publish-reviewer | recipes_shipped, wave_only_review_sufficient | 25, false |
| commodity-registrar | edits_catalog, mechanisms.length | false, 3 |

Reconstructing an agent outside the harness does not change what it decides.

## 5. The one live refusal, and it was the adapter working

The drill's FIRST mapper dispatch failed, twice, and was refused whole. It is worth writing down
because it is the only live demonstration of section 4.1a's re-ask contract in this phase.

The drill asked for `{"no_match_item_id": "<the literal value>"}` typed as a string. The mapper
answered with the JSON literal `null`, which is the correct answer to the question. The adapter:

  * validated in the daemon's own process and found one named violation;
  * refused the payload WHOLE - nothing written, nothing coerced;
  * re-asked ONCE, quoting the violation and the agent's own prior answer back to it;
  * got the same honest `null`, and refused again with the surviving violation named.

That is exactly the ordered behavior, and the defect was in the drill's prompt, not in the adapter or
in the mapper. The field was reworded to `no_match_item_id_is_null` (boolean) and the dispatch re-run.

**The divergence that rewording exposed is a real finding about the two roads.** The Workflow twin,
whose harness FORCES structured output, coerced the same honest `null` into the string `"null"` and
passed. The headless road validates after the fact and refused. Neither is wrong, but they are not
the same guarantee: the harness's forcing can quietly satisfy a schema by changing an answer's type,
where the daemon's validate-then-refuse surfaces the disagreement. For a daemon whose whole reason
for validating in-process is "never auto-coerce", the headless behaviour is the one this plan wants.

## 6. Nondeterminism is real on judgment questions too

The mapper's first twin run answered `ADVANCE` to the unbid-ingredient question; the second twin run,
same prompt, same agent, answered `HOLD`. Same road, same question, different verdict. This matters
for reading any single-sample diff: a one-off disagreement between the roads would not have proven a
road effect. It is the judgment-lane counterpart of the phase-2 finding that rung 1 at temp 0.1 is a
coin flip on borderline pages.

(The final recorded answer, HOLD, is the one that matches the orchestrator's own map-lane dispatch
text: "A recipe whose ingredient resolves but has NO bid must HOLD at mapped". That the agent can be
talked out of it by nothing at all is a D7 concern, not a D9 one - it is an argument for the
pre-resolve table making the rule mechanical rather than asking the model to remember it.)

## 7. The read-only decider's first live test

The `recipe-dedup-selector` frontmatter went read-only (`tools: Read, Grep, Glob`) in D5 and had
never been live-tested - both phase-1 gate rounds predate it and phase 2 dispatched no decide batch.
It was dispatched twice here, once down each road, on a one-candidate scratch dossier.

It returned a schema-conforming DECIDE payload both times, ruled `accepted` with its reasoning
anchored on the dossier's own neighbour evidence, and **wrote nothing**: no `selected.json`, no run
dir, no ledger row. `permission_denials` was empty on the headless dispatch, meaning it did not even
attempt a write to be refused. The prose-to-frontmatter fix holds under a real dispatch.
