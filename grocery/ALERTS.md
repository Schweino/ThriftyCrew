# Alerts - the catalogue (reset 2026-08-22)

Brad's ruling 2026-08-22: delete every queued alert and start over with alerts that fit today's
system. The 162-item backlog is archived at `out\archive\triage-queue.archived-2026-08-22.json`
(gitignored, on the capture PC); `triage-queue.json` starts empty. This file lists every alert the
system can still raise, what it means under the three `TC Grocery *` tasks, and where it lands.

## Where an alert goes

1. **`grocery\triage-queue.json`** - every alert, always (`send-alert.ps1`), de-duped per type per day
   and absorbed into an open item across days. **This is the only place alerts accumulate today.**
2. **Email** - MUTED since 2026-08-14 (`alerts-muted.json`). Delete that file to resume.
3. **A reader** - there is none on a clock. The `grocery-alert-triage` agent (6:30 daily) was disabled
   2026-08-22 along with every other Claude schedule. Until something reads the queue, an alert is a
   record, not a page. *Open decision for Brad: a weekly look at the queue, or re-enable the triage agent.*

## Retired with the old runner (no longer raised)

| Alert | Why it is gone |
|---|---|
| Wednesday browser refresh MISSED | the weekly Chrome agent is disabled; walled stores are on demand from `out\browser-capture-due-<date>.flag`, which capture-watchdog watches |
| local-daily-log.txt is locked / autostash not restored / PUSH FAILED / EDGE STALE / feed did not truly refresh | all lived in `run-daily-local.ps1` (retired); the run record and the LOCKED-log sidecar replace the first two, the chain's own commit step owns the rest |
| check-cloud-runs failures | queried the old repo name and 404'd daily; retired |
| local browser-store refresh STALE (local-watchdog) | replaced by capture-watchdog's run record + browser-flag checks |

## Raised by today's schedule

### `TC Grocery Capture Watchdog 0930` (`capture-watchdog.ps1`) - ONE email per day, all findings in it
- **Grocery capture watchdog: N issue(s)** - any of: a TC task missing/disabled/never fired/failed; the
  run record (`out\logs\capture-run-status.json`) shows a run stuck short of `complete`; no
  `comparison-<today>.json`; `public\board.json` older than the board; an ad window closed with no
  pull; a `browser-capture-due` flag older than 1.5 days (walled stores aging).
- **Automation silent-death** (`health-heartbeat.ps1`, run from the watchdog) - a registered task
  vanished/disabled, a `TC *`/`SMP *` task exists that is not in `expected-automations.json`, or a
  critical output (feed, board, free-dinners, v2 manifest, ingredient map) went stale.

### `TC Grocery Daily Capture 0800` -> `check-ad-cycles.ps1 -NoPull` (the one daily chain)
**Board build and publish (the ones that matter most)**
- **Grocery compare FAILED** - compare-deals exited non-zero; board left at last good.
- **Grocery: GUARDS FAILED - board not published** - a hard invariant broke (guards.ps1); last good stays live.
- **Grocery page HELD (coverage)** / **Grocery publish FAILED** - publish gate held, or Ghost upsert failed.
- **Grocery: N NEW price flag(s)** - sanity flags on a published board (huge week-over-week moves, outliers). Review, still published.
- **<store> ad window advanced with no capture behind it** - ad-schedule says a new ad but no ads file for it.

**Price freshness under the 90-day policy**
- **Board prices aging inside a fresh file** (audit-row-age) - rows older than the policy carry, or a store that stopped stamping `as_of`.
- **Grocery: Walmart full capture aging** / **a union store has NO captures in its window** - the comprehensive Walmart/Sam's capture is nearing or past the 90-day carry. (The 14-day wording is gone; guard 9 reads the policy.)
- **Grocery: a store dropped off a commodity tile** / **board-link price drift** - a link's product no longer matches its tile, or a store lost a cell vs yesterday.

**Identity (wrong product wearing a price)**
- **Grocery: N store(s) dropped from a commodity they carry** (coverage-gaps) - a store has a matching product but no cell (too-strict include).
- **Grocery: semantic sweep found N product(s) no rule can see** - the GPU sweep found real products invisible to the regex rules.
- **Grocery: N board cell(s) sit in the wrong store department** (aisle-test) - the store files the product outside the commodity's department.
- **Grocery matching soundness - review needed** - a product MOVED/DROPPED between commodities vs the reviewed baseline.
- **Grocery: a commodity is in no category** / **store-registry drift** - wiring, not prices.
- **Grocery: N on-sale item(s) have no everyday fallback** - a sale cell with nothing to revert to.

**Recipe side (cost engine)**
- **Recipe pricing: N unpriced ingredient line(s)** - a bid names no board commodity; recipe reads too cheap. (Four open: bulgur wheat, keto bun, Korean rice cakes, sumac.)
- **Database constraint refused a write** / **A write broke cross-store integrity** - same class, caught by the SQLite rebuild and the schema audit.
- **Cost engine: golden test failed** / **Recipe cards: pricing rule guard failed** / **Recipe db drift** / **Recipe spec contradictions got worse** / **Recipe per-serving manifest: skipped / REFUSED** / **Recipe price inversion clamped** / **Recipe cards rebuilt but publish failed** / **Re-anchor did not complete** - engine regressions; each names its script.
- **Recipe batch stalled with stages unfinished** - a hunt batch's ledger went quiet mid-flight.
- **Ingredient stores disagree** - cross-store hard finding in the ingredient DB.

**Self-tests of the watchers**
- **Grocery: a GUARD has gone blind (test-auditors failed)** - a watcher no longer fires on its own founding bug; every quiet guard is unproven until fixed.
- **test-guards weekly** / **ghost-drift weekly** - weekly hermetic guard replay; live Ghost vs local card drift.
- **Ops: an agent prompt is not backed up** / **Ops: the Cloudflare estate drifted** - weekly estate checks.

### Headless captures (run by `capture-run.ps1`, alert through the same queue)
- **Grocery: Family Fare catalog is degrading** / **Family Fare pull dropped a carried item** - Freshop throttling or a pull-drop victim.
- **Grocery: a store SEARCH link is dead** - weekly search-link audit.
- **Baker's daily scan** (`bakers-daily-scan.ps1`) - ADFLIP mid-week or pull failure.

### Cloud backup (`daily.yml`, stands down when a bot commit landed) - **Grocery pull FAILED (server stores)** only on the cloud path.

## Adding an alert
Go through `Send-Alert` (alert-lib.ps1) so the 32 KB command-line limit and the queue write apply;
give it a stable subject prefix (the queue keys on it); add a line here.
