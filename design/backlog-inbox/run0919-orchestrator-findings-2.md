# Backlog run 2026-09-18, second batch: findings reported after the first merge

Collected by the orchestrator of the 2026-09-18 backlog run from item-agent reports that arrived after
I215 to I233 were merged. Nothing here was verified a second time by the orchestrator.

## The daily chain's recipe republish ships a stale card when its rebuild fails, and skips the allergen check
`OPEN` `run-0919` `1-WAY` `RUNG1 RULING`

Found by the agent that repaired wave-publish's P5 (I233). `grocery/check-ad-cycles.ps1:1165-1167` runs
`publish.ps1` whatever `build-cards` returned, so a card that failed to rebuild goes out as its stale version,
and that path bypasses `propagate-recipes.ps1`, so the allergen check I233's branch moves in front of publish
never runs there. The strongest repair (a per-recipe allergen refusal inside `engine\publish.ps1`) changes the
engine the daily chain runs, which is why it is a ruling. Read with I233.

## The graph importer drops about 238,000 Baker's rows every run because their search term is a commodity id
`OPEN` `run-0919` `2-WAY` `RUNG1 MEASURE`

Found under I229. `graph/import/importers.py:848` resolves only through search-term aliases. Of 244,512 rows
whose term is not a known alias, 231,793 carry a staple commodity id instead of a search term, and 237,937 are
Baker's. They are dropped on every nightly import. Resolving them adds observations and could move graph
prices, so the first rung is to measure what they would change. Related: `importers.py:587` builds
`observed_at` from the file name, so `fareway-shop-rescue-2026-09-10.json` stored 8 rows with
`observed_at='rescue-2026-09-10'` (the freshness clock already treats it as future, so it is not fooled).

## Committed task XML disagrees with the registered tasks, and one live task is not in the automation registry
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

- `ops/install-grocery-tasks.ps1 -Verify` exits 2 with 6 findings (I230): the live `TC Grocery Daily Capture
  0800` and `Capture Watchdog 1030` run through `conhost.exe --headless`, but the committed XML still calls
  `powershell.exe` directly.
- `TC Approvals Page` has been flagged by every heartbeat since 2026-09-13 as not listed in
  `grocery/expected-automations.json` (I225).
- Graph nightly repeats hourly 21:30 to 05:30 with a 3 h limit; only `-HardStop 06:30` keeps the 05:30 launch
  out of the 07:00 capture, and whether the in-flight stage actually stops is unchecked (I213).

## Push and gate papercuts that cost every session a retry
`OPEN` `run-0919` `2-WAY` `RUNG1 BUILD`

- An unseeded worktree's `feed-covers-published` BLIND case is counted as a new failing case by
  `prepush-test-auditors`, and `push-main` does not seed before gating, so most first pushes today were
  refused once for a reason unrelated to the change (I230, I231).
- `ops/hooks/pre-push:339`'s refusal text still says the gate budget is 10 (it is 24 since 39be9900e); changing
  the hook needs `ops\install-hooks.ps1` in the same breath or capture-watchdog alerts daily (I230).
- `ops/audit-list-array-wrap.ps1` cannot see a wrap of a property, `@($x.field)`, the exact shape that broke
  match-soundness on 6 chain runs (I232).
- `ops/seo_url_inspect.py` prints only the earliest and latest crawl date, while I44's re-check needs the date
  per URL (I44).

## Unverified leftovers
`OPEN` `run-0919` `2-WAY` `RUNG1 READ`

- Branch `claude/youthful-mirzakhani-eef33c` holds three more unlanded commits (59b25fb61 Hy-Vee pin scan,
  17777dd5e feed-freshness probe name, fc2fae0a2 capture-evictions), probably superseded by main (e.g.
  345a515be); unverified (I195).
- `ops/member-cohorts.ps1:477-496` pages Ghost members at 500 and stops at the first short page, recording
  `lastPages` and never checking it; a server cap below 500 would undercount silently. Needs one read-only call
  to settle (I197).
