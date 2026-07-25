# R300 run state (started 2026-07-25)
Goal: +300 recipes, evening the 4 proteins. Census at start: chicken 69, beef 55, pork 50, turkey 37 (+2 other).
Targets: turkey +90, pork +78, beef +73, chicken +59 (=300; ~128 each final).
Pipeline: NEXT-RUN-PLAYBOOK.md stages; r100 pipeline reused; agents pinned (sourcer/writer=opus-4.8 high, mapper/auditor/reviewer=fable high).
No seafood. Publish in batches; auditor GO required per batch; post-publish-reviewer after every publish.

## Stage 1: sourcing wave (10 slices) - IN FLIGHT
Slices: T1-T3 turkey (135 target), P1-P3 pork (120), B1-B2 beef (100), C1-C2 chicken (90). ~445 candidates for 300 slots.
Output: candidates/<slice>.json
