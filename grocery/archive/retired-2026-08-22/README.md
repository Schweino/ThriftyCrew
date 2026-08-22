# Retired 2026-08-22

The 8:30 local runner and its watchers, replaced on 2026-08-20 by the three `TC Grocery *`
Windows tasks (`capture-run.ps1 -Kind ad` 07:00, `capture-run.ps1 -Kind daily` 08:00,
`capture-watchdog.ps1` 09:30). Kept for the record; nothing calls them.

- `run-daily-local.ps1` - the old "SMP Grocery Daily Pipeline (local)" task body. Its two lessons moved
  with it: the LOCKED-log sidecar + recovery now lives in `check-ad-cycles.ps1`, and the run record
  (start / stage / exit code) in `capture-run.ps1`.
- `local-watchdog.ps1` - browser-store staleness watcher for the retired 6am agents. Its
  `health-heartbeat.ps1` call moved into `capture-watchdog.ps1`.
- `check-cloud-runs.ps1` - queried GitHub Actions on the OLD repo name (SimpleMoneyPlaybook) and 404'd
  every morning since the rename.
- `run-hidden.vbs` - the hidden-window launcher; the TC tasks use `-WindowStyle Hidden` directly.

Also removed that day: the stale `%LOCALAPPDATA%\smp-daily-local.lock` from the 08-19 run.
