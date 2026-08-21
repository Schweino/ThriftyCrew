<#
  commit-capture-cursor.ps1 - advance ONE store's quarterly rotation cursor, after its
  capture has actually landed.

  WHY THIS EXISTS. capture-policy.ps1 has shipped Save-CaptureCursor since 2026-08-20 with
  the rule written down beside it - "advance it only AFTER the capture lands" - and on
  2026-08-21 a census found the function had ZERO production callers. Its only three
  references in the whole repo were its own definition and two prose notes. The visible
  consequence: capture-cursor.json held no store keys at all, every store's rotation sat
  at index 0, and two consecutive days emitted a byte-identical worklist:

      walmart 08-20: cursor_start=0 terms= 15 bean soup mix, 93/7 lean ground beef, ...
      walmart 08-21: cursor_start=0 terms= 15 bean soup mix, 93/7 lean ground beef, ...

  Seven of 596 terms captured forever, the other 589 expiring at the 90-day carry because
  their turn never came round. A quarterly rotation that cannot advance is not a slower
  rotation; it is no rotation, with the first 7 terms standing in for a whole catalogue.

  WHY A SCRIPT AND NOT A LINE IN EACH BUILDER. The four walled stores are built by four
  separate processes (build-walmart-deals, build-sams-deals, build-aldi-regular,
  build-fareway-regular), and the headless lanes are separate again. Four inline copies of
  "work out the next index and write it" is the duplicated-rule trap this estate keeps
  paying for. The rule lives in capture-policy's Step-CaptureCursor; this is just the CLI
  in front of it so a builder needs one line.

  Landing is judged from the DATA, not an exit code: Test-CaptureLanded asks whether the
  store's out\regular\<prefix>-regular-<date>.json exists and holds rows. A lane that
  exits 0 having bought nothing must re-attempt the same slice tomorrow, never skip it.

  Usage:
      .\commit-capture-cursor.ps1 -Store Walmart -Date 2026-08-21
      .\commit-capture-cursor.ps1 -Report          # every store, no writes
      .\commit-capture-cursor.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [string]$Store = '',
  [string]$Date = '',
  [string]$OutDir = '',
  [switch]$Report,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'capture-policy-lib.ps1')

$todayS = if ($Date) { $Date } else { (Get-Date).ToString('yyyy-MM-dd') }

# ---------------------------------------------------------------------------
if ($SelfTest) {
  # A guard ships a frozen fixture of the bug that created it plus a clean twin, so the
  # test can FAIL as well as pass. The founding bug here is "a cursor that never moves".
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cursor-selftest-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $tmp 'regular') -Force | Out-Null
  $fail = 0

  # MUST-FIRE fixture: no capture landed -> the cursor must NOT move.
  $r1 = Step-CaptureCursor -Store 'Walmart' -Today '2026-08-21' -OutDir $tmp
  if ($r1.Advanced) { Write-Output 'FAIL  a store with no landed capture advanced its cursor - that is the skip-the-slice bug'; $fail++ }
  else { Write-Output 'ok    no landed capture -> cursor held' }

  # CLEAN TWIN: a real capture landed -> the cursor must move by the rotation size.
  $prefix = 'walmart'
  @(@{ item = 'x'; ad_price = '$1.00' }) | ConvertTo-Json |
    Set-Content (Join-Path $tmp ("regular\{0}-regular-2026-08-21.json" -f $prefix)) -Encoding UTF8
  $r2 = Step-CaptureCursor -Store 'Walmart' -Today '2026-08-21' -OutDir $tmp
  if (-not $r2.Advanced) { Write-Output "FAIL  a landed capture did NOT advance the cursor ($($r2.Reason))"; $fail++ }
  elseif ($r2.To -le $r2.From) { Write-Output "FAIL  cursor went backwards or nowhere: $($r2.From) -> $($r2.To)"; $fail++ }
  else { Write-Output "ok    landed capture -> cursor $($r2.From) -> $($r2.To)" }

  # MUST-FIRE fixture #2: calling again the SAME day must NOT rotate again. This is the bug
  # this hook shipped with on 2026-08-21 - the commit lives in the builder, a builder can run
  # several times a day, and each run advanced another 7 terms. Fareway reached #63, nine
  # slices ahead, on a day it had landed one capture. Over-advancing skips terms for a whole
  # quarter; repeating one merely costs a few requests.
  $r3 = Step-CaptureCursor -Store 'Walmart' -Today '2026-08-21' -OutDir $tmp
  if ($r3.Advanced) { Write-Output "FAIL  a second build the same day rotated AGAIN ($($r2.To) -> $($r3.To)) - the rotation sprints past uncaptured terms"; $fail++ }
  else { Write-Output 'ok    second build the same day held the cursor' }

  # ...but the NEXT day it must move again, or the guard has frozen the rotation instead of
  # rate-limiting it.
  @(@{ item = 'x'; ad_price = '$1.00' }) | ConvertTo-Json |
    Set-Content (Join-Path $tmp "regular\walmart-regular-2026-08-22.json") -Encoding UTF8
  $r4 = Step-CaptureCursor -Store 'Walmart' -Today '2026-08-22' -OutDir $tmp
  if (-not $r4.Advanced) { Write-Output "FAIL  the next day did NOT advance ($($r4.Reason)) - the day-guard froze the rotation"; $fail++ }
  else { Write-Output "ok    next day advanced $($r4.From) -> $($r4.To)" }

  # The two rotations that are NOT term rotations must refuse, not silently no-op.
  foreach ($s in @('Hy-Vee', "Baker's")) {
    $r = Step-CaptureCursor -Store $s -Today '2026-08-21' -OutDir $tmp
    if ($r.Advanced) { Write-Output "FAIL  $s got a TERM cursor - its rotation is a different namespace"; $fail++ }
    else { Write-Output "ok    $s correctly excluded from the term cursor" }
  }

  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Output ("SELFTEST " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
  exit $(if ($fail) { 1 } else { 0 })
}

# ---------------------------------------------------------------------------
if ($Report -or -not $Store) {
  Write-Output ("capture cursors - " + $todayS)
  Write-Output ''
  foreach ($s in @('Family Fare', 'Walmart', "Sam's Club", 'Aldi', 'Fareway', 'Hy-Vee', "Baker's")) {
    if (-not (Test-TermRotationStore $s)) {
      Write-Output ("  {0,-12} n/a   (not a term rotation)" -f $s)
      continue
    }
    $cur = Get-CaptureCursor -Store $s -OutDir $OutDir
    $landed = Test-CaptureLanded -Store $s -Today $todayS -OutDir $OutDir
    $plan = Get-CapturePlan -Store $s -Today $todayS
    Write-Output ("  {0,-12} #{1,-4} landed_today={2,-5} rotation={3}/day" -f $s, $cur, $landed, $plan.RotationTerms)
  }
  exit 0
}

$res = Step-CaptureCursor -Store $Store -Today $todayS -OutDir $OutDir
if ($res.Advanced) {
  Write-Output ("cursor: {0} #{1} -> #{2} ({3})" -f $res.Store, $res.From, $res.To, $res.Reason)
} else {
  Write-Output ("cursor: {0} held at #{1} - {2}" -f $res.Store, $res.From, $res.Reason)
}
exit 0

