# Estate backlog from the course programme

Everything the Claude/AI course queue has surfaced that we should CHANGE in this estate. Opened
2026-09-06 while working the 15-course queue (`~/.claude/skills/course/QUEUE.md`; per-course detail
in `LEDGER.md` beside it).

**This is a backlog, not a plan.** Nothing here is ordered work until Brad rules on it. Each item
says what, why, and what it would touch, so the size of the bet is visible before anyone takes it.

Status: `OPEN` proposed, not started · `DONE` shipped, commit named · `WONTFIX` ruled out.

---

## Shipped

| ID | What | Commit |
|---|---|---|
| D1 | Reasoning before verdict in `recipe-dedup-selector` and `recipe-source-qa` | `b78e168e` |
| D2 | Worktree blindness + "reporting a result you did not observe" blocks added to the five writing agents | `c56ac827` |
| E2 | Agents stop decoding exit codes and read the verdict line; `run-gates` states its verdict in words on every exit path | `5a7fccf0` |
| I2 | `ops/audit-stray-root-artifacts.ps1`, both halves in the gate; four strays quarantined with a mapping | `558321d5` |
| E15 | Ask-for-Input closing statement on `lesson`, `meal-macro`, `recipe-hunter` | `8e3de6d9` |
| E7 | `.worktreeinclude` + `ops/seed-worktree.ps1`; a bare worktree went 183/6 to 187/2 | `4e8102c2` |
| E3a | Situational-tools block on the eight agents that declare a `tools:` list | `803af3d2` |

Plan for the rest: `design/PLAN-backlog-2026-09-06.md`, which also records seven re-buckets and the
items nobody had bucketed (E8, I3, I4).

---

## Safety and correctness

### E1 - The estate takes irreversible actions with no safety layer `OPEN`
*Source: AI Agents Architecture (course 7).* Board cells, `known-wrong` rulings, Ghost publishes
and R2 writes are all irreversible from an agent's side, and **`post-publish-reviewer` runs after
the irreversible step**, which is the wrong side of it. Two cheap patterns: **staging** (reads
execute, writes queue for a review pass) and an **action log that doubles as an undo log**, with a
`revert` tool the agent may choose itself. Touches every writing agent and the publish chain.
Biggest item on this list.

### E2 - Bare numeric codes cross agent boundaries `DONE` `5a7fccf0`
*Source: AI Agents in Python (course 6).* "An agent that receives error 32 is finished." Our gate
exit codes are exactly that shape. Anywhere a gate's exit code reaches an agent without a
words-level translation is a place an agent retries identically or invents a meaning. Grep for it.
Note the irony: while adding D2 I put "exit 2" into five agent prompts and had it wrong -
`run-gates` uses exit 3, the recipe battery uses 2. Corrected in `6a05dcd7`, but that is the exact
failure this item is about.

### E3 - Tool-list relevance hazard across twelve agent definitions `PARTLY DONE` `803af3d2`
*Source: AI Agents in Python (course 6).* Given three well-named tools and no usage context, the
course's agent decided the unnecessary one must be needed and **invented bolts and screws to justify
it**. Several of our agents ship long tool lists with no statement of which are optional, how they
relate, or whether all must be used. `recipe-hunter-pricer` carries about twenty. Cheapest fix is a
sentence per agent naming which tools are situational.

**Split when it was worked, because it is two items.** `recipe-hunter-pricer` carries **28**, not about
twenty, and eighteen of those are two complete and overlapping browser sets.

- **E3a `DONE` `803af3d2`** - the situational-tools block on the eight agents that declare a `tools:`
  line. Prose, no behaviour change.
- **E3b `OPEN`, design-first** - the four that declare **no `tools:` line at all**
  (`post-publish-reviewer`, `recipe-batch-auditor`, `recipe-writer`, `triage-developer`) and therefore
  inherit every tool including `Write` and `Edit`. Two of those four are verdict-only agents, so this
  is a least-privilege hole of the same class as E1 rather than a documentation gap. Narrowing a tool
  list changes behaviour and needs a ruling: **does a verdict-only agent lose `Write`?**

---

## Accuracy

### E4 - The dedup pipeline is embeddings-only `OPEN`
*Source: Building with the Claude API (course 2), RAG module.* Vector search fails **quietly** on
rare exact identifiers: it returns plausible irrelevance rather than nothing. Commodity ids, SKUs
and slugs are exactly that shape. A BM25 lexical index alongside the embedding index, merged with
reciprocal rank fusion, is a cheap and well-defined experiment. See `rag-craft`.

### E5 - Validate at source `OPEN`
*Source: MCP (course 3).* A direct criticism of any tooling that hands a model raw rows to sift. The
four-layer stack is format -> business rules -> self-prompted semantic -> human review, with **low
confidence routed to review rather than rejection**. Applies to the ingredient queue and the
capture readers.

