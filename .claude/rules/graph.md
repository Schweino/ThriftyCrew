---
description: Rules for the identity graph, provenance and learning state.
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `graph/`

Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3).

- **A commodity id is NAMESPACED: `commodity:staple:<id>`.** The bare id returns an agreeing zero,
  which is the worst possible answer - it looks like a clean lookup.
  [[identity-graph-commodity-is-namespaced]]
- **Time gates are ad timing plus the 90-day quarter only**, and the window is read from
  `capture-policy.ps1`, never hard-coded. [[graph-time-gates-decision]]
- **Learning must be per-batch, not nightly** - check WHICH half before believing it is not learning.
  [[learning-must-be-per-batch-not-nightly]]
- **An agreeing number escapes scrutiny.** Run the check by rule, not by suspicion.
  [[an-agreeing-number-escapes-scrutiny]]
- **A graph.db that EXISTS may hold no nodes** (2026-09-23). `graph/lib/rebuild.py`'s plain mode
  restores only the five learning tables, by design, and `design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md`
  W6.4 sends worktrees down that road, so `question_verdicts` names commodities the index cannot compile.
  A check that reads graph.db when it is present asks whether it holds `Commodity` nodes before resolving
  one, and a no is BLIND: counted, never ok, never a failure. `_index_blind` in
  `graph/bench/priors_ablation.py` is the exemplar; its self-test red a push over exactly this.

Regime: this holds for files under `graph/`.
