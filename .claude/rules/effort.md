---
paths:
  - ".claude/agents/**"
---
# Choosing effort

Loaded when an agent definition under .claude/agents is touched, where effort is pinned. Full account and source: `docs/EFFORT-GUIDE.md`.

- **Effort buys verification and edge-case testing, not a better approach.** Raise effort where edge cases are
  hidden or no human is in the loop (review, audits, brownfield bug fixes, money-path checks). When the approach is
  wrong, fix the plan or spec instead; more effort only verifies the wrong thing harder. (channel: judgement)
- **Plan and verify high, implement medium, iterate low.** For feature work: interview for the spec, implement at
  low or medium, review the gist, then verify at high. An agent's pinned `effort:` changes only by Brad's ruling.
  (channel: judgement)
