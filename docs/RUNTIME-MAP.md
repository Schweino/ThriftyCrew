# Thrifty Crew runtime ownership map

OVERHAUL-5 deliverable (2026-07-27), corrected 2026-08-15. Maps the four runtimes and, critically, the
**git-bus**: which files one runtime writes and another reads through the repo. That coupling is the reason
regenerated data cannot simply leave git (OVERHAUL-4); this map is the classification the remaining
untracking work runs against.

**There is no fifth runtime.** A TypeScript/D1/R2 platform (`income/platform/`, "V3" then "V4") was built
2026-08-09 as a parallel estate and deleted 2026-08-14 (commit `f5e187a0`) along with its 16
`ThriftyCrew V3 *` scheduled tasks. It never became authoritative — the PowerShell estate below ran the live
site the entire time — and its own exit gates stood at 1/14 parity days and 0/4 Chrome cycles when V4 was
started on top of it. If you find a reference to it, that reference is stale. The code is recoverable with
`git checkout pre-platform-removal -- platform/`.

**Its RUNTIME was not deleted, and the sentence that used to sit here — that the Cloudflare workers
`tc-grocery-v3` and `tc-grocery-public` "are no longer in any serving path" — was wrong.** Measured
2026-08-20: `tc-grocery-v3` took **480 requests in five days, more than `smp-feed`**, making it the
busiest worker on the account, and all 542 live recipe cards hydrate their prices from a route it
serves (see the open `/api/v2/recipe-feed/` item in `grocery\triage-queue.json`). It is bound to a
4GB D1 database and all four `tc-grocery-v3-*` R2 buckets. **Do not delete any of it as dead V3
debris.** Deleting the code from this repo did not delete the estate; it only made it invisible.

That invisibility had a price. Nine R2 lifecycle rules nobody could see moved objects into
Infrequent Access, which bills per whole million operations with no free tier — 499 transitions on
2026-08-19 bought a full $9.00 block, about 95% of the Cloudflare bill, to save roughly six cents of
storage. The rules were removed 2026-08-20. The estate is now declared in `ops\cloudflare-estate.json`
and checked on every push by `ops\audit-cloudflare-estate.ps1`.

## The four runtimes

### 1. Local PC (Windows Task Scheduler) — PRIMARY
| Task | When | Does |
|---|---|---|
| TC Grocery Ad Pulls 0700 | 7:00am | `capture-run.ps1 -Kind ad` — pulls the weekly ad for every store whose ad rolled over TODAY (capture-policy decides; a store not due is skipped, not pulled "just in case"). All stores run CONCURRENTLY, then the downstream chain: compare-deals -> guards -> publish -> recipes -> commit. |
| TC Grocery Daily Capture 0800 | 8:00am | `capture-run.ps1 -Kind daily` — the quarterly rotation slice (total terms / 90 days, per store) plus any sale reverting today, then the same downstream chain. Ads land on different days per store, but everyday prices move daily, so this publishes too. |
| TC Graph Nightly Matching | 9:30pm (when installed) | `graph/pipeline/nightly.ps1` — the local matching chain. Owns the GPU window end to end and hands the card back before 06:30, so the 07:00 and 08:00 jobs never find it held. BLIND-not-block at every stage; publishes nothing. |
| TC Grocery Capture Watchdog 0930 | 9:30am | `capture-watchdog.ps1 -Alert` — asks whether the 07:00/08:00 jobs actually CAPTURED and PUBLISHED, not merely exited 0. One email, never six. |

