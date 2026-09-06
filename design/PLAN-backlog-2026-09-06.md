# Plan: working the course backlog

Ruling requested on this file before E1 is touched. Source: `design/BACKLOG-course-findings.md`
(18 E-items, 6 I-items; D1 and D2 already shipped). Written 2026-09-06.

**Regime note.** Every rule this plan writes into a file is stated with the condition it holds
under, per `claude-code-craft` 12.4c. Eleven consecutive courses each found one contradiction in
our own skills and every one was the same defect: a rule true in one regime written as universal.
Where a rule below has no named regime, that is a defect in this plan, not a universal rule.

---

## 0. Where I disagree with the buckets

Brad's read, and my challenge. Seven changes; the rest I agree with.

| Item | Brad | Mine | Why |
|---|---|---|---|
| **E8** | *(unbucketed)* | **MINE TO DECIDE** | It is a permission-mode change. I6 establishes that permission settings are not mine to alter; E8 is the same class and the same answer should apply. |
| **I3, I4** | *(unbucketed)* | **MINE TO DECIDE** | Both are "no version control / no backup" outside this repo, which is I1's question with a smaller radius. They should be ruled on together with I1, not separately. |
| **I2** | MECHANICAL | **SPLIT** | Deleting two paths is mechanical. "Find the writer before deleting the evidence" is open-ended investigation with no bound - I searched statically and found no writer. See I2 below for the split. |
| **E3** | MECHANICAL | **SPLIT** | Writing a situational-tools sentence is mechanical. But four of the twelve agents declare **no `tools:` line at all**, so they inherit every tool including Write and Edit - and two of those four are verdict-only agents. Narrowing them changes behaviour and is a design call. |
| **E7** | MECHANICAL | MECHANICAL, **with one measurement gate** | Sized below: 39 boards, 127 MB, so a glob is affordable but wasteful. The bigger risk is that `.worktreeinclude` is a course claim I have not verified against the product. Verify first; if it is not real the item becomes a small seed script, still mechanical. |
| **E16** | MECHANICAL | **probably ALREADY RULED** | No plugins are installed on this machine, and the finding is already recorded in `claude-code-automation` 8.3. The only change left in *this* estate is a pre-install check, which is one line. I propose measuring what `bash` actually resolves to here and then either closing it or adding the regime note - not inventing a change to justify the ticket. |
| **E13** | DESIGN-FIRST | DESIGN-FIRST, **premise corrected** | As written it says "emit memory ids and inflate them in code." There is no code layer between this session and a spawned agent - the Agent tool takes a prompt string, so there is nowhere to inflate. The implementable version is references-as-paths. See E13. |

Two further premise corrections that do not move a bucket but change what gets built:

- **E4** assumes the dedup pipeline is live and embeddings-only. Memory `ingest-dedup-gate-cannot-fire`
  records that the ingest dedup refusal path is retired and that the ingredient prompt made recall 19
  points *worse*. Before building a BM25 index, confirm which half of that pipeline still rules
  anything. E4 is last in the order for this reason.
- **E12** overlaps machinery that already exists: `ops/audit-twin-drift.ps1` is in run-gates precisely
  to catch "a rule this estate keeps in two files has drifted apart." E12 should be scoped to the
  rules that auditor cannot cover, not restated as if nothing guards this.

---

## 1. Bucket assignments after the challenge

| Bucket | Items |
|---|---|
| **MECHANICAL** (Phase 2, no ruling needed) | E2, I2a, E15, E3a, E7, E16 |
| **DESIGN-FIRST** (Phase 3, after the ruling) | E1, E6, E3b, E14, E13, E12, E9, E10, E11+E18, E5, E4 |
| **MINE TO DECIDE** (untouched) | I1, I3, I4, I5, I6, **E8** |
| **ALREADY RULED** | E17 |
| **Open investigation, not a change** | I2b (find the writer) |

---

## 2. Phase 2 - the mechanical bucket

Order is dependency-first: E2 is the instrument every other item's verification is read through, so
it ships first.

### E2 - bare numeric codes crossing agent boundaries

**What is broken.** The estate runs **three** exit-code vocabularies, not two, and an agent handed a
bare number cannot tell which one it is in:

