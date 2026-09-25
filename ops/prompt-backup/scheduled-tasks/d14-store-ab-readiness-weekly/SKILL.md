---
name: d14-store-ab-readiness-weekly
description: Weekly: checks whether first-write refusals have run 14 days with at least 80% of contexts searching first (M1b); when they have, brings Brad the D14 A/B design.
---

Weekly check for Brad's D14 ruling of 2026-09-25 on design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md (C:\Codex\ThriftyCrew): "Yes, bring it back when 80% clears (Recommended)". D14 is the decisive store A/B (about 60 build plus 60 judge sessions, per the plan's section 7 note and design/MEASURE-store-ab's sizing) that measures whether the knowledge store improves the WORK, not only whether it was used. It may start only after M1b clears.

1. Read C:\Users\Owner\.claude\skills\recall-first-write-mode.json. If the mode is not "deny", say in one line that D14 is still waiting on refusals (D3) and stop; change nothing.
2. If it is "deny", run `C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\first-write-report.py` to a file, read the exit code and FIRST-WRITE-REPORT-COMPLETE line first, and read M1b over DENY-MODE contexts. The bar, fixed in the plan's section 7 before any data: M1b at least 80% after 14 days of deny, with N printed. State how many days deny has run (from the mode file's commit date in `git -C C:\Users\Owner\.claude log -- skills/recall-first-write-mode.json`).
3. If the bar does not clear yet, say where it stands in one line (N of M, days of deny) and stop.
4. If it CLEARS: write Brad a concrete D14 design to decide on: which real ThriftyCrew tasks are split between a store-on and a store-off arm, how each arm is isolated, how quality is scored (bugs found in review, verdicts later proved wrong, redo rate) with the acceptance bar written in those units before any run, one row per case per arm, the harness and blob it will run at, and the cost in sessions. Put it in design/ as a MEASURE or PLAN file, commit with a pathspec (Store: line, `Plan: design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md D14`, `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), land with `powershell -NoProfile -File ops\push-main.ps1` (never between 06:30 and 09:00, never bypass a gate), tell Brad, and then disable this task with update_scheduled_task (enabled false) so it stops checking.

No em dashes. Never run the A/B itself: Brad decides from the design.

## Knowledge consulted
- The plan's section 7: "M1b | editing contexts that searched before their first in-scope write that was NOT denied | at least 80% after 14 days of deny, N printed" and "A decisive answer needs about 60 build and 60 judge sessions (MEASURE-store-ab's own sizing). That is D14, after M1b clears."
- memory:one-agent-run-is-not-evidence-about-a-process: same-arm runs differed as much as store against no store, which is why the sample is 60 per arm.
- .claude/rules/measurement.md: "Write the ACCEPTANCE BAR before the run", "Write ONE ROW PER CASE PER ARM", "NAME THE HARNESS AND THE COMMIT IT RAN AT".