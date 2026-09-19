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

## produce-condiment-exclusion.md (Brad's "Fix all produce" ruling, 2026-09-19)

The condiment class (aioli, mayo, squeeze, dip, dressing, spread) is already on main for 114 of 116 produce
commodities; the live board was built ten minutes before it landed. The file has the paired diff (1 cell is this
rule), the full rebuild diff (80 cells), and the one command that rebuilds the live board.

## I60-lesson-republish.md (backlog I60, 2026-09-19)

The before and after of the three finance lessons (30, 31, 37), the checks, and the commands that swap only the
changed passages into the live posts. Nothing is republished until you run them.

## lessons/ (backlog I108, I109, I111, 2026-09-19)

Three lesson drafts Brad ruled on 2026-09-19 (insurance basics, the emergency fund, the personal balance sheet),
with their HTML bodies, the three cross-link lines, and the exact publish commands in `lessons\README.md`.
Nothing is published until Brad runs them.

## One VACUUM of graph.db (backlog I211, 2026-09-19)

The importer no longer re-inserts, every run, the rows the last prune deleted (477,950 inserted and 477,950
pruned per run before; 187 and 187 after, measured on copies). So graph.db stops climbing, but the 165 MB of
empty pages the old churn left behind stay in the file until one VACUUM hands them back. That is the one step.

When: after the new importer has run once (the daily chain's graph import, about 08:15), in the quiet window
between that import and 21:30 (TC Graph Nightly Matching runs 21:30 to 06:30). Not while any python.exe is
writing graph.db; if one is, the script refuses with "VACUUM refused, nothing changed" and you just run it later.
It needs about 150 MB of free disk. From the main checkout:

    C:\Codex\Python312\python.exe graph\pipeline\vacuum_graph_db.py            # report only: pages and freelist
    C:\Codex\Python312\python.exe graph\pipeline\vacuum_graph_db.py --apply    # the VACUUM, with its proof

It must end `VACUUM-GRAPH-DB-COMPLETE ok=True applied=True`, with `integrity_check ['ok']`,
`row_counts_identical True` and `freelist_after 0`; anything else exits 1. What to expect, measured on a
backup-API copy carrying the new importer's steady state: 323,358,720 B before (78,945 pages, 38,599 free), about
143,343,616 B after (34,996 pages) in about 1 second, and two more full imports afterwards left it at 145,444,864
and 145,637,376 B. The live file will differ a little by the day you run it.