| Vocabulary | Where | 0 | 1 | 2 | 3 |
|---|---|---|---|---|---|
| `lib/guard-contract.ps1` (older) | ~100 audit scripts | clean | - | hard finding | could-not-evaluate |
| PLAN v3 §4.5 battery | `wave-preaudit.ps1` and successors | clean | findings, report written | **could-not-run** | - |
| `ops/run-gates.ps1` | the change-time gate | passed | at least one failed | - | could not evaluate |

Measured: 56 `exit 2` sites across 38 files, 103 `exit 3` sites across 60 files, one `exit 4`. So
**`2` means "hard finding" in 38 files and "could-not-run" in the battery.** That collision is the
item. The five prompts corrected in `6a05dcd7` state a two-tool rule in a three-vocabulary estate,
which is the same defect one level up.

**The change.** Two halves, and the second is the durable one.

1. *Reading side.* Replace the "run-gates uses 3, the battery uses 2" sentence in the five agent
   definitions carrying it with a rule that does not enumerate tools: **in this estate an exit code
   carries no meaning across tools; read the verdict LINE the tool printed, and if there is no
   verdict line the run is could-not-evaluate.** Regime: holds for any script in this repo, because
   every convention here prints a words-level verdict. It does *not* hold for third-party tools.
2. *Writing side.* Make `run-gates.ps1` print a words-level verdict on **every** exit path, not only
   on 3. It already prints `run-gates: COULD NOT EVALUATE - ...` before `exit 3`; the 0 and 1 paths
   print a tally, not a verdict. One line each.

Explicitly **not** doing: rewriting 100 audit scripts to a single vocabulary. That is a large
migration with a real chance of flipping a gate's meaning silently, and it is not what the item asks
for.

**Blast radius.** Five agent definition files (prose only) plus one behavioural line in
`run-gates.ps1`. No script's exit code changes value.

**Gate.** `ops/run-gates.ps1` exit 0 from the main checkout, plus reading the new verdict line on a
deliberately failed run (I will break one self-test in a scratch copy, confirm the words appear on
the exit-1 path, and restore it). A run that only proves the exit-0 path proves half of this.

---

### I2a - a gate for stray root artifacts

**What is broken.** Two path-construction bugs left artifacts at the repo root: a 7,094,631-byte
TSV named `3 cups sliced, for topping` (an ingredient base-amount string used as a redirect target,
written 2026-09-03) and an empty `CodexThriftyCrewgroceryoutcaptures_sink` (a `C:\Codex\ThriftyCrew\
grocery\out\captures_sink` with its separators eaten). Both are gitignored by `.gitignore:3` (`/*`),
so **nothing in the estate can see them** - they are invisible to git status, to every audit, and to
the gate.

**The change.** `ops/audit-stray-root-artifacts.ps1` with a `-SelfTest`, which run-gates discovers
automatically. It fails when an untracked, non-allowlisted entry at the repo root has a name that
looks like a *constructed path* (a drive-letter-and-separators run with no separators left) or a
*measurement string* (leading digit plus a unit word). Allowlist is an explicit named list, in the
house style: a line is a decision someone defends in a diff.

This is the process fix. Deleting the two artifacts buys one correction; the gate catches the next
one, and the next one is the point - two independent writers produced this shape already.

**Disposal, not deletion.** Per `agent-workflow-craft/agent-architecture.md` §2, quarantine instead
of destroy: both move to `ops/quarantine/2026-09-06-stray-root/` with a `WHY.md` naming what they
were and when. A move is its own inverse and needs no log. This also keeps I2b's evidence alive.
Nothing is deleted in this phase.

**Blast radius.** One new file, two moves. Nothing tracked changes.

**Gate.** run-gates exit 0 with the new self-test in the discovered list (its count goes up by one -
I will read the count, not assume it). Plus the must-fire discipline: the self-test drives a frozen
fixture of both real names and a clean twin, so it fails loudly if the detector stops detecting.

---

### E15 - "Ask for Input", and it must come last

**What is broken.** `.claude/skills/lesson`, `.claude/skills/meal-macro` and
`.claude/skills/recipe-hunter` are all rules-first skills that take user input, and all three end
with a constraints list. None ends with an ask-for-input statement, so on a bare invocation the
skill invents its own first input instead of waiting.

**The change.** One closing statement per skill, as the final line. It must compose with the standing
memory `always-prompt-for-direction` (never ask in prose; use the question tool with options plus
Other), so the statement names that mechanism rather than saying "ask the user."

