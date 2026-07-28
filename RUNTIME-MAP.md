# Thrifty Crew runtime ownership map

OVERHAUL-5 deliverable (2026-07-27). Maps the four runtimes and, critically, the **git-bus**:
which files one runtime writes and another reads through the repo. That coupling is the reason
regenerated data cannot simply leave git (OVERHAUL-4); this map is the classification the remaining
untracking work runs against.

## The four runtimes

### 1. Local PC (Windows Task Scheduler) — PRIMARY
| Task | When | Does |
|---|---|---|
| SMP Bakers Daily Scan | 6:00am | `wscript run-hidden.vbs bakers-daily-scan.ps1` (Kroger API pull for Baker's) |
| SMP Grocery Daily Pipeline (local) | 8:30am | `check-ad-cycles.ps1` — the whole daily: ad pulls -> compare-deals -> guards -> publish deals page -> cost-recipes -> compute-v2 -> top5-weekly -> rotate-free-dinners. Commits + pushes. |
| SMP Grocery Failure Watchdog | periodic | `local-watchdog.ps1` + `health-heartbeat.ps1` (silent-death detection) |
| SMP Wake For Grocery Agents | early am | wakes the machine so the Claude agents can run |

### 2. GitHub Actions (cloud) — BACKUP
- **daily.yml**: stands down if a bot commit already landed today (the local run). If the local run was missed, it full-checks-out, runs the SAME `check-ad-cycles.ps1`, and `git add -A` commits everything back. It is a safety net for days the PC is off. It CANNOT replace local fully because the weekly browser captures need a real Chrome.
- **heartbeat.yml** (10:00 Central): alerts if no pipeline commit landed recently. Alerting only, writes no data.

### 3. Cloudflare Worker — SERVE + INGEST
- Serves `public/` statically with per-path CORS (`public/_headers`): `smp-feed.json`, `board.json`, `free-dinners.json`, `planner-data.json`, `price-history.json`, `share/`.
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
- **Logs + queue read by the triage agent** — `grocery/ad-cycle-log.txt`, `alert-log`, `local-daily-log`, `out/**` audit jsons, `triage-queue.json`.

## OVERHAUL-4 classification

- **UNTRACKED 2026-07-27 (provably safe):** `meal-prep/db/built/**` (1026 cards). Only build-cards (writes) + publish (reads) touch them, always paired and on-demand; no runtime reads them cross-run. Rebuildable from spec+costed. Repo 4692 -> 3668 files.
- **DEFER to a watched cloud-run session:** the `grocery/out/**` derived OUTPUTS (`comparison-*`, `candidates-*`, `flagged-*`, `audit/**`, `board.json`, `trend/**`). Each run makes and reads its own newest, so they *look* untrackable, but the last-good-board fallback and staleness logic touch prior outputs; verify against one live daily cycle before untracking. Store captures, public/, caches, and logs above stay tracked permanently.

## OVERHAUL-5 consolidation opportunities

- Local (8:30am) and cloud (daily.yml) run the identical pipeline; cloud is a stand-down backup. The **non-browser** daily portion (server ad pulls -> compare -> publish) is fully headless and could become cloud-PRIMARY, demoting the PC to the weekly browser captures only. Hard blocker: the Wed walled-store captures need a real logged-in Chrome (no headless path; CAPTCHA walls).
- Consolidation target: shrink the PC's role to (a) the weekly browser capture and (b) a watchdog, moving the daily headless pipeline to the cloud. That also shrinks the git-bus, which in turn unblocks more of OVERHAUL-4.
