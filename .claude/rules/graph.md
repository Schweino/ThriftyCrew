---
description: Rules for the identity graph, provenance and learning state.
globs: "graph/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `graph/`

Loaded only when you touch the identity graph, provenance or learning state.

- **A commodity id is NAMESPACED: `commodity:staple:<id>`.** The bare id returns an agreeing zero,
  which is the worst possible answer - it looks like a clean lookup.
  [[identity-graph-commodity-is-namespaced]]
- **Time gates are ad timing plus the 90-day quarter only**, and the window is read from
  `capture-policy.ps1`, never hard-coded. [[graph-time-gates-decision]]
- **Learning must be per-batch, not nightly** - check WHICH half before believing it is not learning.
  [[learning-must-be-per-batch-not-nightly]]
- **An agreeing number escapes scrutiny.** Run the check by rule, not by suspicion.
  [[an-agreeing-number-escapes-scrutiny]]

Regime: this holds for files under `graph/`.
