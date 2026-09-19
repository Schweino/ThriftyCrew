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
  Since 2026-09-19 holding rows is not enough: Test-CaptureSliceLanded also needs at least one
  row FOUND BY a term of the store's current slice and dated today, because the files are
  cumulative and a capture can bring back only owed terms. Replayed over the cursor log that
  day, it would have held three real advances that skipped their slice (Sam's 08-22 #0,
  Fareway 08-22 #14, Walmart 08-30 #28) and passed every advance since 2026-09-01.

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
  $r1 = Step-CaptureCursor -Store 'Walmart' -Today (Get-Date).ToString('yyyy-MM-dd') -OutDir $tmp
  if ($r1.Advanced) { Write-Output 'FAIL  a store with no landed capture advanced its cursor - that is the skip-the-slice bug'; $fail++ }
  else { Write-Output 'ok    no landed capture -> cursor held' }

  # THE SLICE HAS TO BE IN THE ROWS (2026-09-19). A landed file only moves the cursor when at least one
  # row was found by a term of the store's CURRENT slice and is dated today; see Test-CaptureSliceLanded.
  # So every fixture that means "a real capture landed" writes a row the slice would have produced.
  $ccTerms = @(Get-AllTerms)
  $ccToday = (Get-Date).ToString('yyyy-MM-dd')
  function Write-CcRows([string]$Rel, [object[]]$Rows) {
    $doc = @{ deals = @($Rows) } | ConvertTo-Json -Depth 4
    $path = Join-Path $tmp $Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $doc, (New-Object System.Text.UTF8Encoding($false)))
  }
  function New-CcRow([string]$Term, [string]$AsOf) {
    return @{ item = 'x'; ad_price = '$1.00'; found_by_term = $Term; as_of = $AsOf }
  }
  function Get-CcSliceTerm([string]$Store) { return [string]$ccTerms[(Get-CaptureCursor -Store $Store -OutDir $tmp) % $ccTerms.Count].term }
  $wmRel = "regular\walmart-regular-$ccToday.json"
  # Each MUST FIRE starts from a fresh ledger. Without this, the first case a mutant lets through sets
  # Walmart_last to today and the day guard holds every later case for the wrong reason, so they pass
  # over a broken check and the probe cannot see which half failed.
  function Reset-CcCursor { Remove-Item -LiteralPath (Join-Path $tmp 'capture-cursor.json') -Force -ErrorAction SilentlyContinue }

  # MUST FIRE: ZERO CAPTURED ROWS. The builder wrote today's file and it holds nothing - the 333 raw -> 0
  # priced day of 2026-08-22, and the shape a sweep with no terms to ask leaves behind.
  Write-CcRows $wmRel @()
  Reset-CcCursor
  $rz = Step-CaptureCursor -Store 'Walmart' -Today $ccToday -OutDir $tmp
  if ($rz.Advanced) { Write-Output "FAIL  zero captured rows advanced the cursor $($rz.From) -> $($rz.To) - the slice is skipped for a quarter"; $fail++ }
  else { Write-Output "ok    zero captured rows -> cursor held ($($rz.Reason))" }

  # MUST FIRE: rows landed today, but from terms OUTSIDE the slice - an owed ruling term or a sale expiry
  # only, which is what a sweep that lost the rotation half of its worklist brings back.
  $offTerm = [string]$ccTerms[((Get-CaptureCursor -Store 'Walmart' -OutDir $tmp) + 300) % $ccTerms.Count].term
  Write-CcRows $wmRel @((New-CcRow $offTerm $ccToday), (New-CcRow $offTerm $ccToday))
  Reset-CcCursor
  $ro = Step-CaptureCursor -Store 'Walmart' -Today $ccToday -OutDir $tmp
  if ($ro.Advanced) { Write-Output "FAIL  rows found only by a term outside the slice ('$offTerm') advanced the cursor - the slice was never asked"; $fail++ }
  else { Write-Output "ok    rows from outside the slice only -> cursor held ($($ro.Reason))" }

  # MUST FIRE: a CUMULATIVE file carrying the slice from an EARLIER day. aldi-regular holds 3,345 rows of
  # which 436 were read on 2026-09-17; a rebuild with nothing new still writes today's file full of rows.
  Write-CcRows $wmRel @((New-CcRow (Get-CcSliceTerm 'Walmart') '2026-08-15'))
  Reset-CcCursor
  $rc = Step-CaptureCursor -Store 'Walmart' -Today $ccToday -OutDir $tmp
  if ($rc.Advanced) { Write-Output 'FAIL  slice rows carried forward from 2026-08-15 advanced the cursor - a carry-forward is not a capture'; $fail++ }
  else { Write-Output "ok    slice rows dated an earlier day -> cursor held ($($rc.Reason))" }

  # MUST FIRE: rows that name no term are a could-not-look, and a could-not-look repeats rather than skips.
  Write-CcRows $wmRel @(@{ item = 'x'; ad_price = '$1.00'; as_of = $ccToday })
  Reset-CcCursor
  $rn = Step-CaptureCursor -Store 'Walmart' -Today $ccToday -OutDir $tmp
  if ($rn.Advanced) { Write-Output 'FAIL  rows naming no found_by_term advanced the cursor - whether the slice landed could not be seen'; $fail++ }
  else { Write-Output "ok    rows naming no term -> cursor held ($($rn.Reason))" }

  # MUST FIRE, SAM'S CLUB, THE STORE THIS WAS ASKED ABOUT: its deals file lives under out\sams, not
  # out\regular. An empty one must hold the Sam's cursor.
  $samsRel = "sams\sams-deals-$ccToday.json"
  Write-CcRows $samsRel @()
  Reset-CcCursor
  $rs0 = Step-CaptureCursor -Store "Sam's Club" -Today $ccToday -OutDir $tmp
  if ($rs0.Advanced) { Write-Output "FAIL  an empty Sam's deals file advanced the Sam's cursor $($rs0.From) -> $($rs0.To)"; $fail++ }
  else { Write-Output "ok    empty Sam's deals file -> Sam's cursor held" }

  # CLEAN TWIN, SAM'S: the 2026-09-17 shape - one owed term plus the slice, all read today - still advances.
  Write-CcRows $samsRel @((New-CcRow $offTerm $ccToday), (New-CcRow (Get-CcSliceTerm "Sam's Club") $ccToday))
  $rs1 = Step-CaptureCursor -Store "Sam's Club" -Today $ccToday -OutDir $tmp
  if (-not $rs1.Advanced) { Write-Output "FAIL  a real Sam's capture of its slice did NOT advance ($($rs1.Reason))"; $fail++ }
  else { Write-Output "ok    Sam's capture of its slice -> cursor $($rs1.From) -> $($rs1.To)" }

  # CLEAN TWIN: a real capture landed -> the cursor must move by the rotation size. The file is cumulative
  # on purpose, as the real ones are: carried rows beside one slice row read today.
  Reset-CcCursor
  Write-CcRows $wmRel @((New-CcRow $offTerm '2026-08-15'), (New-CcRow (Get-CcSliceTerm 'Walmart') $ccToday))
  $r2 = Step-CaptureCursor -Store 'Walmart' -Today (Get-Date).ToString('yyyy-MM-dd') -OutDir $tmp
  if (-not $r2.Advanced) { Write-Output "FAIL  a landed capture did NOT advance the cursor ($($r2.Reason))"; $fail++ }
  elseif ($r2.To -le $r2.From) { Write-Output "FAIL  cursor went backwards or nowhere: $($r2.From) -> $($r2.To)"; $fail++ }
  else { Write-Output "ok    landed capture -> cursor $($r2.From) -> $($r2.To)" }

  # MUST-FIRE fixture #2: calling again the SAME day must NOT rotate again. This is the bug
  # this hook shipped with on 2026-08-21 - the commit lives in the builder, a builder can run
  # several times a day, and each run advanced another 7 terms. Fareway reached #63, nine
  # slices ahead, on a day it had landed one capture. Over-advancing skips terms for a whole
  # quarter; repeating one merely costs a few requests.
  $r3 = Step-CaptureCursor -Store 'Walmart' -Today (Get-Date).ToString('yyyy-MM-dd') -OutDir $tmp
  if ($r3.Advanced) { Write-Output "FAIL  a second build the same day rotated AGAIN ($($r2.To) -> $($r3.To)) - the rotation sprints past uncaptured terms"; $fail++ }
  else { Write-Output 'ok    second build the same day held the cursor' }

  # ...but on a NEW day it must move again, or the guard has frozen the rotation instead of
  # rate-limiting it.
  # SIMULATED BY AGEING THE LEDGER, NOT BY FAKING THE DATE. The first version of this case passed
  # -Today 2026-08-22 to mean "tomorrow", which the replay guard now correctly refuses - a future or
  # past date is exactly what a self-test or a rebuild looks like, and that is the thing that moved
  # Fareway seven slices. What the day-guard actually keys on is <store>_last, so rolling that back a
  # day is what "a new day" genuinely means to it, and the run still carries today's real date.
  $realToday = (Get-Date).ToString('yyyy-MM-dd')
  Write-CcRows $wmRel @((New-CcRow (Get-CcSliceTerm 'Walmart') $realToday))
  $cf = Join-Path $tmp 'capture-cursor.json'
  $cj = ConvertFrom-Json ([IO.File]::ReadAllText($cf))
  $cj.Walmart_last = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
  [IO.File]::WriteAllText($cf, ($cj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $r4 = Step-CaptureCursor -Store 'Walmart' -Today $realToday -OutDir $tmp
  if (-not $r4.Advanced) { Write-Output "FAIL  a new day did NOT advance ($($r4.Reason)) - the day-guard froze the rotation instead of rate-limiting it"; $fail++ }
  else { Write-Output "ok    a new day advanced $($r4.From) -> $($r4.To)" }

  # MUST-FIRE fixture #3: a REPLAY must not advance the live rotation. This is the bug the advance log
  # caught on the day the day-guard shipped: build-fareway-regular's SELF-TEST builds with frozen
  # fixture dates (2026-07-31, 2026-08-01), and the day-guard compares against the date it was PASSED,
  # so a fixture date never matched <store>_last and every self-test run advanced the production
  # cursor. Fareway went #7 -> #63 in two hours that way. A test must not move live state.
  @(@{ item = 'x'; ad_price = '$1.00' }) | ConvertTo-Json |
    Set-Content (Join-Path $tmp "regular\walmart-regular-2026-07-31.json") -Encoding UTF8
  $r5 = Step-CaptureCursor -Store 'Walmart' -Today '2026-07-31' -OutDir $tmp
  if ($r5.Advanced) { Write-Output "FAIL  a replay dated 2026-07-31 advanced the live cursor - a self-test can move production"; $fail++ }
  else { Write-Output 'ok    a replay/self-test date is refused, however landed its capture looks' }

  # The ONE rotation that is not a term rotation must refuse, not silently no-op. Hy-Vee indexes 1,554
  # PRODUCT IDS and keeps hyvee-rotation-cursor.json; the same integer must not mean two things.
  $r = Step-CaptureCursor -Store 'Hy-Vee' -Today (Get-Date).ToString('yyyy-MM-dd') -OutDir $tmp
  if ($r.Advanced -or $r.Reason -notmatch 'product id') { Write-Output "FAIL  Hy-Vee got a TERM cursor - its rotation is a different namespace"; $fail++ }
  else { Write-Output 'ok    Hy-Vee correctly excluded from the term cursor (it rotates by product id)' }
  # BAKER'S IS IN, AS OF 2026-08-22 (Brad: "Bakers should be following the SAME logic as literally
  # everyone else"). It used to pull all 598 terms every day and was excluded here for that reason.
  # It now rotates over the SAME term list as the other five, so it must be ACCEPTED - and this case
  # fails on the code that shipped before that change, where it was refused as "comprehensive".
  # -Landed is passed because Baker's own file always carries its full row count (the un-asked terms
  # are carried forward), so Test-CaptureLanded cannot tell a good day from a dead endpoint there.
  $rb = Step-CaptureCursor -Store "Baker's" -Today (Get-Date).ToString('yyyy-MM-dd') -OutDir $tmp -Landed $true
  if ($rb.Advanced -and $rb.To -gt 0) { Write-Output ("ok    Baker's now takes a term cursor and advanced #" + $rb.From + ' -> #' + $rb.To) }
  else { Write-Output ("FAIL  Baker's did not get its term cursor: " + $rb.Reason); $fail++ }

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

# THE EXPIRY LEDGER MOVES ON THE SAME EVIDENCE AS THE CURSOR (2026-08-22). This script is
# already the one CLI every builder calls after its capture, and "did the data land?" is the
# same question both writes depend on. Recording it here - rather than in each builder - is
# the same reason this file exists at all: four inline copies of one rule is the duplicated-
# rule trap. Unlike the cursor this is NOT term-rotation-only; every store owes re-prices.
# Non-fatal: a re-price that happened but could not be recorded is simply asked for again.
try {
  $mk = Set-SaleExpiryProcessed -Store $Store -Today $todayS -OutDir $OutDir
  if ($mk.Marked -gt 0) {
    Write-Output ("expiry: {0} recorded {1} re-price(s) - they can now be pruned from sale-windows.json" -f $Store, $mk.Marked)
  } else {
    Write-Output ("expiry: {0} recorded none - {1}" -f $Store, $mk.Reason)
  }
} catch { Write-Warning ("expiry ledger not updated for $Store (" + $_.Exception.Message + ") - the re-price stays owed and leads tomorrow's slice") }
exit 0

