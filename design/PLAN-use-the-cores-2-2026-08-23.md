# PLAN — use the cores, part 2: the whole estate

**Status: PROPOSED, 2026-08-23 evening. Plan only — no code has been changed for this document.**
Brad's objective, stated plainly: *everything that can use up to 8 cores should, and "everything" means
the estate, not the one chain the first plan scoped.* This document is the full map, every process
classified, with the number that justifies each verdict where one exists and an honest "unmeasured"
where it does not.

Part 1 (`PLAN-use-the-cores-2026-08-23.md`) covered one chain and got four things wrong that this
document inherits corrections for. The method here is the same one that found those: read the
scheduled entry points, read the logs those runs actually wrote, and do not trust a comment, a grep, or
a profiler number over a wall-clock timestamp.

---

## 0. The three shapes of "serial", and which one this estate has

1. **A script that launches several distinct children one after another.** `fanout-lib.ps1` solves
   this and is proven on 34 lanes. Cheap to apply wherever the children are independent.
2. **A loop that makes one network call per item.** `discover-hyvee`'s resolve → fetch → judge split
   solves this. Cheap to apply, but every instance is a call against a **third party's API**, and the
   cap is a vendor-relationship decision, not a tuning knob.
3. **Work that is serial because it must be** — mutators, publishers, hard gates, paced browser
   sessions. These are listed so nobody "optimises" them; each has a reason.

The first plan only looked for shape 1 in one file. This one looks for all three everywhere.

---

## 1. The map: every scheduled process, classified

### 1.1 `TC Grocery Daily Capture 0800` — `capture-run.ps1 -Kind daily` → `check-ad-cycles -NoPull`

The main event. Measured today, 2026-08-23, from the run's own transcript and log:
**08:00:02 → 08:29:09, 29.1 min wall.**

