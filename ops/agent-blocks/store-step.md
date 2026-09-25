# The store-step, canonical text

This file is the ONE copy of the store-step: the block that tells an agent or a scheduled task to search the
knowledge store before it works, and to say what it used. Every carrier pastes a variant below byte for byte,
begin and end markers included, and `ops/audit-agent-tools.ps1` RULE 3 holds every copy identical to this file
on every push. It is not under `ops/prompt-backup/`, because that directory is a managed mirror of live prompts
and this is the source they are pasted from.

**To change a variant:** edit it here, then paste the new span into every carrier IN THE SAME COMMIT, run
`powershell -NoProfile -File ops\audit-prompt-backup.ps1 -SyncMirror` so the agent mirrors follow, and read
`ops\audit-agent-tools.ps1` exit 0. A carrier that is a live scheduled-task SKILL.md changes through procedure
P3 of `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md` (section 4.6), never from a worktree.

Two variants (plan W5.2):

- **CODE** is for a context that designs or changes code. It is the 2026-09-18 text with two lines replaced:
  the command is the plan's section 4.7 string (the old `%USERPROFILE%` form failed in both shells when
  launched without cmd, and its backslash interpreter path failed in Bash with exit 127), and the Store:
  example is W0.1's, which resolves since W0.1 landed.
- **ANALYSIS** is for a context that diagnoses, measures, compares, audits or returns a verdict.

Which agent carries which variant, and which are allow-listed and why, is declared in
`ops/audit-agent-tools.ps1` (`$STORE_STEP_REQUIRED` and `$STORE_STEP_ALLOW`), beside the rule that enforces it.
W3.4 added `--estate` to both variants, here and in every copy together, on 2026-09-25, after W3.3's bar held
(10 of 16 "nothing applicable" commits got a relevant rules, memory or machinery section back, against a bar of 5).

<!-- store-step:CODE begin (canonical: ops/agent-blocks/store-step.md) -->
## SEARCH THE KNOWLEDGE STORE BEFORE YOU DESIGN OR CHANGE CODE (Brad, 2026-09-18)

The knowledge store holds the engineering rules this estate has already paid for: `~\.claude\skills\`
(one folder per subject, each with a `MAP.md`) and the memory directory
`~\.claude\projects\C--Codex-ThriftyCrew\memory\`. No skill content reaches you unless it is written
here, so this is the step. **Before you write a plan item, a fix or a finding that proposes code, search:**

    C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>"

One term at a time widens it; `--multi a b c` probes each. Open what it returns and read the section.
Then **say what you used**: a plan or report carries a `Knowledge consulted` section listing the terms you
searched and each store file you used (or "searched <terms>: nothing applicable"), and **every commit that
changes code carries a `Store:` line** - for example
`Store: .claude/rules/ops-and-gates.md ("A catch around a native redirect is not a guard"); lib/atomic-write.ps1 (reused)`, or
`Store: searched "regex timeout", nothing applicable`. The commit-msg hook checks that each named file
exists (warns until 2026-09-25, refuses from then), and `ops/store_citation.py` is the rule. Measured the
day this was added: a backlog run made dozens of code fixes with zero searches, while the one fix that
searched first came out with a better design because of what it found.
<!-- store-step:CODE end -->

<!-- store-step:ANALYSIS begin (canonical: ops/agent-blocks/store-step.md) -->
## SEARCH THE KNOWLEDGE STORE BEFORE YOU DIAGNOSE OR JUDGE (Brad, 2026-09-22)

Before you diagnose, measure, compare, audit or return a verdict, search:
`C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>"`.
Say what you used in a Knowledge consulted section of your report or verdict file, or
`searched "<terms>", nothing applicable`.
<!-- store-step:ANALYSIS end -->