### E6 - Fact Check List before we publish `OPEN`
*Source: Prompt Engineering (course 4).* Ask the generator for the fundamental claims that would
undermine its own output, then diff that list against the prose. Cheap pre-publish check, close in
spirit to what `post-publish-reviewer` does afterwards - and on the correct side of the publish,
which is E1's whole point.

---

## Efficiency and ergonomics

### E7 - `.worktreeinclude` `DONE` `4e8102c2`
*Source: Claude Code in Action (course 1).* A repo-root file listing gitignored files to copy into
every new worktree. Would automate the manual copy-in that `run-gates-blind-in-worktrees` and
`worktrees-lack-the-boards-the-engines-price-on` both describe. **Needs sizing first** - the full
ignored set is ~25 GB, so it must be a narrow list: the four gates' real inputs plus the three board
files.

### E8 - "Don't ask" permission mode for unattended runs `OPEN`
*Source: Claude Code in Action (course 1).* Purpose-built for CI, scheduled jobs and overnight
batches: pre-approved tools only, everything else auto-denied with no prompt to hang on. May fit the
scheduled tasks and the daemon better than what they use now.

### E9 - Model choice is pinned per agent, but MATE's M is per call `OPEN`
*Source: AI Agents Architecture (course 7).* All twelve definitions pin one model. A tool that makes
its own LLM call can pick its own. Highest-leverage split: an expensive model for the up-front plan,
a cheap one to execute it.

### E10 - Long-running lanes have no progress tracking `OPEN`
*Source: AI Agents Architecture (course 7).* The Recipe Hunter daemon runs far past the point where
its initial plan is still near the front of context. Fix is a cheap end-of-iteration progress report
every Nth loop; calibrate N by running plan-only and watching for where drift starts.

### E18 - Tool arguments are untrusted model input, and our pattern does not validate them `OPEN`
*Source: AI Agents in TypeScript (course 10).* The Python decorator pattern in E11 **derives** a tool
schema from the function signature and then never checks what comes back: the model's arguments
arrive and are passed straight into `execute`. The TypeScript route **declares** a schema once and
gets three things from it - the JSON Schema shown to the model, the inferred argument type, and
**runtime validation of the model's arguments before the tool body runs**.

That third thing is the point, and it is a correctness boundary rather than a typing convenience. A
tool argument is model output: it can be malformed, out of range, or a path we did not intend.
Anywhere the daemon hands model-supplied arguments to a tool that writes, reads a path, or shells
out, an unvalidated boundary is the same class of exposure as E1.

Take this together with E11 rather than separately: if we adopt decorators, add explicit argument
validation at the same time rather than inheriting the gap.

### E11 - Tool decorators and tag-scoped registries for the daemon `OPEN`
*Source: AI Agents in Python (course 6).* Derive each tool's schema from its signature, docstring
and type hints. Removes the class of bug where an agent's map of a tool has drifted from the tool,
and makes "which agents can write?" a grep instead of an audit.

### E12 - Document-as-implementation `OPEN`
*Source: AI Agents Architecture (course 7).* Brad's rulings, the band rules and the naming
conventions are already written for humans and already change without a deploy. Loading the rules
file at run time and pairing it with a schema'd verdict is smaller than the equivalent code, and
removes the class of bug where the ruling document and the enforcing script have drifted.

### E13 - Pass references, not copies `OPEN`
*Source: AI Agents Architecture (course 7).* Models read far more than they can write, so a
delegating agent physically cannot restate a large memory as a task description. Emit memory ids and
inflate them in code. Beats the output cap and makes paraphrase of the referenced content
structurally impossible. Relevant anywhere we hand a brief to a spawned agent.

### E14 - Agent definitions front-load their rules `OPEN`
*Source: MCP (course 3), mechanism from Mastering Claude Code (course 8).* A five-trigger framing
plus a hierarchical context walk is a cheaper shape for the estate's per-directory conventions than
the current front-loading.

**Course 8 supplied the actual mechanism: `.claude/rules/`, one topic per file, with YAML front
matter carrying a `paths` glob so the file loads ONLY when Claude touches a matching file.** That is
conditional loading, which we had written down nowhere - `claude-code-craft` had been posing the
attention-budget problem since course 2 without an answer to it.

Direct fit here: the estate's conventions are already per-directory. `grocery/`, `meal-prep/`,
`graph/`, `ops/`, `site/` each have rules that are noise when you are working anywhere else, and the
root `CLAUDE.md` currently carries the lot. Splitting them into path-scoped rule files would shrink
the always-on load without losing anything.

Related timing fact worth knowing before restructuring: **only CLAUDE.md files at or above the
current working directory load at session start**; a subdirectory CLAUDE.md loads lazily. So a
`meal-prep/CLAUDE.md` costs nothing until someone works in there.

### E16 - Plugin hooks written in bash fail on Windows `WONTFIX` - measured, no estate change owed
*Source: Building Apps and AI Agents (course 9).* The `ralph-loop` plugin ships a Stop hook written
in bash, which **fails on this machine because `bash` resolves to WSL**. Not our bug, but it is a
standing hazard for any plugin we install: a plugin's hooks fire on every matching tool call, and a
broken hook on Windows is a silent failure surface. Check the hook language before installing
anything with hooks. Recorded in `claude-code-automation` 8.3.