Regime: holds for a skill that **consumes** a user-supplied brief. It does not hold for a reference
skill, which has no first input to wait for - so the eight personal craft skills are untouched.

**Blast radius.** Three files, one line each, at the end. No behaviour outside a skill invocation.

**Gate.** run-gates exit 0 (regression only - it does not read skills), plus an actual invocation
check: invoke each of the three with no argument and confirm it asks rather than starts. This is the
one item whose real gate is a behavioural observation, and I will report what I observed, not that I
ran it.

---

### E3a - which tools are situational

**What is broken.** Course 6's finding: given three well-named tools and no usage context, the agent
decided the unnecessary one must be needed and **invented work to justify it**. Eight of our twelve
agents declare a `tools:` list with no statement of which are optional. `recipe-hunter-pricer`
declares **28**, including two complete and overlapping browser tool sets (`mcp__Claude_Browser__*`
and `mcp__claude-in-chrome__*`), which is the worst case in the estate: two ways to do one thing,
with nothing saying when each applies.

**The change.** One paragraph per agent, in the body, naming which tools are situational and what
situation selects them. For the pricer specifically, the two browser sets need the rule that already
exists in memory (`chrome-is-always-available`, `chrome-debug-port-blocked-on-default-profile`)
written into the definition, because a spawned agent gets no memory index beyond a session-start
snapshot.

Scope here is the **eight that declare a list**. The four that declare none are E3b.

**Blast radius.** Eight agent definition files, prose only. No tool list changes in this item.

**Gate.** run-gates exit 0 (regression). The real check is a read: for each of the eight, the
situational tools named in the paragraph must be a subset of the frontmatter list. I will diff those
two sets mechanically rather than by eye, because that is exactly the drift E3 is about.

---

### E7 - `.worktreeinclude`

**Sizing, which the backlog asked for first.** The full ignored set is ~25 GB (`grocery/out` alone is
4.1 GB, `meal-prep` 8.3 GB), so a broad list is out. The narrow set:

| Candidate | Size | Needed by |
|---|---|---|
| newest `grocery/out/comparison-*.json` | 4.2 MB | guards, tile-integrity, every data audit, the pricing engines |
| all 39 `comparison-*.json` | 127 MB | only the trend/history audits |

**One open question, and it decides the shape.** `.worktreeinclude` is a claim from course 1
(`claude-code-craft` §10) that I have **not verified against the product**. Per memory
`verify-model-claims-externally`, I will confirm the mechanism exists before writing the file. Two
outcomes:

- *It exists* - ship `.worktreeinclude` naming the narrow set. If it only accepts globs and not
  "newest", take the 127 MB: correctness beats 123 MB of disk, and a worktree with yesterday's board
  is the blindness this item exists to fix.
- *It does not exist* - ship `ops/seed-worktree.ps1` instead, doing the same copy explicitly. Still
  mechanical, different artifact. I will say which one happened.

**Blast radius.** One new file. Nothing existing changes. A worktree created before it lands is
unaffected.

**Gate.** run-gates exit 0 in the **main** checkout, then the real proof: create a throwaway
worktree, run `ops/run-gates.ps1` inside it, and read whether it is still blind. Memory
`run-gates-blind-in-worktrees` says it is today. If the number of discovered self-tests or the audit
verdicts do not change, the file did nothing and I will report that rather than claiming the item.

---

### E16 - plugin hooks in bash

**What I expect to find.** No plugins are installed here (`~/.claude/plugins/` holds only
`known_marketplaces.json` and the marketplace cache), and the finding is already written into
`claude-code-automation` 8.3. So there may be no change owed in this estate at all.

**The change, conditional on a measurement.** Resolve what `bash` actually is on this machine's PATH
as a hook would spawn it. Then:

- *WSL wins* - the recorded hazard is real as stated; add the pre-install check as a line in the
  skill's §8 read-before-you-install rule, naming the regime (Windows, WSL on PATH).
- *Git Bash wins* - the skill's entry is **over-stated** and needs the regime note instead: the
  failure is real on machines where WSL shadows Git Bash, and this is not one of them. That is a
  12.4c fix, and it is the more likely and more useful outcome.

Either way I expect to close E16 as `WONTFIX` or `DONE (already recorded)` rather than shipping a
change to justify the ticket.

**Blast radius.** A skill file outside this repo, or nothing.

**Gate.** The measurement itself, reported with its command and output. There is no repo gate for
this item and I will not imply one.

