# L3, measured: the speed work targets the wrong 16 seconds

**2026-08-02.** L3 asked for a DuckDB cache for "the repeated multi-MB JSON parses" and a PS7 consolidated
runner for "the watcher suite's process-spawn overhead". Both are real inefficiencies. Neither is where
the time is, and the plan's own ranking already suspected as much: *"Speed last, because the measured
pipeline is already fast enough that nobody but the machines notices."*

This is the measurement that closes the item. Nothing was built, on purpose.

## Where the daily run's 42 minutes actually go

`check-ad-cycles` on 2026-08-02 ran 08:31:00 to 09:12:50, **41.8 minutes**. Eleven gaps of 20 s or more
account for **39.1 of those 41.8 minutes**, and the top three account for 29.2 minutes on their own:

| gap | what was running |
|---:|---|
| **734 s** | the Hy-Vee Aisles Online GraphQL pull (1,538 products, 939 refreshable by link) |
| **588 s** | the Baker's Kroger API pull + link-snapshot sync |
| **429 s** | the board publish (share image render, then the Ghost upsert) |

**All three are waiting on somebody else's server.** They are network-bound and rate-limited by the
stores; no local cache, no faster JSON reader and no consolidated runner moves them by a second. The only
levers that would are fewer calls or concurrent ones, and both are accuracy decisions about pull depth
rather than speed work. See the pull-depth findings for why "fetch less" is not free here. **The memory that held them is GONE** - cited here as `pull-depth-findings`, no file and no near match in the store as of 2026-09-06, found by `ops/audit-memory-citations.ps1` on its first run. Treat the sentence above as the whole of what survives.

## What the two proposed optimisations are actually worth

**DuckDB, for the JSON re-parses.** One pass over the five largest files the pipeline reads:

```
out\comparison-2026-08-01.json           3,112 KB   0.15 s
price-history.json                       9,365 KB   0.21 s
out\regular\family-fare-regular-*.json   3,586 KB   0.10 s
commodities.json                         2,151 KB   0.04 s
product-urls.json                        2,129 KB   0.04 s
                                    one full pass   0.54 s
```

The 4.7 s figure this item was written from must have been a cumulative count across many re-reads, or it
predates a file that has since shrunk. Caching every one of these perfectly, on every re-read, saves a few
seconds inside a 2,508-second run.

**PS7, for the process spawns.** `test-auditors` runs **386 checks in 106.8 s** through **114 child
processes** (93 `RunPS` plus 21 direct). A no-op PowerShell child costs **96 ms**, so the spawn overhead is
**≈11 s — about 10% of the suite**, once a day. Consolidating it means rewriting 114 call sites, each of
which is currently isolated from the others by process boundaries. That isolation is not incidental: the
suite's whole job is to keep running after one watcher dies, and this estate has already been bitten by a
single child's stderr killing a parent under `$ErrorActionPreference='Stop'`. **The memory that held this is GONE** (cited here as `logger-kills-pipeline`, no file as of 2026-09-06), but unlike the one above THE FACT SURVIVED elsewhere: `C:\Codex\CLAUDE.md` carries "avoid `2>&1` on native exes - it fakes a failure at exit 0", and `ops/run-gates.ps1` carries the long-form version at both of its child-process calls, naming the three guards it has already bitten. Read those rather than trusting this pointer.
Trading that isolation for 11 s a day is a bad trade.

## The honest total

Both optimisations, executed perfectly, save **roughly 16 seconds** across a 42-minute daily run and a
107-second test suite — while 70% of the daily run is blocked on grocery-store APIs. **L3 is closed as
measured-and-declined.** If speed ever becomes the constraint, the measurement above says to start at the
Hy-Vee and Baker's pulls with concurrency, not at the JSON reader.

Reproduce: the stage timings come from parsing `grocery\ad-cycle-log.txt` timestamps for one day and
taking the gaps; the parse costs from timing `Get-Content -Raw | ConvertFrom-Json` on each file; the spawn
cost from ten no-op children.
