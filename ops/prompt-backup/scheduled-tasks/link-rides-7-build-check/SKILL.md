---
name: link-rides-7-build-check
description: Re-measure the link-rides-with-price bars on the real daily boards and start L3/L6/L7 only if they hold.
---

Project: C:\Codex\ThriftyCrew (read its CLAUDE.md and .claude/rules first; work in a worktree under .claude\worktrees, land only through ops\push-main.ps1, commit messages via -F with a Store: line and a Plan: line).

Brad ruled on 2026-09-27 (D6 in design/PLAN-link-rides-with-price-2026-09-27.md): after 7 clean daily builds with the tile link (L1 landed 2026-09-27; first daily build with it 2026-09-28), re-measure the plan's bars on the REAL daily boards and start L3/L6/L7 only if they hold.

Do this:
1. Read design/PLAN-link-rides-with-price-2026-09-27.md in full (work items L1-L7, Bars, Decisions D1-D6).
2. For each daily comparison board 2026-09-28 .. today (grocery/out/comparison-*.json in the MAIN checkout, read-only) plus grocery/out/recipe-board.json, count per store: priced tiles by link_source (row/none/flyer/ad). Report storefront linked N of M per board (bar: at least 97%), and whether any build was missing or had no link_source. One row per board per store; derive totals from the rows.
3. Check the backlog (grocery/out/url-worklist.json): every entry is none (with a capture file) or ad.
4. Check audit-tile-integrity and guards link failures did not rise over those builds (read the daily logs / check-ad-cycles output).
5. If every bar holds for 7 builds: write a short plan addendum and start L3 (link checks judge identity for row links), then L6 (retire product-urls.json outright per D2 and the bridge scripts, one commit each with audit-script-census evidence of no remaining caller), then L7 (one per-unit engine, paired run showing identical per_unit on every tile before pu-lib retires). Gate every push with run-gates.
6. If any bar misses: do NOT start L3/L6/L7. Write what missed, by how much, over how many builds, into the plan and a design/ready-for-brad/ file, and stop.
7. Also check D5: whether the Hy-Vee flyer linker (grocery/hyvee-flyer-link.ps1, design/PLAN-flyer-line-product-link-2026-09-26.md) has gone live and whether Family Fare was added to it; report its status, do not change it.

Report to Brad in plain language: what held, what missed, what you started, what needs him. Never fabricate a number; every rate with its denominator.