# refresh-chain-verdict.ps1 - re-MEASURE the guard verdict out of band, and write what was observed.
#
# WHY THIS EXISTS (2026-09-07). out\chain-verdict.json said guards_blocked=true from 08:14 while the
# board had since been rebuilt and republished with guards passing. The only writer was check-ad-cycles,
# and re-running the whole daily chain to correct one boolean is not proportionate - so the correction
# people reach for is a hand-edit, and a hand-edited verdict is a verdict about nothing.
#
# This is the proportionate path: it RUNS guards.ps1, reads the exit code it actually got, and hands
# that number to the one writer in lib\chain-verdict-lib.ps1. It cannot write a pass it did not observe,
# because it has no way to name the rc except by running the thing that produces it.
#
#   grocery\refresh-chain-verdict.ps1              run guards, write the verdict, print the status
#   grocery\refresh-chain-verdict.ps1 -WhatIf      print what the verdict WOULD say; write nothing
#   grocery\refresh-chain-verdict.ps1 -SelfTest    frozen fixtures for the freshness rules
#
# Exit 0 = the verdict now says guards pass. 1 = it says guards block (this is a correct outcome, not
# an error in this script). 2 = self-test regression. 3 = could not evaluate.
[CmdletBinding()]
param([switch]$SelfTest, [switch]$WhatIfVerdict)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\chain-verdict-lib.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
$OutDir = Join-Path $PSScriptRoot 'out'

if ($SelfTest) {
  $fail = 0
  $tmp = Join-Path $env:TEMP ('cvfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $fxOut = Join-Path $tmp 'grocery\out'
  [void](New-Item -ItemType Directory -Path $fxOut -Force)
  # A fixture tree that Get-ChainVerdictInputPaths can walk. Only the board exists; the rest report
  # 'absent', which is itself a stable, hashable answer - that is the point of not skipping them.
  '{"rows":[]}' | Set-Content -LiteralPath (Join-Path $fxOut 'comparison-2026-09-07.json') -Encoding UTF8
  $today = '2026-09-07'
  try {
    # ---- CLEAN TWIN: a verdict this library just wrote, over an unchanged tree, is a PASS ----------
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 0 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'PASS' -and $st.ship_ok) { Write-Output '  PASS  CLEAN TWIN: a verdict written over the tree it scored reads PASS and ships' }
    else { Write-Output ('  FAIL  a fresh passing verdict did not read PASS (' + $st.status + ': ' + $st.why + ')'); $fail++ }

    # ---- MUST FIRE: THE FOUNDING BUG, IN THE DIRECTION THAT LOSES MONEY. Guards passed, then an
    # input moved. Same file, same date, same guards_blocked=false. The date check calls this fresh.
    'x' | Set-Content -LiteralPath (Join-Path $tmp 'grocery\commodities.json') -Encoding UTF8
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'STALE-INPUTS' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: a PASSING verdict whose inputs changed underneath it is STALE and must not ship (the founding bug)' }
    else { Write-Output ('  FAIL  a stale PASS was trusted - a board no gate has seen can reach the edge (' + $st.status + ')'); $fail++ }

    # ---- CLEAN TWIN: re-measuring over the CHANGED tree makes it fresh again -----------------------
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 0 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'PASS') { Write-Output '  PASS  CLEAN TWIN: re-measuring after the change restores PASS - the check is not a one-way trapdoor' }
    else { Write-Output ('  FAIL  a correctly re-measured verdict still read ' + $st.status); $fail++ }

    # ---- MUST FIRE: a BLOCKING verdict over an unchanged tree blocks --------------------------------
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 2 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'BLOCKED' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: a fresh blocking verdict blocks' }
    else { Write-Output ('  FAIL  a blocking verdict did not block (' + $st.status + ')'); $fail++ }

    # ---- MUST FIRE: yesterday's verdict is not today's ----------------------------------------------
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date '2026-09-06' -GuardsRc 0 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'OTHER-DAY' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: a verdict from another day does not ship today' }
    else { Write-Output ('  FAIL  a stale-dated verdict was trusted (' + $st.status + ')'); $fail++ }

    # ---- MUST FIRE: the PRE-LIBRARY shape. This is the literal file that sat in out\ at 14:47 on
    # 2026-09-07 - date, written, guards_rc, guards_blocked, note, and no fingerprint at all. A verdict
    # that records nothing about what it measured cannot be shown to be about this tree.
    $legacy = '{ "date": "2026-09-07", "written": "2026-09-07T08:14:24", "guards_rc": 0, "guards_blocked": false, "note": "written before the fingerprint existed" }'
    $legacy | Set-Content -LiteralPath (Join-Path $fxOut 'chain-verdict.json') -Encoding UTF8
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'STALE-INPUTS' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: a fingerprint-less verdict is not evidence, whatever it claims' }
    else { Write-Output ('  FAIL  a verdict with no fingerprint was trusted (' + $st.status + ')'); $fail++ }

    # ---- MUST FIRE: no file at all is ABSENT, and ABSENT does not ship -------------------------------
    Remove-Item -LiteralPath (Join-Path $fxOut 'chain-verdict.json') -Force
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'ABSENT' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: a missing verdict is ABSENT and does not ship' }
    else { Write-Output ('  FAIL  a missing verdict was not ABSENT (' + $st.status + ')'); $fail++ }

    # ---- CLEAN TWIN: the fingerprint is STABLE across two reads of an unchanged tree. Without this
    # the check would fire on every read and be turned off within a week.
    $f1 = Get-ChainVerdictFingerprint -Repo $tmp
    $f2 = Get-ChainVerdictFingerprint -Repo $tmp
    if ($f1 -eq $f2 -and $f1) { Write-Output '  PASS  CLEAN TWIN: the fingerprint is stable across reads of an unchanged tree' }
    else { Write-Output ("  FAIL  the fingerprint is not stable ($f1 vs $f2) - every verdict would read stale"); $fail++ }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - 5 must-fire (stale PASS after an input moved, a blocking verdict, another day, a fingerprint-less verdict, a missing file) and 3 clean twins'
  exit 0
}

