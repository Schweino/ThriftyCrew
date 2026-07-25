<#
  check-cloud-runs.ps1 - did the CLOUD side fail? (2026-07-25, triage-system completeness)

  Cloud failures (the GitHub Actions daily backup, the heartbeat) email Brad through the Worker /ops-alert
  relay, which BYPASSES the local triage queue - so under the "no issue email waits for a human" rule they
  were the one alert class with no automated responder. This script closes that: it asks the GitHub API for
  the latest run of each workflow using the SAME stored credential git push already uses (git credential
  fill - nothing new to provision), and routes any failure through send-alert.ps1, which queues it for the
  triage agent. The once-per-type-per-day gate keeps a repeatedly-failing workflow to one email a day while
  the queue entry's count climbs.

  Called by run-daily-local.ps1 after the pipeline (non-fatal). Fails OPEN with a log line: no credential
  or no network must never break the pipeline - the Worker relay email still reaches Brad regardless.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# stored git credential, the way git itself asks for it (never printed, never persisted here)
$tok = $null
try {
  $lines = @("protocol=https", "host=github.com", "path=Schweino/SimpleMoneyPlaybook.git", "")
  $out = $lines | git credential fill 2>$null
  foreach ($l in @($out)) { if ($l -like 'password=*') { $tok = $l.Substring(9) } }
} catch {}
if (-not $tok) { Write-Output 'check-cloud-runs: no stored credential - skipping (fails open; the Worker relay still emails on cloud failure)'; exit 0 }

$h = @{ 'User-Agent' = 'smp-pipeline'; Authorization = 'Bearer ' + $tok }
foreach ($wf in @('daily.yml', 'heartbeat.yml')) {
  try {
    $r = Invoke-RestMethod -Uri ("https://api.github.com/repos/Schweino/SimpleMoneyPlaybook/actions/workflows/$wf/runs?per_page=1") -Headers $h -TimeoutSec 25
    $run = @($r.workflow_runs)[0]
    if (-not $run) { Write-Output ("check-cloud-runs: $wf has no runs"); continue }
    # only completed runs have a verdict; an in-progress run is tomorrow's problem if it hangs
    if ($run.status -eq 'completed' -and $run.conclusion -notin @('success', 'skipped', 'neutral')) {
      Write-Output ("check-cloud-runs: $wf latest run FAILED (" + $run.conclusion + ") - queueing for triage")
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') `
        -Subject ("Cloud workflow $wf failed (" + $run.conclusion + ")") `
        -Body ("The latest GitHub Actions run of $wf concluded '" + $run.conclusion + "' at " + $run.created_at + ".`nRun: " + $run.html_url + "`nThe local pipeline is unaffected (it already ran); this alert exists so the triage agent investigates the cloud side - logs are at the run URL. Common causes: secrets rotation, runner image changes, the pre-checkout gate erroring instead of skipping.") | Out-Null
    } else {
      Write-Output ("check-cloud-runs: $wf ok (" + $run.status + '/' + $run.conclusion + ')')
    }
  } catch { Write-Output ("check-cloud-runs: $wf query failed (" + $_.Exception.Message + ') - skipping (fails open)') }
}
