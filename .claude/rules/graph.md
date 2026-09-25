---
description: Rules for the identity graph, provenance and learning state - one line each; the account is graph-depth.md.
---

# Graph rules, one line each

LEAD FILE: loads in every ThriftyCrew session, because it has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3 option B, D2). The account behind each line, with
its dates and measurements, is `.claude/rules/graph-depth.md`, which loads only after a session reads a file under
`graph/`. A `[[name]]` is `~/.claude/projects/C--Codex-ThriftyCrew/memory/<name>.md`: read it, never write it.

- A commodity id is NAMESPACED, `commodity:staple:<id>`: a bare id returns an agreeing zero that looks like a clean lookup. [[identity-graph-commodity-is-namespaced]]
- Time gates are ad timing plus the 90-day quarter only, with the window read from `capture-policy.ps1`, never hard-coded. [[graph-time-gates-decision]]
- Learning must be per-batch, not nightly: check WHICH half is not learning before believing it. [[learning-must-be-per-batch-not-nightly]]
- An agreeing number escapes scrutiny: run the check by rule, not by suspicion. [[an-agreeing-number-escapes-scrutiny]]
- A graph.db that EXISTS may hold no nodes: ask whether it holds `Commodity` nodes before resolving one, and score a no as BLIND (counted, never ok, never a failure); copy `_index_blind` in `graph/bench/priors_ablation.py`.

Regime: this holds for files under `graph/`.
