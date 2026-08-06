<#
  test-proof-freshness.ps1 - self-test for the PROOF-FRESHNESS block in health-heartbeat.ps1.

  Written the same way as test-log-sidecar-recovery.ps1 and for the same reason: health-heartbeat.ps1
  cannot be dot-sourced (that would run the whole health check and mail Brad), so this test EXTRACTS the
  shipped text between the >>> / <<< PROOF-FRESHNESS sentinels and executes exactly those lines against a
  sandbox. It therefore reaches the REAL code, not a copy of it - a copy is how two same-day fixes shipped
  regressions on 2026-07-29.

  FOUNDING BUG (2026-08-06, case 1 below - this case MUST fire).
    "SMP Bakers Daily Scan" exited 0x800710E0 and produced no data at all: the PC woke at 05:49 for the 5:50
    wake task, went back to sleep at 05:52, and the 06:00 trigger fired into a sleeping machine. The heartbeat
    ran at 06:45, saw the nonzero result, checked the task's 'proves' glob, found bakers-regular-2026-08-05.json
    at 23.5h old - inside the 30h max_age_hours - and reported "work landed, not dead". A whole missed day went
    unpaged. max_age_hours is deliberately WIDER (30h) than a daily task's period (24h), so yesterday's output
    will always excuse today's missed run unless the proof is also required to postdate the run.

  CLEAN TWIN (2026-07-28, case 2 - this case MUST NOT fire).
    The same task exited nonzero because a battery condition terminated it AFTER its data had already
    refreshed. That is the reason 'proves' exists. Its proof was written DURING the run, so it postdates
    LastRunTime and is still correctly excused. A fix that pages on this case has broken the feature.

  Both fixtures are frozen here as explicit timestamps. Do NOT regenerate them from the live task state.

  Exit 0 = all cases pass. Exit 1 = a case failed.
#>
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'health-heartbeat.ps1'
$all = Get-Content $src
$a = ($all | Select-String -Pattern '^# >>> PROOF-FRESHNESS' | Select-Object -First 1).LineNumber
$b = ($all | Select-String -Pattern '^# <<< PROOF-FRESHNESS' | Select-Object -First 1).LineNumber
if (-not $a -or -not $b -or $b -le $a) { Write-Host 'FAIL: PROOF-FRESHNESS sentinels not found in health-heartbeat.ps1'; exit 1 }
$block = ($all[$a..($b - 2)]) -join "`r`n"
. ([scriptblock]::Create($block))
if (-not (Get-Command Test-ProofLanded -ErrorAction SilentlyContinue)) { Write-Host 'FAIL: the extracted block did not define Test-ProofLanded'; exit 1 }

$fails = @()
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host ("  ok   " + $name) } else { Write-Host ("  FAIL " + $name + " :: " + $detail); $script:fails += $name }
}
function NewProof($dir, $name, [datetime]$stamp) {
  $p = Join-Path $dir $name
  Set-Content -Path $p -Value 'fixture' -Encoding UTF8
  (Get-Item $p).LastWriteTime = $stamp
  return $p
}

