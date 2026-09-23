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

    # ---- MUST FIRE: guards rc 4, the QUARANTINED tier (2026-09-21, grocery\cell-quarantine-lib.ps1). The board carries
    # cells held at their last verified price, verified by guards on this board: it SHIPS, and it reads as QUARANTINE,
    # never as a clean PASS and never as BLOCKED - a board with three held cells is neither.
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 4 -WrittenBy 'selftest' -Quarantined 3)
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    $rec = Read-ChainVerdictRecord -Repo $tmp -OutDir $fxOut
    if ($st.status -eq 'QUARANTINE' -and $st.ship_ok -and -not $st.guards_blocked -and $st.why -match '3 cell' -and [string]$rec.verdict -eq 'quarantine' -and -not [bool]$rec.guards_blocked) { Write-Output '  PASS  MUST FIRE: a QUARANTINED verdict (guards rc 4) ships, reads QUARANTINE with its cell count, and is recorded not-blocked' }
    else { Write-Output ('  FAIL  a quarantined verdict read ' + $st.status + ' ship_ok=' + $st.ship_ok + ' (' + $st.why + ')'); $fail++ }
    # ---- MUST FIRE: an rc nothing here knows how to read is held, never a pass
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 5 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'BLOCKED' -and -not $st.ship_ok) { Write-Output '  PASS  MUST FIRE: an unknown guards rc (5) is BLOCKED, never read as a pass' }
    else { Write-Output ('  FAIL  an unknown guards rc read ' + $st.status); $fail++ }

    # ---- MUST FIRE: guards PASSED but export-feed REFUSED (2026-09-23). check-ad-cycles ran export-feed with | Out-Null,
    # so a refusal (exit 3, nothing written) left yesterday's smp-feed.json served while the log said "smp-feed exported"
    # and the board shipped beside it. The verdict now records the refusal and the board does not ship; guards_blocked
    # stays false because guards did pass, and the reason travels to whoever reads the status.
    # Built by concatenation so test-auditors' "emits under another script's name" check does not read this fixture as
    # this script signing export-feed's verdict line.
    $fxWhy = ('export-feed' + ': REFUSED - 1 input') + ' file(s) missing, so the feed would carry an emptied section: grocery\out\recipe-costs.json'
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 0 -WrittenBy 'selftest' -FeedRefused $fxWhy)
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    $rec = Read-ChainVerdictRecord -Repo $tmp -OutDir $fxOut
    if ($st.status -eq 'FEED-REFUSED' -and -not $st.ship_ok -and -not $st.guards_blocked -and $st.why -match 'recipe-costs\.json' -and -not [bool]$rec.feed_refreshed) { Write-Output '  PASS  MUST FIRE: a passing guards verdict whose feed export was REFUSED reads FEED-REFUSED, does not ship, and names the reason' }
    else { Write-Output ('  FAIL  a refused feed export read ' + $st.status + ' ship_ok=' + $st.ship_ok + ' (' + $st.why + ')'); $fail++ }
    # ---- MUST FIRE: a guards-only re-measure (refresh-chain-verdict's live path passes no -FeedRefused) CARRIES today's
    # refusal forward rather than laundering it into a PASS: re-running guards says nothing about the feed.
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 0 -WrittenBy 'selftest')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    if ($st.status -eq 'FEED-REFUSED' -and -not $st.ship_ok -and $st.why -match 'recipe-costs\.json') { Write-Output '  PASS  MUST FIRE: a guards-only rewrite keeps today''s feed refusal and still does not ship' }
    else { Write-Output ('  FAIL  a guards-only rewrite dropped the feed refusal and read ' + $st.status); $fail++ }
    # ---- CLEAN TWIN: the chain's next run exports the feed (-FeedRefused '') and the board ships again as a PASS
    [void](Write-ChainVerdict -Repo $tmp -OutDir $fxOut -Date $today -GuardsRc 0 -WrittenBy 'selftest' -FeedRefused '')
    $st = Read-ChainVerdictStatus -Repo $tmp -OutDir $fxOut -Today $today
    $rec = Read-ChainVerdictRecord -Repo $tmp -OutDir $fxOut
    if ($st.status -eq 'PASS' -and $st.ship_ok -and [bool]$rec.feed_refreshed -and [string]$rec.feed_refused -eq '') { Write-Output '  PASS  CLEAN TWIN: a refreshed feed (-FeedRefused empty) records feed_refreshed=true and ships as PASS' }
    else { Write-Output ('  FAIL  a refreshed feed read ' + $st.status + ' feed_refreshed=' + [string]$rec.feed_refreshed); $fail++ }

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
  Write-Output 'SELF-TEST PASS - 9 must-fire (stale PASS after an input moved, a blocking verdict, a quarantined verdict that ships as QUARANTINE, an unknown rc held, a refused feed export held, that refusal carried through a guards-only rewrite, another day, a fingerprint-less verdict, a missing file) and 4 clean twins'
  exit 0
}

# ---- live path: run guards, write what it returned ------------------------------------------------
$guardsPath = Join-Path $PSScriptRoot 'guards.ps1'
if (-not (Test-Path -LiteralPath $guardsPath)) {
  Write-Output 'BLIND: guards.ps1 not found, so no verdict can be measured'
  Exit-Guard -Name 'refresh-chain-verdict' -Summary 'blind=no-guards' -Code 3
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