**Ruled 2026-09-06 after measuring, and the recorded diagnosis was wrong for this machine.** From a
clean Windows process `Get-Command bash` returns **nothing at all**: `wsl.exe` is present but
`C:\Windows\System32\bash.exe` is not, and Git Bash sits at `C:\Program Files\Git\usr\bin\bash.exe`
without being on the Windows PATH. So a bare-`bash` hook here does not die with a WSL error, it dies
with command-not-found - and `where bash` succeeds only from *inside* a Git Bash session, which is why
checking from a terminal gives the wrong answer. No plugin is installed on this machine
(`~/.claude/plugins/` holds only the marketplace cache), so **no change is owed in this estate**. The
durable half was the regime note, which is now in `claude-code-automation` 8.3 as a three-row table;
the rule to carry is the conclusion (never let a plugin hook invoke a bare interpreter name), not the
WSL story that only holds on a different machine.

### E17 - Skill invocation flags are a matrix, and ours are all set the same `OPEN` `LOW`
*Source: Building Apps and AI Agents (course 9).* Invocation control is two independent flags, not
one switch: `disable-model-invocation: true` makes a skill user-only, `user-invocable: false` makes
it Claude-only. All eight of our personal skills set `user-invocable: true`.

**Deliberately not changed.** The cost of leaving it is seven extra entries in the slash menu; the
benefit is being able to force-load a reference on purpose ("load `rag-craft` before we design
this"), which is occasionally worth having. It does not suppress model invocation either way. Listed
so the decision is visible rather than accidental, not because it needs doing.

### E15 - "Ask for Input" for rules-first prompts `DONE` `8e3de6d9`
*Source: Prompt Engineering (course 4).* One statement, and it must come last. Fixes the annoyance
where a rules-first prompt invents its own first input instead of waiting.

---

## Infrastructure and hygiene

Found while running the programme; not course-derived.

### I1 - `~/.claude` is not under version control `OPEN`
294 KB across 17 skill files plus the global `CLAUDE.md` - seven courses of distilled learning - on
one disk, no repo, no remote. Snapshot taken 2026-09-06 to
`~/.claude/backups/skills-2026-09-06`, which protects against a bad edit but **not disk failure**.
Durable fix needs Brad's call: a private repo for `~/.claude`, or committing the skills into this
repo under a marked path (simpler, but creates two copies that drift).

### I6 - Bypass-permissions is opted in at the account level, with no sandbox under it `OPEN` `BRAD'S CALL`
*Surfaced by the Claude Cowork run (course 11), then verified directly rather than taken on its
word.* `%APPDATA%\Claude\claude_desktop_config.json` carries, for this account:

```
bypassPermissionsGateByAccount   = true
bypassPermissionsOptInByAccount  = true
coworkModelAutoFallbackByAccount = true
coworkBrowserToolsEnabled        = true
coworkScheduledTasksEnabled      = true
```

Confirmed by me: those five flags. **Still the agent's claim, not independently confirmed:** that
`C:\Codex` specifically is the granted folder, and that the VM sandbox is unsupported on this machine
(it reported `yukonSilver not supported` in `cowork_vm_node.log`). `coworkUserFilesPath` is
`C:\Users\Owner\Claude`, not `C:\Codex`, so the grant may be narrower than reported - worth checking
before acting.

Two separate things to decide, and both are Brad's:
1. **Bypass permissions with no sandbox** is the one mode the Claude Code course says belongs only
   inside an isolated container or VM. If the sandbox really is unavailable here, that condition is
   not met.
2. **`coworkModelAutoFallback` means a Cowork result is not attributable to a named model.** That
   matters anywhere we record which model produced a ruling - the estate pins models per agent
   precisely so results are attributable.

**Nothing changed.** Permission settings are not mine to alter, and this is listed to be ruled on.

### I2 - Stray artifacts at the repo root `DONE` `558321d5`
`3 cups sliced, for topping` (1 file) and `CodexThriftyCrewgroceryoutcaptures_sink` (empty - a
mangled `C:\Codex\ThriftyCrew\grocery\out\captures_sink`). Both look like path-construction bugs.
Untouched deliberately: something wrote them and may still be writing them, so find the writer
before deleting the evidence.

### I3 - `C:\Codex\CLAUDE.md` and `C:\Codex\Fantasy\CLAUDE.md` have no backup `OPEN`
Neither directory is a git repo. Same exposure as I1, smaller.

### I4 - Fantasy has 212 Python files and no version control `OPEN`
No branch to abandon, no diff to review, no undo. `git init` there is worth one conversation.

### I5 - Coursera enrollment lapsed on `building-with-the-claude-api` `OPEN`
Will not reinstate by clicking - three attempts. Course-specific, not account-wide. All content was
already extracted and routed; outstanding are 6 ungraded dialogues and that course's progress ticks.
Needs Brad to click enroll himself.
