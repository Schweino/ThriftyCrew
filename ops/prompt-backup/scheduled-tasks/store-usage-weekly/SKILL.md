---
name: store-usage-weekly
description: Weekly: is the knowledge store being applied to code and design? Reports search, cite and backing rates against the written bar.
---

Run the weekly knowledge-store usage report and summarise it for Brad in a short plain-language TL;DR (no em dashes, no file paths in the summary).

1. Run: C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\store-usage-report.py --days 7
   Read the EXIT CODE first. Exit 3 means it could not read the logs (BLIND): say so, and do not report any rate.
2. Report, each with its denominator: judged code commits; how many carried a Store: line backed by a logged search, against the 80% bar; of those, how many cited a real store file, against the 50% bar; how many were warned or refused and the top reasons; how many sessions committed code without searching at all.
3. Open 3 of the "read these" cited commits in C:\Codex\ThriftyCrew (git show) and say plainly for each whether the cited store section visibly shaped the change or looks like a box-ticking citation. This is the half no number sees.
4. The commit check in ThriftyCrew's ops/store_citation.py warns until 2026-09-25 and refuses from then (REFUSE_FROM). If the flagged reasons show it refusing commits that genuinely needed no store knowledge, say so and recommend whether to keep or move that date. Never change the date, the rule or any gate yourself; that is Brad's call.
5. Change nothing. This task only reads and reports.