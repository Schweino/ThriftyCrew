# grocery-browser-stores-refresh.SKILL.i124.md (backlog I124, 2026-09-18)

## What Brad does

The Fareway store-stamp paragraph for the 09:00 browser runbook (four lines after "Emit JSONL ...
fareway-shop-<date>.jsonl"). `audit-prompt-backup` fails every push while the live scheduled-task SKILL.md and
its repo copy differ, so both copies must change together. From the main checkout:

    Copy-Item design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md C:\Users\Owner\.claude\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md
    Copy-Item design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md ops\prompt-backup\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md

then commit the prompt-backup copy and delete BOTH `design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md`
and this file. Until then an attended Fareway rescue that uses an old in-page copy of the extractor is refused with a
message telling the operator to reload pull-fareway-shop.js.

**Re-staged 2026-09-24** (design\backlog-inbox\pd-index-2026-09-23.md, first finding). The file staged on 2026-09-18
predated six commits to the live prompt's mirror (Brad's 2026-09-19 four-stores-at-06:15 ruling, the capture sink's
absolute `-OutDir` warning, the 2026-09-22 sale-fallback change), so the two `Copy-Item` lines above would have
reverted all six. The staged file is now the mirror as committed on origin/main at that date with ONLY the four-line
stamp paragraph inserted. Before copying, check the mirror has not moved again since: the command below must print
the four added lines and nothing else.

    git diff --no-index ops\prompt-backup\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md
