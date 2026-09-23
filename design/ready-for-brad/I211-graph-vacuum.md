# One VACUUM of graph.db (backlog I211, 2026-09-19)

## What Brad does

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