$sand = Join-Path $env:TEMP ('proof-freshness-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $sand 'grocery\out\regular') -Force | Out-Null
try {
  # ---- CASE 1: FOUNDING BUG. Frozen 2026-08-06 timings. Proof is 23.5h old (inside the 30h window) but was
  #      written the day BEFORE the run, because the run never started. MUST NOT be excused.
  $now1  = [datetime]'2026-08-06T06:45:00'
  $last1 = [datetime]'2026-08-06T06:12:20'   # the refused start Task Scheduler recorded
  NewProof (Join-Path $sand 'grocery\out\regular') 'bakers-regular-2026-08-05.json' ([datetime]'2026-08-05T07:12:54') | Out-Null
  $r1 = Test-ProofLanded -ProvesGlob 'grocery/out/regular/bakers-regular-*.json' -RepoRoot $sand -MaxAgeHours 30 -LastRunTime $last1 -Now $now1
  Check 'case 1 founding bug: missed run is NOT excused by yesterday output' (-not $r1.fresh) ("fresh=" + $r1.fresh + " ageH=" + $r1.ageH)
  Check 'case 1 says WHY in the alert text' ($r1.why -match 'PREDATES') ("why='" + $r1.why + "'")
  Check 'case 1 proof really was inside the age window (else it passes for the wrong reason)' ($r1.ageH -le 30) ("ageH=" + $r1.ageH)

  # ---- CASE 2: CLEAN TWIN. Frozen 2026-07-28. Task exited nonzero (battery kill) but its data HAD refreshed
  #      during the run. MUST still be excused, or the 'proves' feature is broken.
  $now2  = [datetime]'2026-07-28T06:45:00'
  $last2 = [datetime]'2026-07-28T06:00:03'
  $sand2 = Join-Path $sand 'twin'
  New-Item -ItemType Directory -Path (Join-Path $sand2 'grocery\out\regular') -Force | Out-Null
  NewProof (Join-Path $sand2 'grocery\out\regular') 'bakers-regular-2026-07-28.json' ([datetime]'2026-07-28T06:09:18') | Out-Null
  $r2 = Test-ProofLanded -ProvesGlob 'grocery/out/regular/bakers-regular-*.json' -RepoRoot $sand2 -MaxAgeHours 30 -LastRunTime $last2 -Now $now2
  Check 'case 2 clean twin: work that landed mid-run is still excused' ($r2.fresh) ("fresh=" + $r2.fresh + " why='" + $r2.why + "'")

  # ---- CASE 3: proof older than max_age_hours -> not excused (the original condition still holds).
  $r3 = Test-ProofLanded -ProvesGlob 'grocery/out/regular/bakers-regular-*.json' -RepoRoot $sand -MaxAgeHours 30 -LastRunTime ([datetime]'2026-08-10T06:00:00') -Now ([datetime]'2026-08-10T06:45:00')
  Check 'case 3 genuinely stale proof is not excused' (-not $r3.fresh) ("fresh=" + $r3.fresh + " ageH=" + $r3.ageH)

  # ---- CASE 4: no 'proves' in the registry -> a nonzero result always pages. Unchanged behaviour.
  $r4 = Test-ProofLanded -ProvesGlob '' -RepoRoot $sand -MaxAgeHours 30 -LastRunTime $last1 -Now $now1
  Check 'case 4 task with no proves glob is never excused' (-not $r4.fresh) ("fresh=" + $r4.fresh)

  # ---- CASE 5: glob matches nothing -> not excused, and says so.
  $r5 = Test-ProofLanded -ProvesGlob 'grocery/out/regular/nothing-matches-*.json' -RepoRoot $sand -MaxAgeHours 30 -LastRunTime $last1 -Now $now1
  Check 'case 5 empty proves glob is not excused' ((-not $r5.fresh) -and $r5.why -match 'nothing matches') ("fresh=" + $r5.fresh + " why='" + $r5.why + "'")

  # ---- CASE 6: no LastRunTime known (task info unavailable) -> fall back to the age test alone rather than
  #      pretending we can compare against a run time we do not have.
  $r6 = Test-ProofLanded -ProvesGlob 'grocery/out/regular/bakers-regular-*.json' -RepoRoot $sand -MaxAgeHours 30 -LastRunTime $null -Now $now1
  Check 'case 6 unknown LastRunTime falls back to the age test' ($r6.fresh) ("fresh=" + $r6.fresh + " why='" + $r6.why + "'")
}
finally { Remove-Item $sand -Recurse -Force -ErrorAction SilentlyContinue }

if ($fails.Count -eq 0) { Write-Host 'PROOF-FRESHNESS: all cases pass.'; exit 0 }
Write-Host ("PROOF-FRESHNESS: " + $fails.Count + " case(s) FAILED: " + ($fails -join ', ')); exit 1