**The four `SMP *` tasks that used to sit here are gone** (deleted 2026-08-20, not renamed): `SMP Bakers
Daily Scan`, `SMP Grocery Daily Pipeline (local)` (the 8:30am run), `SMP Grocery Failure Watchdog`,
`SMP Wake For Grocery Agents`, plus `SMP Daily Facebook Reel` and `SMP Friday Email`. The three tasks
above replace them. The browser-walled stores (Walmart, Sam's Club, Fareway, Aldi) have no headless
lane: `capture-run.ps1` writes them a worklist and raises a flag file, and a human-driven Chrome works
it — the watchdog is what notices when nobody does.

### 2. GitHub Actions (cloud) — MANUAL FALLBACK ONLY (not a running backup)
Both are `on: { workflow_dispatch: {} }` — **no cron, they never fire on their own.** GitHub-hosted
Actions minutes were exhausted, so they are retained as operator-selected rollback artifacts. Do not
describe them as a safety net: on a day the PC is off, nothing runs unless a human dispatches one.
- **daily.yml**: stands down if a bot commit already landed today (the local run). If dispatched after a
  missed local run, it full-checks-out, runs the SAME `check-ad-cycles.ps1`, and `git add -A` commits
  everything back. It cannot replace local fully because the weekly browser captures need a real Chrome.
- **heartbeat.yml**: alerts if no pipeline commit landed recently. Alerting only, writes no data.

### 3. Cloudflare Worker — SERVE + INGEST
- Serves `public/` statically with per-path CORS (`public/_headers`): `smp-feed.json`, `board.json`, `free-dinners.json`, `planner-data.json`, `price-history.json`, `share/`.
- `GET /smp-feed.json` is served **straight from the static asset**, with no upstream fetch and no fallback
  branch (`X-TC-Feed-Source: static-asset`). From 2026-08-09 to 2026-08-14 it proxied a V3 "promoted
  release" and kept the asset only as an outage fallback; when the V3 engine started crashing on 2026-08-12
  the release pointer froze and the route served a stale, WRONG blueberries price for two days *after* the
  pipeline had corrected it. The fallback never fired because V3 answered 200 — it served confidently, just
  wrongly. The repo is the source of truth for this feed; read it directly.
- POST endpoints: `/submit` (item request -> Gmail), `/submit-recipe` (recipe suggest, paid-gated), and the daily.yml failure relay -> Gmail.
- Reads the served files **from the repo** (git is its deploy source). This is why `public/**` must stay tracked.

### 4. Claude scheduled agents — JUDGMENT + BROWSER
| Agent | Role |
|---|---|
| grocery-alert-triage | 6:30am — drains `triage-queue.json`, fixes issues + root cause. READS `ad-cycle-log.txt` + `out/**` audit jsons. |
| grocery-browser-stores-refresh | weekly Wed — real-Chrome captures for the walled stores (Hy-Vee/Aldi/Walmart/Sam's). Cannot run headless. |
| grocery-bakers-daily-flash-check / grocery-fareway-daily-check | daily store spot-checks |
| grocery-recipe-everyday-refresh | recipe-side everyday-price refresh |
| dns-cloudflare-migration-reminder | reminder only |
| scalp-eod-google-doc | UNRELATED project (not Thrifty Crew) |

## The git-bus (what makes OVERHAUL-4 delicate)

Files written by one runtime and read by another **through the committed repo**. These MUST stay tracked:

- **Store captures** — `out/regular/**`, `out/bakers/**`, `out/sams/**`, `out/fareway/**`, hyvee/aldi ad pulls. Written by the local pipeline + the Wed browser agent; read by `compare-deals` on every local AND cloud run (union window). Durable INPUTS.
- **Served data** — `public/**` (feed, board.json, free-dinners, planner-data, price-history). Written by the pipeline; served by the Worker off the repo.
- **Durable caches / state read next run** — `product-urls.json`, `price-history.json`, `board-price-overrides.json`, `category-excludes.json`, `ad-schedule.json`, `meal-prep/db/published-hashes.json`, `meal-prep/ingredient-map.json`, `meal-prep/recipes-db.json` (holds visibility), `meal-prep/free-rotation.json`, `meal-prep/db/costed.json`, `meal-prep/pipeline/v2-perserving.json`.
- **Logs read by the triage agent** — `grocery/ad-cycle-log.txt`, `alert-log`, `local-daily-log`, `out/**` audit jsons.
  NOT `triage-queue.json`: it is deliberately ignored (`.gitignore:153`, an explicit rule, not the
  deny-by-default `/*` catch-all) and has never been tracked. It is written by `send-alert.ps1` and read by
  the triage agent on the SAME PC, so it never crosses the git-bus, and its bodies carry alert text. Listing
  it here as must-stay-tracked was an over-claim.

## OVERHAUL-4 classification

- **UNTRACKED 2026-07-27 (provably safe):** `meal-prep/db/built/**` (1026 cards). Only build-cards (writes) + publish (reads) touch them, always paired and on-demand; no runtime reads them cross-run. Rebuildable from spec+costed. Repo 4692 -> 3668 files.
- **DEFER to a watched cloud-run session:** the `grocery/out/**` derived OUTPUTS (`comparison-*`, `candidates-*`, `flagged-*`, `audit/**`, `board.json`, `trend/**`). Each run makes and reads its own newest, so they *look* untrackable, but the last-good-board fallback and staleness logic touch prior outputs; verify against one live daily cycle before untracking. Store captures, public/, caches, and logs above stay tracked permanently.

## The knowledge graph (graph-native redesign, added 2026-08-20)

**There is still no fifth runtime.** `graph/` is a SHADOW estate that reads the
legacy estate and writes only itself. Nothing in any serving path reads it, the
Worker does not touch it, and the four runtimes above are unchanged. It stays
that way until its numeric exit gates pass — the V3/V4 platform is the reason
those gates are numbers.

- **What it is.** A file+SQLite knowledge graph over the same facts the board
  already knows: 7 stores, 633 commodities across the staple and recipe
  namespaces, 3.3k product SKUs, the adjudicated known-wrong rulings, the
  category-exclude guardrails, and ~119k price observations backfilled from the
  tracked captures. Built by `graph/import/import_all.py` in about six seconds.
- **Where truth lives.** In the tracked JSON under `graph/nodes|edges|aliases|
  provenance` plus the gold set. `graph/sqlite/graph.db` is a rebuildable INDEX
  and is gitignored — it never crosses the git-bus, so this adds nothing to the
  OVERHAUL-4 problem.
- **A fifth local model, not a fifth runtime.** `tools/local-llm/serve.ps1`
  starts a llama.cpp OpenAI-compatible endpoint on 127.0.0.1:8080 (Qwen3.8-27B,
  13.1 GB, weights OUTSIDE the repo at `C:\Codex\llm`). Nothing requires it:
  every caller checks `LocalLLM.health()` (`graph/lib/llm.py`) and falls back to
  the deterministic path, because the board must publish with the endpoint down.
  **ONE OWNER OF THE CARD (2026-08-22, narrowed by PLAN-local-matching phase
  2):** it cannot share the 16 GB card with the semantic sidecar sweep, which
  needs ~3 GB and runs in the 07:00 pipeline and 2-3x a day. The ordering is
  owned by `graph/pipeline/nightly.ps1` — emit contested (read-only) -> sweep ->
  **sidecar exits** -> llama-server -> resolve -> Learning Stage 1 ->
  **llama-server down, in a finally block**. That chain is the only scheduled
  path allowed to start the server, and `graph/pipeline/install-nightly-task.ps1`
  is the only thing allowed to schedule the chain (default 21:30, hard stop
  06:30, status in `grocery/out/logs/graph-nightly-status.json`). Start it by
  hand for interactive work and stop it when done —
  `nightly.ps1 -StopOnly`. `audit-semantic-identity.ps1` still checks
  `nvidia-smi` first and still goes BLIND (exit 3, naming llama-server) instead
  of launching a sweep that would OOM; it is now a backstop for a rule something
  enforces, not the rule itself. Client bounds: `LocalLLM` times out at 120 s
  per call (recipe extraction passes 600 explicitly for its 4096-token ask) and
  `resolve.py --jobs` defaults to 4, coupled to `serve.ps1 -Slots 4`. The old
  PowerShell client `grocery/local-llm-lib.ps1` was deleted the same day: it had
  no callers and Python is the only client.
- **New local-only queue.** `grocery/learning-queue.json`, gitignored for exactly
  the reason `triage-queue.json` is (`.gitignore:153`): producer and consumer are
  the same PC, so it never crosses the git-bus, and its bodies carry store text.
- **Where it already earns its keep.** `graph/agentic/verifier.py` answers the
  existing hard gates as graph queries. On its first run it flagged that
  **Fareway's weekly ad window expired 2026-08-15 with `next_pull` 2026-08-16 —
  four days overdue on the browser lane** — while correctly classifying Aldi as
  merely due-today rather than overdue.
- **Status and what remains.** `python graph/eval/status.py` is the single
  answer. Phase 0 passed all four acceptance bars; the gold set (547 cases) shows
  precision 1.000 / recall 0.981 / false-merge 0.0000 / missed-merge 0.0188.
  Board parity is NOT met, but the gap is now small: **0.916 agreement over 0.838
  coverage** (measured 2026-08-20, 2691 shared cells of 3213 live; the bar is 0.99).
  The old figures here (0.758 over 0.31) came from a run where only the `regular` and
  `throttled` lanes had a parseable `deals` array. All seven stores are imported now -
  Aldi, Baker's, Family Fare, Fareway, Hy-Vee, Sam's Club and Walmart all appear in the
  parity run - so do not read that sentence as a live description of the importers.
  The 14-day and 4-Wednesday gates stand at 0.

## OVERHAUL-5 consolidation opportunities

- Local (07:00 ad pulls + 08:00 daily capture, was a single 8:30am run) and cloud (daily.yml) run the identical pipeline; cloud is a stand-down backup. The **non-browser** daily portion (server ad pulls -> compare -> publish) is fully headless and could become cloud-PRIMARY, demoting the PC to the weekly browser captures only. Hard blocker: the Wed walled-store captures need a real logged-in Chrome (no headless path; CAPTCHA walls).
- Consolidation target: shrink the PC's role to (a) the weekly browser capture and (b) a watchdog, moving the daily headless pipeline to the cloud. That also shrinks the git-bus, which in turn unblocks more of OVERHAUL-4.
