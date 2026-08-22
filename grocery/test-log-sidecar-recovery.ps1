<#
  test-log-sidecar-recovery.ps1 - self-test for the SIDECAR RECOVERY block in check-ad-cycles.ps1 (it lived in run-daily-local.ps1 until that runner was retired on 2026-08-22).

  Why it is written this way: check-ad-cycles.ps1 cannot be dot-sourced (that would run the whole daily
  pipeline), so this test EXTRACTS the shipped text between the >>> / <<< SIDECAR-RECOVERY sentinels and
  executes exactly those lines against a sandbox $root/$log. It therefore reaches the real code, not a
  copy of it - a copy is how two same-day fixes shipped regressions on 2026-07-29.

  Founding bug (2026-08-02): local-daily-log.txt was locked mid-run, the run correctly diverted its trail
  to local-daily-log.LOCKED-2026-08-02.txt, and the alert's remedy said "delete the sidecar" - which would
  have destroyed the only record of the run between 08:30:03 and 09:13:10. Nothing merged it back.

  Exit 0 = all cases pass. Exit 1 = a case failed.
#>
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'check-ad-cycles.ps1'
$all = Get-Content $src
$a = ($all | Select-String -Pattern '^# >>> SIDECAR-RECOVERY' -SimpleMatch:$false | Select-Object -First 1).LineNumber
$b = ($all | Select-String -Pattern '^# <<< SIDECAR-RECOVERY' -SimpleMatch:$false | Select-Object -First 1).LineNumber
if (-not $a -or -not $b -or $b -le $a) { Write-Host 'FAIL: SIDECAR-RECOVERY sentinels not found in check-ad-cycles.ps1'; exit 1 }
$block = ($all[$a..($b - 2)]) -join "`r`n"
$sb = [scriptblock]::Create($block)

$fails = @()
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host ("  ok   " + $name) } else { Write-Host ("  FAIL " + $name + " :: " + $detail); $script:fails += $name }
}

$sandRoot = Join-Path $env:TEMP ('sidecar-recovery-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandRoot -Force | Out-Null
try {
  $today = (Get-Date -Format 'yyyy-MM-dd')
  $yday  = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

  # ---- CASE 1+2+3: prior-day sidecar merges and clears; today's is left alone; empty one is just cleared.
  $root = $sandRoot
  $log  = Join-Path $root 'local-daily-log.txt'
  Set-Content -Path $log -Value @('[x] first line', '[x] frozen here') -Encoding UTF8
  $scOld   = Join-Path $root ('local-daily-log.LOCKED-' + $yday + '.txt')
  $scToday = Join-Path $root ('local-daily-log.LOCKED-' + $today + '.txt')
  $scEmpty = Join-Path $root 'local-daily-log.LOCKED-2020-01-01.txt'
  Set-Content -Path $scOld   -Value @('[y] recovered A', '[y] recovered B', '[y] done') -Encoding UTF8
  Set-Content -Path $scToday -Value @('[t] run in progress') -Encoding UTF8
  Set-Content -Path $scEmpty -Value '' -NoNewline -Encoding UTF8

  $LogFile = $log
  & $sb

  $after = @(Get-Content $log)
  Check 'prior-day sidecar deleted'        (-not (Test-Path $scOld))                     'sidecar survived the merge'
  Check 'today sidecar untouched'          ((Test-Path $scToday) -and (Get-Content $scToday) -contains '[t] run in progress') 'today sidecar was consumed'
  Check 'empty sidecar cleared'            (-not (Test-Path $scEmpty))                   'empty sidecar survived'
  Check 'recovered lines present'          ($after -contains '[y] recovered A' -and $after -contains '[y] done') 'trail was lost'
  Check 'marker names the sidecar'         (($after | Where-Object { $_ -like '*recovered from local-daily-log.LOCKED-*' -and $_ -like '*3 lines*' }).Count -eq 1) 'no marker / wrong line count'
  Check 'original lines preserved'         ($after[0] -eq '[x] first line' -and $after[1] -eq '[x] frozen here') 'primary log was overwritten'
  Check 'appended in order after the seam' ([array]::IndexOf($after, '[y] recovered A') -lt [array]::IndexOf($after, '[y] done') -and [array]::IndexOf($after, '[y] recovered A') -gt 1) 'out of order'
  Check 'today sidecar not merged in'      (-not ($after -contains '[t] run in progress')) 'in-progress sidecar was folded in early'

  # ---- CASE 4 (the one that matters): primary log LOCKED. Nothing may be deleted, no trail may be lost.
  $root2 = Join-Path $sandRoot 'locked'; New-Item -ItemType Directory -Path $root2 -Force | Out-Null
  $root = $root2
  $log  = Join-Path $root 'local-daily-log.txt'
  Set-Content -Path $log -Value '[x] frozen' -Encoding UTF8
  $sc2 = Join-Path $root ('local-daily-log.LOCKED-' + $yday + '.txt')
  Set-Content -Path $sc2 -Value @('[y] precious', '[y] trail') -Encoding UTF8
  $fs = [System.IO.File]::Open($log, 'Open', 'ReadWrite', 'None')
  $LogFile = $log
  try { & $sb } finally { $fs.Close() }
  Check 'locked log: sidecar kept'   (Test-Path $sc2)                                        'sidecar deleted while the log was locked - trail destroyed'
  Check 'locked log: content intact' ((@(Get-Content $sc2)) -contains '[y] precious')         'sidecar content lost'
} finally {
  Remove-Item $sandRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails.Count) { Write-Host ("FAIL: " + $fails.Count + " case(s): " + ($fails -join ', ')); exit 1 }
Write-Host 'PASS: log sidecar recovery (merge, same-day hold, empty clear, locked-log refusal)'
exit 0
