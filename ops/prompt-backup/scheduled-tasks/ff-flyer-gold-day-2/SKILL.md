---
name: ff-flyer-gold-day-2
description: Collect the remaining Family Fare flyer lines and propose their labels for Brad's review.
---

Project: C:\Codex\ThriftyCrew. Read its CLAUDE.md and .claude/rules first. Work in a NEW worktree under .claude\worktrees (never the main checkout), land only through ops\push-main.ps1, commit messages written to a file and used with -F, with a Store: line and a Plan: line (Plan: design/PLAN-link-rides-with-price-2026-09-27.md D5). Run measurements against copies in your scratch folder, never over files in the worktree you land from.

Job: finish the Family Fare flyer-line labelled set that day 1 (2026-09-27, commit a93b33dd0) started. Brad ruled D5: extend the existing flyer linker (grocery/hyvee-flyer-link.ps1) to Family Fare; this set is what it will be scored on.

1. Board: the newest grocery/out/comparison-2026-09-28.json in the MAIN checkout (read-only; copy it to your scratch folder). Check it carries link_source on its tiles; if not, stop and report BLIND.
2. In your worktree run: powershell -NoProfile -File grocery\familyfare\collect-flyer-link-evidence.ps1 -Board <scratch copy> -Evidence grocery\familyfare\flyer-link-evidence-2026-09-27.jsonl
   It skips lines already collected and retries failed ones, 30 searches max (Freshop's daily budget). Read its exit code and COMPLETE line.
3. Then: C:\Codex\Python312\python.exe grocery\familyfare\label_flyer_gold.py grocery\familyfare\flyer-link-evidence-2026-09-27.jsonl grocery\familyfare\flyer-link-gold.jsonl
4. Read every NEWLY proposed label against its candidate rows by eye (name equals the line, sale text equals the flyer). Report any you disagree with; do not edit labels by hand.
5. Gate (ops\run-gates.ps1, exit code first), commit those two data files, land via push-main.
6. If lines remain uncollected, say how many; they continue the next day.
7. Tell Brad in plain language: how many lines are now labelled, how many UNSURE, and that the set is ready for his review in grocery/familyfare/flyer-link-gold.jsonl (every row says "proposed, awaiting Brad review"). Every count with its denominator. Never fabricate a number.