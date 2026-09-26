# PLAN: a measured pilot of the local LLM in two places in the alert triage

Status: DRAFT for Brad's review, not built. Written 2026-09-26.

## Why

The triage routine's cost is Opus reasoning. Two jobs inside it are narrow, repetitive and checkable,
so a local model might do them for nothing:

1. **Condensing gate output (pilot G).** A refused landing leaves a 300 to 800 line log, and the
   orchestrator or a developer reads it to find the few red lines. On 2026-09-25 six refused landings
   (two daily, two weekly, two round 2) were each diagnosed by reading logs.
2. **Proposing worklist verdicts (pilot W).** The band-refusal and contested-name worklists hold
   rows that wait for a hand decision (1,091 band backlog keys plus 38 open on 2026-09-25, and 139
   September contested names). Each row is one question: is this product the commodity, a wrong
   product, or a real price the band refuses? Rows waiting on that decision are why 2026-09-22-0c812e
   cannot close.

Neither pilot lets the model decide anything. Pilot G only summarises; the gate's own verdict line
stays the truth. Pilot W only proposes; the existing `resolve-match-worklist -Decide` step, by a person
or a lane, still decides, and no proposal writes `match-verdicts.json` or `commodities.json`.

## Knowledge consulted

- `experiment-craft/analysis-preflight.md`, all ten lines, in particular: "The bar is written before
  the run, in the metric's own units"; "One row per case per arm, and the totals are derived from those
  rows"; "A rate carries its denominator AND its coverage ... a matcher that abstains on the hard rows
  outscores one that attempts them"; "Name the harness and the blob it ran at".
- `.claude/rules/measurement.md`: "A matcher that ABSTAINS is scored on what it skipped"; "RECORD THE
  CASE AT THE MOMENT IT FAILS"; "A fixture's 50% base rate overstates precision enormously".
- memory `a-delegated-finding-is-an-input` ("confident phrasing is not evidence") - why pilot W
  proposes and never decides.
- memory `per-slot-context-is-context-over-slots`: "-c is the TOTAL KV budget and llama.cpp DIVIDES it
  by --parallel ... At the defaults -Context 16384 -Slots 4 that is 4,096 per slot" - why pilot G
  pre-filters before it prompts.
