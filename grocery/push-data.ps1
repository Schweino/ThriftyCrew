<#
  push-data.ps1 - Run at the END of a LOCAL browser-store refresh (Baker's daily agent + weekly agent) to
  commit the freshly-pulled RAW store data to the repo, so the cloud recomputes with current prices instead
  of clobbering them with stale data.

  Only raw inputs travel: derived files are gitignored, and the cloud-owned regenerable/state files (the
  served feed, the publish signature, the visibility cache, price-history) are reverted here so the two
  sides never fight over the same file on rebase. The one genuinely co-written file is ad-schedule.json
  (local writes Baker's window, cloud writes the server windows) - a rare same-minute race just aborts and
  retries next run rather than leaving a mess.
#>
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent   # income\ (git root)
Push-Location $repo
try {
  # cloud owns these (regenerated deterministically OR cross-run state it must persist): discard local copies
  git checkout -- grocery/public/smp-feed.json grocery/out/published-board.sig grocery/out/last-visibility.txt grocery/price-history.json grocery/alert-state.json 2>$null
  git add -A
  git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) { Write-Output 'push-data: no raw-input changes to push'; return }
  git commit -m ("Local browser-store refresh " + (Get-Date -Format 'yyyy-MM-dd HH:mm')) 2>&1 | Out-Null
  git pull --rebase origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    git rebase --abort 2>$null
    Write-Output 'push-data: rebase conflict (likely ad-schedule.json) - NOT pushed; will retry next run'
    return
  }
  git push origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Output 'push-data: raw store inputs pushed - the cloud will recompute with current prices' }
  else { Write-Output 'push-data: PUSH FAILED (network/auth) - will retry next run' }
} finally { Pop-Location }
