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

---

## Safety and correctness

### E1 - The estate takes irreversible actions with no safety layer `OPEN`
*Source: AI Agents Architecture (course 7).* Board cells, `known-wrong` rulings, Ghost publishes
and R2 writes are all irreversible from an agent's side, and **`post-publish-reviewer` runs after
the irreversible step**, which is the wrong side of it. Two cheap patterns: **staging** (reads
execute, writes queue for a review pass) and an **action log that doubles as an undo log**, with a
`revert` tool the agent may choose itself. Touches every writing agent and the publish chain.
Biggest item on this list.

### E2 - Bare numeric codes cross agent boundaries `OPEN`
*Source: AI Agents in Python (course 6).* "An agent that receives error 32 is finished." Our gate
exit codes are exactly that shape. Anywhere a gate's exit code reaches an agent without a
words-level translation is a place an agent retries identically or invents a meaning. Grep for it.
Note the irony: while adding D2 I put "exit 2" into five agent prompts and had it wrong -
`run-gates` uses exit 3, the recipe battery uses 2. Corrected in `6a05dcd7`, but that is the exact
failure this item is about.

### E3 - Tool-list relevance hazard across twelve agent definitions `OPEN`
*Source: AI Agents in Python (course 6).* Given three well-named tools and no usage context, the
course's agent decided the unnecessary one must be needed and **invented bolts and screws to justify
it**. Several of our agents ship long tool lists with no statement of which are optional, how they
relate, or whether all must be used. `recipe-hunter-pricer` carries about twenty. Cheapest fix is a
sentence per agent naming which tools are situational.

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

### E7 - `.worktreeinclude` `OPEN`
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
*Source: MCP (course 3).* A five-trigger framing plus a hierarchical `.context.md` walk is a
plausibly cheaper shape for the estate's per-directory conventions than the current front-loading.

### E15 - "Ask for Input" for rules-first prompts `OPEN`
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

### I2 - Two stray directories at the repo root `OPEN`
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