| stage | wall | parallel today? | verdict |
|---|---|---|---|
| 3 API store lanes (FF / Hy-Vee / Baker's) | ~100 s, bounded by FF | **yes** — `Start-Job`, 3 lanes | inner loop of FF is shape 2 → §2.2 |
| browser driver (Fareway / Walmart / Sam's) | **~13 min** | **yes per store** — one thread each | per-term loop is **deliberately paced**; §3.1 |
| first-stage builders | tens of s | **yes** — part-1 Phase 4 | done |
| `check-ad-cycles` SHIP path | **418 s** | **no** | the remaining block; §2.1 |
| `check-ad-cycles` INSPECT | **104 s** | **yes** — 34 lanes, 8-wide | done (was 513 s → 171 s → 104 s) |
| arrivals / resolve-worklist / notify / prune | ~30 s | no | serial by **dependency**; §3 |
| `git add -A` / commit / push | unmeasured | no | not parallelisable — but **shrinkable**, and badly; §4.1 |

**The long pole of the daily wall clock is the browser driver, not compute.** ~13 of 29 minutes is
Chrome walking 45 Fareway terms plus Sam's at a deliberate pace, because the alternative is a bot wall
(Walmart is already walled and is now attended). More cores do not help a paced session. This is the
single most important sentence in the document: **the daily chain's floor is set by vendor politeness,
and that floor is ~15 minutes regardless of anything below.**

### 1.2 `TC Grocery Ad Pulls 0700` — `capture-run.ps1 -Kind ad`

Two lanes (Fareway monthly, Family Fare), launched concurrently. No downstream by design ("ONE CHAIN
A DAY", Brad 2026-08-22). Already parallel. **Today's run exited rc=1 on a git stderr line** — the
`2>$null` class `bfcd28f7` fixed; verify tomorrow's 07:00 is the first clean run with it.

### 1.3 `TC Graph Nightly Matching` — `graph\pipeline\nightly.ps1`

Measured from `graph-nightly-status.json`, 2026-08-23 01:24: **132 s total.**

| stage | s | bound by |
|---|---|---|
| emit (resolve.py --emit-contested) | 2 | CPU, already fast |
| defs | 0 | — |
| **sweep** (GPU embedding, 4,070 texts) | **93** | **GPU** |
| serve (llama, 4 slots) | 8 | GPU |
| resolve --llm --jobs 4 | 2 | 0 model calls — every question settled deterministically |
| stage1_analyze | — | — |

**Nothing here for cores.** 70% is a GPU sweep; the LLM stage already takes `--jobs`. Leave alone.

### 1.4 `TC Grocery Capture Watchdog 0930`, `heartbeat.yml`, `gates.yml`

Seconds each. Out of scope.

### 1.5 `daily.yml` (GitHub Actions cloud backup)

Runs `check-ad-cycles -NoAlert` on the days Brad's machine is off. Inherits every fan-out above.
**Note:** this is precisely the path where the `store-registry` lane was dead until `bf0158e4`; the
first cloud run since is the proof it is fixed.

### 1.6 Weekly / cadence-gated

| process | wall | parallel? | verdict |
|---|---|---|---|
| `test-auditors` (7 d or inputs moved) | **226 s**, 220 child launches, 72% in children | partly (`test-match-lib` 16 shards, `RunPSMany` ×3) | part 1 §3 measured the rest at **8 s** — closed |
| `run-test-guards-weekly` | unmeasured | no | 2 children; §2.4 measure |
| `audit-ghost-drift`, `audit-cloudflare-estate`, `audit-prompt-backup` | unmeasured | no | network; each is one script; measure |
| `audit-search-links` (weekly) | unmeasured | no | 7 net calls in 14 loops — shape 2; §2.4 |

### 1.7 Manual / on-demand

| process | children | parallel? | verdict |
|---|---|---|---|
| `apply-coverage-batch` | 14 launches, 9 distinct (4× `compare-deals`) | no | **dependency chain** — compare → audit → build → gate; §3.3 |
| `wave-publish` (recipe hunter) | 9 launches | no | ordered pipeline with a lock ("nothing else may write the tree while a wave is being verified"); §3.3 |
| `propagate-recipes` | 3 | no | small; measure |
| `engine\publish.ps1` | per-recipe Ghost upsert | no | shape 2 against Ghost admin API; §2.3 |
| `hunt-run` lanes | — | yes by design (plan §2.4) | — |
| lessons skill scripts | interactive | — | out of scope |
| `check-ad-cycles` run **without** `-NoPull` | 4 serial store pulls, lines 350–408 | no | **not on any scheduled path** — only manual runs. See §3.4: retire, do not fan out |

---

## 2. Move off serial — with the number, or with the measurement that comes first

### 2.1 `publish-deals-page.ps1` — 11 serial children inside a 167 s block *(daily, ship path)*

The largest remaining block on the critical path. Today's gap from `share-image` to
`AUTO-PUBLISH` was **167 s**. Its children, in order:

```
audit-price-mode  audit-links  audit-name-drift      <- pre-build gates, read-only
build-deals-page                                      <- THE build; serial pivot
audit-store-coverage  audit-match-soundness  audit-category-coverage   <- post-build gates, read-only
publish-store-guide  build-trend-pages  build-trend-index  publish-trend-pages
```

**What moves:** the pre-build trio (one fan-out), the post-build trio (a second fan-out), and
`publish-store-guide` alongside the trend chain. `build-deals-page` stays a serial pivot between them.
Every gate is a read-only report-writer — the same shape as the 34 inspect lanes, already proven.

**The constraint that makes this different from Phase 1:** these are **hard gates**. A BLIND here
must HOLD the publish, not log a REVIEW line. The fan-out helper already returns `Blind`; the
consumer must treat it as a gate failure. Markers are mandatory (all six emit one).

**Expected:** roughly 50–70 s off the block; **unmeasured**, because the per-child timings inside
`publish-deals-page` are not logged. First step is to log them (one line per child, as
`check-ad-cycles` now does for the publish itself), run one morning, then fan out on the numbers.

**A duplication to decide on, not paper over:** `audit-store-coverage`, `audit-match-soundness` and
`audit-category-coverage` run **twice a day** — once here as publish gates, once in the inspect
fan-out as advisory lanes. `match-soundness` is 108 s concurrent / 2 s cached. If the second run is
deliberate (gate before, watch after), say so in the lane comment; if not, drop the inspect copy.

### 2.2 `pull-regular-familyfare.ps1` — 94 terms, one Freshop call each *(daily, capture lanes)*

Measured across nineteen scheduled mornings: **88–108 s**, and it is the longest of the three API
lanes, so it bounds that whole phase. Same shape as `discover-hyvee`: resolve the slice → fetch
concurrently → judge serially.

**Expected:** ~100 s → ~30 s at 4 workers, **~70 s off every morning** — the largest compute-side
win left. **The risk is the reason it is not already done:** on 08-01, 08-08 and today, a *second*
run in a day took **407 / 408 / 567 s** — Freshop throttles. Four workers at the existing 400 ms pace
is a ~4× rate increase against that API. This is **Brad's call as a vendor decision**, and the plan
recommends trying it at **2 workers first** and reading the next morning's lane time before going
to 4.

### 2.3 `engine\publish.ps1` — one Ghost upsert per recipe *(on demand: waves, reanchors)*

`foreach ($slug in $Slugs)` → `Invoke-GhostApi` (30 s timeout, 3-retry backoff). Serial by
construction, and Ghost's admin API **rate-limits** (the retry ladder exists because of 429s).
A wave is 10 recipes; a reanchor republish is capped. **Measure a wave's publish time first**; if it
is >60 s, 2–3 concurrent upserts with the existing backoff. Not a daily-path item.

### 2.4 Measure before touching — no number exists yet

| process | why it might matter | what to measure |
|---|---|---|
| `guards.ps1` | the hard gate, 72 checks, one process, read-only over one board | wall time; if >30 s, its checks are independent and could shard |
| `compare-deals.ps1` | the engine; `apply-coverage-batch` runs it 4× | wall time; whether 4× is 4 distinct inputs |
| `top5-weekly` (35 s), `sale-windows` (32 s), `free-rotation` (17 s) | visible gaps in today's ship path | what they do in that time — Ghost calls or compute |
| `audit-search-links` | 7 net calls × 14 loops, weekly | wall; 4-wide if >60 s |
| `publish-trend-pages` | one Ghost upsert per trend page | page count × per-call time |
| `run-test-guards-weekly`, `test-scale-hardening`, `test-guards` | serial children, weekly | wall; probably small |

**Rule for this table:** nothing in it gets a fan-out on a hunch. Part 1 §4 projected ~2 s for the
`norm_text` cache and measured 0.26 s; `discover-hyvee` was projected from a log gap and measured
half of that. Every row here gets a stopwatch line first.

---

## 3. Must stay serial — and the reason, so nobody re-asks

### 3.1 The browser driver's per-term loop (the long pole)

`pull-browser-stores.py` runs one thread per store — already parallel at the store level. **Within a
store, terms are sequential by design**: a `goto → hydrate → extract → pace` loop at 8–12 s per term
for Fareway, with `pull-agent-lib`'s backoff and wall limit. The file's own header explains what
happened when Walmart was hit from a fresh headless profile with no pacing: a bot wall, and the store
is now attended through Brad's own Chrome. **Do not parallelise within a store.** The 13-minute
capture is the price of not being walled again, and it is the daily floor.

### 3.2 Mutators and deleters

`repair-multipack-sizes` (65 s today) rewrites `out\regular\*`; `derive-links-from-prices` (41 s)
rewrites `product-urls.json`; `fix-links-ff` likewise; `prune-out` / `prune-intermediates` delete
dated files the audits read; `db-build` rebuilds a SQLite database. Each one's output is another
stage's input. ~110 s of today's ship path is this, and it stays.

### 3.3 Dependency chains dressed as child lists

`apply-coverage-batch` (compare → audit → build → tile-integrity → links → compare → guards) and
`wave-publish` (update-db → compute → propagate → hunt-run … under a tree lock) look like shape 1
and are not: each step reads what the previous one wrote. `wave-publish` additionally holds a lock
*because* concurrent writers to the recipe tree were the 2026-08-15 failure. Serial, correctly.

### 3.4 The in-chain store pulls — retire, do not fan out

`check-ad-cycles` lines 350–408 pull four stores one after another. Part 1's follow-up ranked fanning
these out as priority #1. **That was wrong**: the block is inside `if (-not $NoPull)` and every
scheduled caller passes `-NoPull`, because `capture-run` already does these pulls as parallel lanes
*before* calling the chain. The block exists for manual runs only — and on a manual run it is a
**trap**, not a convenience: it re-pulls stores that were pulled hours earlier, gets throttled (567 s
today), and advances rotation cursors (FF 515 → 522 today) for a test. Recommendation: make the
chain **refuse** without `-NoPull` unless `-Force`, and point the operator at `capture-run`. One
guard, not one fan-out.

### 3.5 Outward-facing, one at a time on purpose

`Send-Alert` (mutex-serialised, `9d56d137`), `send-price-alerts` (per-subscriber Gmail),
`notify-item-added`, the Friday digest, `git push`. Anything that pages a human or publishes
outward stays serial.

---

## 4. Found in the review, not a parallelism item, and more important than most of the above

### 4.1 A 680 MB Chrome profile is tracked in git, and it holds Brad's store sessions

`grocery\out\browser-profiles\` — **4,552 files, 680 MB** — entered git on 2026-08-22 with the
browser driver (`d2a864c0`: 4,388 files, 797,640 insertions) and churns every run: the 08-22 daily
commit carried 101 profile files, today's 20. `.git` is now **395 MB**. It is not in any ignore
list, and the daily commit's `git add -A -- $paths` sweeps it up.

Two problems, in order of importance:

1. **The profile is the persistent Chrome session the driver uses to prove it is on the right Omaha
   store** — cookies, local storage, the Fareway in-store identity. That is now in a git remote.
2. Every daily commit stages and pushes Chrome cache churn. This is the one thing in the estate that
   makes the commit stage slower every day rather than the same.

**Recommendation:** `.gitignore` the directory, `git rm -r --cached` it (the working copy stays, the
driver is unaffected), and **Brad decides** whether the two days of history are rewritten — that is
a force-push of `main` and a credential-rotation question, not something this plan does on its own.
Before any of that: confirm the driver does not rely on the profile being *restored from git* on the
cloud runner (it should not — `daily.yml` runs `-NoAlert` and cannot drive Chrome).

### 4.2 Today's two rc=1 exits are explained, not open

- **08:00 `downstream rc=1`**: the chain ran the **pre-merge** `check-ad-cycles` — `Test-CadenceDue`
  did not exist until `efe803f5` was merged at ~10:30. Tomorrow's 08:00 is the first scheduled run
  with it. The board still published at 08:22:33; the failure was in INSPECT.
- **07:00 rc=1**: a git stderr line under EAP=Stop, the class `bfcd28f7` closes. Verify tomorrow.

### 4.3 `Log()` against a held file — fixed today (`6c2632e9`)

250 s of a 29-minute run was `Start-Sleep`. 100.7 s → 0.7 s per 200 lines. Recorded here because it
is the kind of thing that reads as "the chain is slow" and is nothing of the sort.

---

## 5. What the daily wall clock looks like after all of this

| | today | after §2.1 + §2.2 | floor |
|---|---|---|---|
| capture (API lanes) | ~100 s | ~30 s | FF vendor pace |
| capture (browser) | ~13 min | **~13 min** | paced by design — §3.1 |
| chain SHIP | 418 s | ~330 s | ~110 s of mutators + the build + the publish |
| chain INSPECT | 104 s | 104 s | `semantic` (118 s GPU) and `discover-hyvee` |
| commit / push | unmeasured | smaller — §4.1 | — |
| **total** | **29 min** | **~26 min** | **~15 min, all of it browser pacing** |

That is the honest number. The compute side of the daily chain has gone from ~31 min of downstream
(plan 1 §0) to ~9 min, and the next 3 minutes are in §2. Past that, the wall clock belongs to the
stores' rate limits, and the only lever left is how many terms a day the policy asks for — a
coverage decision, not a cores decision.

---

## 6. Order

1. **§4.1** — the profile out of git. Not speed; hygiene and a credential. Brad's decision on history.
2. **§3.4** — the in-chain pull guard. One `if`. Stops the next manual run from repeating today.
3. **§2.1** — instrument `publish-deals-page`'s children, one morning of numbers, then the two trios.
4. **§2.2** — Family Fare at 2 workers, one morning, then Brad decides on 4.
5. **§2.4** — stopwatches on the unmeasured table. Fan out only what the numbers justify.
6. **§2.3** — recipe publish, on the next wave, if the wave's publish time says so.

Each is its own commit with before/after wall time in the message, a `-Sequential` path, records
asserted by name, markers demanded where they exist, and a fixture proven to fire — the same
discipline as part 1, because the three regressions part 1 found were all caught by exactly that.
