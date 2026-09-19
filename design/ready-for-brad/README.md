# Ready for Brad

Files here are prepared changes that need one action from Brad, because landing them any other way is refused
by a gate or is his call. Each is named after the item it belongs to. Delete the file once it has been applied.

## grocery-browser-stores-refresh.SKILL.i124.md (backlog I124, 2026-09-18)

The Fareway store-stamp paragraph for the 09:00 browser runbook (four lines after "Emit JSONL ...
fareway-shop-<date>.jsonl"). `audit-prompt-backup` fails every push while the live scheduled-task SKILL.md and
its repo copy differ, so both copies must change together. From the main checkout:

    Copy-Item design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md C:\Users\Owner\.claude\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md
    Copy-Item design\ready-for-brad\grocery-browser-stores-refresh.SKILL.i124.md ops\prompt-backup\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md

then commit the prompt-backup copy and delete this file. Until then an attended Fareway rescue that uses an old
in-page copy of the extractor is refused with a message telling the operator to reload pull-fareway-shop.js.

## I60-lesson-republish.md (backlog I60, 2026-09-19)

The before and after of the three finance lessons (30, 31, 37), the checks, and the commands that swap only the
changed passages into the live posts. Nothing is republished until you run them.
