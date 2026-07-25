# Recipe expansion run playbook (model-routed, zero /model flips)

Brad's requirement (2026-07-25): he should never have to remember to flip models mid-run. The routing
lives in the AGENT definitions (C:\Codex\.claude\agents\), each pinned to its model. Whatever model the
main session is on, the orchestrator dispatches stages to these agents and each runs on its own brain.

No seafood recipes: seafood is expensive per serving and nobody has asked (Brad, 2026-07-25).

## Stage routing

| Stage | Who runs it | Model | Why |
|---|---|---|---|
| 1. Source candidates from the internet (fan out N slices by cuisine/protein/method) | **recipe-sourcer** (parallel) | **opus** | breadth research; returns structured candidates + source URLs; selector culls |
| 2. Normalize ingredients -> canonical worklist | scripts + main session | any | mechanical (normalize-recipe-ids.ps1 is idempotent) |
| 3. NEW ingredient mapping + food-DB entries | **recipe-ingredient-mapper** | **fable** | accuracy-critical; evidence-gate judgment; label transcription |
| 4. Scale to 14 servings, macros, 550 gate, pricing | scripts (r100 pipeline) | any | the gates do the checking |
| 5. Prose + card assembly (fan out slices) | **recipe-writer** (N in parallel) | **opus** | volume; numbers are transcribed, never computed |
| 6. Pre-publish batch audit | **recipe-batch-auditor** | **fable** | adversarial full-batch review; GO / NO-GO |
| 7. Publish + verify live + push + memory | main session | any | scripted, verified |

## How to start a run

Tell the session: "start a recipe run for N recipes" (optionally: theme/constraints). The session follows
this playbook, reuses the r100 pipeline in meal-prep\r100\ (see recipe-r100-expansion memory for the
engine gotchas: $Matches clobber, rule order), and dispatches stages 3/5/6 to the pinned agents by name.
Stage 6's NO-GO blocks publish, full stop.

After ANY batch lands in recipes-db: run meal-prep\normalize-recipe-ids.ps1 (stamps item_id + protein;
the free-dinner rotation and the hub Top 5 read the protein field and must stay set-identical).
