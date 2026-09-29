---
name: recall-cluster-rulings
description: Weekly: rule every unruled memory cluster (gist / distinct / cued / defer) so the nightly knowledge pass never goes red over them
---

You are the weekly owner of memory-cluster rulings for Brad's knowledge store (~\.claude, its own git repo). Brad's ruling of 2026-09-28: this task rules clusters so the nightly pass (skills\recall-sleep.py, 04:35) stops paging him. An unruled cluster has GRACE_DAYS = 7 (skills\recall-consolidate.py) before it counts against the mark and turns the nightly pass RED, so every run of this task must finish with zero unruled clusters, or say exactly why not.

Python is C:\Codex\Python312\python.exe (bare `python` is not the interpreter). Shell is PowerShell 5.1 (no && or ||). No em dashes in anything you write. Search before you write: C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>".

STEPS
1. List: `C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\recall-consolidate.py` (read-only). It prints each UNRULED cluster (key, store, target skill domain, member memo names) and IN GRACE lines. Read the file's header and its VALID rulings and TIER1_REFUSAL text once.
2. For each unruled cluster, read every member memo (~\.claude\projects\<store>\memory\<name>.md) and the target domain's MAP.md / applies-here.md. Decide ONE ruling:
   - gist: the members teach one lesson that belongs in a skill (tier 2, under ~\.claude\skills\). Write that lesson under a new heading in the target file (usually <domain>\applies-here.md; create it with a one-line purpose header if missing), keeping every number, date and file path the memos carry, and citing each member. Never write a gist into CLAUDE.md or any .claude\rules file (tier 1).
   - distinct: they are neighbours by wording but different lessons; say in one line what separates them.
   - cued: the lesson is already carried by a tier-1 pointer plus a whole memory; fading would empty the account.
   - defer: ONLY when the decision is genuinely a business preference of Brad's, not an engineering fact. Name the question.
   Then record it: `recall-consolidate.py --rule <key> <gist|distinct|cued|defer> "<one-line reason>"` and, for gist, `--domain <skill dir>` (or `--target skills/<path>`) and `--heading "<the heading you wrote>"`; add `--members a,b` only to fade a subset.
3. Apply and converge: run `recall-consolidate.py --apply`, then the plain run again. Fading changes the graph and new smaller clusters can form; repeat steps 2-3 until the plain run prints no UNRULED cluster (it converged 23, 6, 2, 0 on 2026-09-07). Cap: 4 rounds.
4. Verify: `recall-consolidate.py --selftest` exits 0, and `C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\check-skills.py` shows no recall-consolidate FAIL line. Read exit codes before tallies.
5. Commit in ~\.claude with a PATHSPEC commit naming only the files you changed (the skill files you wrote, skills\recall-consolidations.json, skills\recall-cluster-first-seen.json, and the faded memo files): write the message to a temp file with [IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false))) and run `git -C $env:USERPROFILE\.claude commit -F <file> -- <paths>`, then `git show --stat HEAD` to confirm it holds only your paths. Never `git add -A`; other sessions share this index. End the message with: Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
6. Only if a cluster is left unruled or deferred: send ONE email with `powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\send-alert.ps1 -Subject "Memory cluster needs Brad's ruling" -BodyFile <file> -Emitter "scheduled-tasks/recall-cluster-rulings"`, body = each cluster key, its members, the question, and the consequence of each option. Otherwise send nothing.

REPORT (under 12 lines): clusters found, each ruling with its key, what was gisted where, rounds to converge, the commit hash, and anything left for Brad.