- memory `start-llama-server-never-wait-for-it`: if llama-server is down, start it; always `-Slots 1`
  for the hunter. And GPU sharing with the 07:00 ad pull (serve.ps1's own guard).
- `mcp-craft/intelligence-budget.md`, "Layer it, cheapest first": deterministic rules before any model
  call. Both pilots keep a deterministic arm as the baseline the model must beat.
- `grocery/test-match-worklist.ps1` header: the 24 frozen labels and the bar "written in the plan
  BEFORE the classifier existed", with its HONEST LIMIT that those labels are in-sample for the rules.
- searched "classifier label precision abstain bar": nothing further applicable.

## The model and the box

`tools/local-llm/serve.ps1` serves `C:\Codex\llm\models\Qwen3.8-27B-UD-Q3_K_XL.gguf` (llama.cpp build
b10509) on an OpenAI-shaped endpoint, default port 8080, default `-Context 16384 -Slots 4`, 4,096 tokens
per slot. The GPU is shared with the 07:00 ad pull and the Recipe Hunter. Triage runs at 09:45, after
the pull. The pilots run OFFLINE against frozen inputs, never inside a live triage run, until a bar is met.

## Pilot G: condense a gate log into its failures

**Input.** Every kept landing log: `%LOCALAPPDATA%\ThriftyCrew\triage-land\*.log` (13 on 2026-09-26)
plus the push-main output files of the same runs. Each log is ONE case (distinct input), however many
arms read it.

**Ground truth, deterministic, written first.** For each log, the set of failing gates and cases as
the tools already print them: `run-gates`' `failed: <script>` lines, `prepush-test-auditors`'
`NEW FAILING CASE` lines, `push-main: REFUSED` cause, and `blind=` tokens. A script extracts this set;
it is committed as `ops/probe-gate-log-truth.ps1` with frozen fixtures (one red log, one green, one
blind), so the truth is reproducible and not model output.

**Arms.**
- **A0, deterministic:** the same extractor, returning its set plus the 5 lines around each hit. This
  is the baseline, and if it already does the job the pilot's answer is "no model needed".
- **A1, local model:** a pre-filter keeps lines matching FAIL|REFUSED|blind=|NEW FAILING|exit [1-9]
  with 3 lines of context, capped to fit 3,000 tokens; the model returns JSON
  `{failed:[{gate, case, one_line_cause}], blind:[...], refused_cause}`.
- Optional **A2, local model on the raw tail** (last 3,000 tokens, no pre-filter), to learn whether the
  pre-filter is doing the work.

**Bar, written now, in the metric's units.**
- Recall of failing gates: A1 names every failing gate in at least 12 of 13 logs, and never names a
  gate that did not fail in more than 1 of 13.
- Blind honesty: every log with a `blind=` token is reported blind by A1 (13 of 13 where present).
- A1 must add something A0 lacks to be worth running: its `one_line_cause` is judged correct (by the
  orchestrator, against the log, blind to arm) in at least 10 of the logs that have a failure.
- Coverage: a malformed or empty model reply counts as a MISS, never skipped.
If A0 already meets the recall and blind lines, adopt A0 alone and stop.

**Where it would land.** `grocery\triage-land.ps1` and `ops\push-main.ps1` would print the condensed
block beside the verdict line, so the orchestrator reads that instead of the log. The verdict line and
exit code stay authoritative; the summary is labelled advisory.

## Pilot W: propose worklist verdicts

**Input.** Worklist rows as `resolve-match-worklist` presents them: product name, store, claiming
commodity (id, label), candidate commodity, price and size where present, and the band where the kind
is `band`.

**Ground truth.** Only rows a person or a lane has already DECIDED, taken from
`grocery/match-verdicts.json` (39 verdicts on the round-2 branch) and the 24 frozen labels in
`grocery/test-match-worklist.ps1`. Undecided rows are never scored. Every scored row keeps its `source`.
Known limits, stated now: the decided set is small (about 60 distinct inputs), mostly contested and
coverage kinds, and it has almost no band-kind rows, so pilot W can prove little about the 1,091 band
keys until more are decided by hand. Step W0 below addresses that.

**Arms.**
- **B0, the existing head-noun classifier** in `match-worklist-lib.ps1` (today: 13 decided of 24
  frozen, 0 wrong after 706c8de4e; 2 of 11 wrong on the contested September labels before it).
- **B1, local model:** returns `{verdict: confirm|release|ad-line|abstain, reason}`; ABSTAIN is
  allowed and scored as coverage, never as correct.

**Bar, written now.**
- Wrong decisions: B1 is wrong on at most 1 of the scored rows it decides, and on 0 of the 24 frozen
  labels. A wrong `confirm` (a wrong product left on a commodity) counts double, because that is the
  direction that reaches a price.
- Coverage: B1 decides at least 20 more scored rows than B0, with the count printed as "decided N of M".
- In-sample honesty: B1's prompt is written without looking at the scored rows' answers, and the 24
  frozen labels are held out of any prompt examples.

**Step W0, before scoring band rows:** Brad or a lane decides a random 40 of the 1,091 band keys by
hand (seeded draw, seed printed, per ops rules on `Get-Random`), recorded through `-Decide` as usual.
Those 40 are the band-kind test set. This step costs a person's time, which is why it is a question below.

**Where it would land, if it passes.** A `-Propose` mode on `resolve-match-worklist` that writes a
proposals file beside the worklist, never into `match-verdicts.json`. A person or lane still runs
`-Decide`. Proposals would let the weekly lane clear the backlog at reading speed rather than at
research speed.

## Harness and records

- Both pilots commit their harness (`ops/probe-local-llm-gatelog.ps1`, `ops/probe-local-llm-worklist.ps1`)
  because the question will recur with every model change.
- One row per case per arm in `ops/out/local-llm-pilot-rows.jsonl`: case id, input fingerprint
  (sha256), arm, output, verdict against truth, latency, tokens. Totals are derived from that file.
- Each result states the model file, serve.ps1 blob, prompt text blob and harness blob
  (`git rev-parse HEAD:<path>`), never an unlanded commit hash.
- Runs are scheduled away from 07:00 to 09:30 and never while the Recipe Hunter holds the GPU; a
  run that finds llama-server down starts it (`serve.ps1`), and one that cannot get the GPU reports
  BLIND, never a score.

## Build order and size

1. Pilot G truth extractor and fixtures (small, deterministic, useful on its own).
2. Pilot G arms A0 and A1 over the 13 logs, verdict against the bar.
3. Pilot W arm B0 and B1 over the decided set, verdict against the bar.
4. W0 hand-decided band sample, then B1 over it, if Brad approves W0.
5. Only for a pilot that met its bar: the integration named above, behind a switch, off by default for
   one week of triage runs with both the old and new outputs logged, then a decision.

## Questions for Brad

1. **W0:** is a person's pass over 40 band rows acceptable to create a band test set, or should pilot W
   stay on contested and coverage rows only?
2. **GPU window:** is any slot in the day off-limits besides 07:00 to 09:30 and hunter runs?
3. **Adoption rule:** if a pilot meets its bar, may the integration go live after its week of
   side-by-side logging without a further ruling, or does each go back to you?