---

## 3. Phase 3 - the design-first bucket, proposed order

Rationale for the order: E1 first because it is the longest wall-clock and blocks nothing; E6 second
because it is the cheapest thing that lands on the correct side of a publish and ships whichever E1
design wins; then the items that shrink context and risk; then the two experiments last, one of them
gated on re-checking its own premise.

| # | Item | The change, in one line | Blast radius | Gate that proves it |
|---|---|---|---|---|
| 1 | **E1** | **Two designs, built and compared - not one picked.** (a) staging: writes queue, reads execute, a review pass drains the queue. (b) action log that doubles as an undo log, with a `revert` the agent may call. | Every writing agent and the publish chain. The largest on the list. | A deliberately wrong write, staged or reverted, with the live board proven unchanged. Not a dry run. |
| 2 | **E6** | Fact Check List before publish: ask the generator for the claims that would undermine its own output, diff against the prose. | The publish path, additively - it gates nothing yet. | Run it against a recipe with a known-bad claim already on record and confirm it names that claim. |
| 3 | **E3b** | The four agents with no `tools:` line get one. Two of them (`post-publish-reviewer`, `recipe-batch-auditor`) are verdict-only and arguably belong read-only. **Needs a ruling: does a verdict agent lose Write?** | Four agent definitions, behavioural. | Each of the four run once on real work after narrowing; a refusal caused by a missing tool is a failed narrowing, not a pass. |
| 4 | **E14** | Split the root `CLAUDE.md`'s per-directory conventions into path-scoped `.claude/rules/` files. | The always-on context load for every session in this repo. | `InstructionsLoaded` or an equivalent read confirming a `grocery/` rule does **not** load when working in `meal-prep/`. A shrunk CLAUDE.md that still loads everything is not the win. |
| 5 | **E13** | Briefs to spawned agents name memory **paths** and require the agent to read them, rather than restating their content. (Premise corrected: there is no code inflation point.) | Every spawn prompt. | A spawned agent's report cites the file it read. Paraphrase in the brief is the defect being removed, so the check is that the brief contains none. |
| 6 | **E12** | Load the ruling documents at run time and pair with a schema'd verdict, **scoped to the rules `audit-twin-drift.ps1` cannot already cover.** | Whichever rules move. | The existing twin-drift auditor, plus a deliberate edit to the ruling document changing the outcome with no code change. |
| 7 | **E9** | Model per call rather than per agent, starting with the highest-leverage split (expensive plan, cheap execution). Verify `claude-opus-4-8` is a real id first - two agents pin it. | Cost and **attribution**: a ruling's recorded model must stay true. | A run whose recorded model matches what actually answered. |
| 8 | **E10** | End-of-iteration progress report every Nth loop in the Recipe Hunter daemon; calibrate N by running plan-only and watching for drift. | The daemon's cost and its context. | The calibration measurement itself - "N=5" with no observed drift point behind it is a guess. |
| 9 | **E11+E18** | **Ship together or not at all.** Decorator-derived tool schemas *plus* runtime validation of model-supplied arguments. Adopting E11 alone inherits exactly the gap E18 names. | The daemon's tool layer. | A malformed and an out-of-range argument, each rejected at the boundary before the tool body runs. A test that only sends valid arguments proves nothing here. |
| 10 | **E5** | Four-layer validation at source (format, business rules, self-prompted semantic, human review) with low confidence routed to **review, not rejection**. | The ingredient queue and the capture readers. | A low-confidence row appearing in the review queue rather than being dropped. |
| 11 | **E4** | BM25 alongside the embedding index, merged with reciprocal rank fusion. **Gated on first confirming what in that pipeline still rules anything** (see §0). | The dedup pipeline. | A rare exact identifier - a commodity id or SKU - retrieved by BM25 and missed by embeddings, measured, not asserted. |

---

## 4. What I will not touch

`I1`, `I3`, `I4`, `I5`, `I6` and `E8`, per §0. `E17` is a ruling already made and stays as written.

I2b - finding the writer of the stray root artifacts - stays open as an investigation. Static search
across the meal-prep and grocery trees found no script emitting that four-column TSV shape and no
redirect to an unquoted variable that would explain the filename. The artifacts are quarantined, not
deleted, so the evidence survives until the writer surfaces or the shape recurs and the new gate
catches it in the act.