# ---- live path: run guards, write what it returned ------------------------------------------------
$guardsPath = Join-Path $PSScriptRoot 'guards.ps1'
if (-not (Test-Path -LiteralPath $guardsPath)) {
  Write-Output 'BLIND: guards.ps1 not found, so no verdict can be measured'
  Write-GuardComplete -Name 'refresh-chain-verdict' -Summary 'blind=no-guards'
  exit 3
}
$before = Read-ChainVerdictStatus -Repo $repo -OutDir $OutDir
Write-Output ('before: ' + $before.status + ' - ' + $before.why)

$rc = 0
& powershell -NoProfile -ExecutionPolicy Bypass -File $guardsPath | ForEach-Object { Write-Output ('guards: ' + $_) }
$rc = $LASTEXITCODE
Write-Output ("guards exit code: $rc")

if ($WhatIfVerdict) {
  Write-Output ('WhatIf: the verdict WOULD be guards_blocked=' + ([bool]($rc -ne 0)).ToString().ToLower() +
                ' over inputs ' + (Get-ChainVerdictFingerprint -Repo $repo) + '. Nothing was written.')
  exit ([int]($rc -ne 0))
}

$path = Write-ChainVerdict -Repo $repo -OutDir $OutDir -Date ((Get-Date).ToString('yyyy-MM-dd')) -GuardsRc $rc -WrittenBy 'refresh-chain-verdict'
$after = Read-ChainVerdictStatus -Repo $repo -OutDir $OutDir
Write-Output ('after : ' + $after.status + ' - ' + $after.why)
Write-GuardComplete -Name 'refresh-chain-verdict' -Summary ("guards_rc=$rc status=" + $after.status + ' inputs=' + $after.fingerprint_now)
if ($after.status -ne 'PASS') { exit 1 }
exit 0
