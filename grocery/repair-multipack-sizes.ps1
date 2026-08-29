<#
  repair-multipack-sizes.ps1 - fix a size that records ONE unit of a pack the name already counted.

  WHY IT EXISTS. Guard 5 hard-fails a row whose NAME declares a pack and whose SIZE is one unit of it,
  because taken at face value that row publishes a per-unit price at Nx the truth. The gate is right to
  fail closed, but for a subset of those rows nothing is actually unknown: the store told us the count AND
  the per-unit weight in the product name, and only the multiplication is missing. Founding case, and the
  reason this exists - Family Fare's own API returned size "50.5 oz" for
  "Heinz Tomato Ketchup, 2 Pack 50.5 Oz" at $14.99. At face value $0.2968/oz, nearly 2x every other Heinz
  on that same shelf; as 101 oz, $0.1484/oz, exactly where a bulk 2-pack belongs. It turned the nightly
  publish red on 2026-08-01 and there was no way to clear it except an allowlist entry that would have been
  a LIE - the allowlist means "a human checked and the size really is the pack total", and here it is not.

  THE ARITHMETIC LIVES IN multipack-lib.ps1, shared with guards.ps1 and build-walmart-deals.ps1. The
  guard's verdict and this repair must never be able to disagree about what a pack is; two hand-maintained
  copies of one rule is the trap this repo already paid for with pu-lib.

  IT REPAIRS ONLY WHAT THE NAME PROVES. A name with a pack count and NO per-unit weight ("ReaLemon 100%
  Lemon Juice (2 pk)", size "48 fl oz" - the bug guard 5 was built for) is REFUSED and stays a hard fail
  for a human, because inventing a total there is guessing at the exact point the guard exists to stop
  guessing. Two pack counts in one name are refused for the same reason: the total is ambiguous between
  N, M and NxM, and confirming a size against all three is not the same act as choosing one to write.

  ...UNLESS A HUMAN SUPPLIED THE MISSING WEIGHT (2026-08-29, multipack-unit-hints.json). A refusal is the
  right default but it is not a resolution: Aldi's 'OH Snap Pickling CO Dilly Bites 6pk 6 EA' at size
  "3.25 oz" sat as a guard-5 HARD FAIL for three days and held the whole board off the edge, and neither
  way out was honest - a multipack-allowlist entry asserts "the size IS the pack total", which here is
  false. What was actually missing was one fact, the weight of a single unit, and a human can read that
  off the package. So a hint supplies THE WEIGHT AND NOTHING ELSE: this script appends it to the name and
  runs the UNCHANGED Get-MpRepairedSize over the result, which means the multiplication is still the one
  shared multipack-lib code path and the guard's verdict still cannot disagree with the repair. A hint
  that does not produce a repair is reported as a BAD HINT rather than silently doing nothing, and every
  hint is keyed on store + exact name + exact size, so any drift in the store's own data voids it and the
  row returns to being a human's problem.

  DRY RUN by default. -Apply rewrites the size in place and stamps `size_repaired` on the row so the change
  is visible to anything that reads it afterwards, rather than looking like the store's own number.

  Usage:
    .\repair-multipack-sizes.ps1
    .\repair-multipack-sizes.ps1 -Apply
    .\repair-multipack-sizes.ps1 -SelfTest
#>
param(
  [switch]$Apply,
  [string]$RegularDir = '',
  [string]$Root = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $RegularDir) { $RegularDir = Join-Path $Root 'out\regular' }
. (Join-Path $Root 'multipack-lib.ps1')

if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Write-Output ('  PASS  ' + $msg); $script:p++ } else { Write-Output ('  FAIL  ' + $msg); $script:f++ } }
  Write-Output 'repair-multipack-sizes -SelfTest'
  # MUST FIRE: the founding row. Name states 2 packs of 50.5 oz, size records one bottle.
  T ((Get-MpRepairedSize 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz') -eq '2 pk 50.5 oz') 'the founding Heinz row repairs to the pack total'
  # MUST REFUSE: guard 5's own founding bug. A pack count with NO per-unit weight cannot be multiplied.
  T ((Get-MpRepairedSize 'ReaLemon 100% Lemon Juice (2 pk)' '48 fl oz') -eq '') 'a pack count with no per-unit weight is REFUSED, not invented'
  # MUST REFUSE: two counts in one name - the total is ambiguous between 2, 6 and 12.
  T ((Get-MpRepairedSize '(2 pack) Pearls Sliced Olives, 6 Pack of 6.5 oz Cans' '6.5 oz') -eq '') 'two pack counts in one name is ambiguous and REFUSED'
  # MUST REFUSE: the size is not the per-unit weight the name states, so we do not know what it is.
  T ((Get-MpRepairedSize 'Something, 2 Pack 50.5 Oz' '12 oz') -eq '') 'a size that is not the name''s per-unit weight is REFUSED'
  # MUST REFUSE: unit families must agree - a name in oz against a size in fl oz is not the same quantity.
  T ((Get-MpRepairedSize 'Juice, 2 Pack 50.5 Oz' '50.5 fl oz') -eq '') 'a unit-family mismatch between name and size is REFUSED'
  # MUST NOT TOUCH a correct row: the size already IS the pack total.
  T ((Get-MpRepairedSize '(12 pack) Great Value Great Northern Beans, 15.5 oz' '186.4 oz') -eq '') 'a size that is already the pack total is left alone'
  # THE REPAIR MUST SATISFY THE GUARD, or it is decoration. Round-trip through the shared classifier.
  $rep = Get-MpRepairedSize 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz'
  T ((Test-MpClassify 'Family Fare' 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' '50.5 oz' @()) -eq 'reject') 'the unrepaired row is still a guard-5 reject'
  T ((Test-MpClassify 'Family Fare' 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz' $rep @()) -ne 'reject') 'the REPAIRED row passes the same guard that rejected it'

  # ---- THE HINT PATH (2026-08-29). A hint supplies the one weight the name omitted and NOTHING else, so
  # every case below runs through the same Get-MpRepairedSize as the cases above - that is the property
  # worth testing. The founding row is Aldi's Dilly Bites, which held the board for three days.
  $dillyName = 'OH Snap Pickling CO Dilly Bites 6pk 6 EA'
  T ((Get-MpRepairedSize $dillyName '3.25 oz') -eq '') 'the founding Dilly Bites row REFUSES on its name alone'
  $dillyFix = Get-MpRepairedSize ($dillyName + ' 3.25 oz') '3.25 oz'
  T ($dillyFix -eq '6 pk 3.25 oz') 'with the hinted unit weight it repairs to the 6-pack total'
  T ((Test-MpClassify 'Aldi' $dillyName '3.25 oz' @()) -eq 'reject') 'the unhinted Dilly Bites row is a guard-5 reject'
  T ((Test-MpClassify 'Aldi' $dillyName $dillyFix @()) -ne 'reject') 'the HINTED repair passes the same guard that rejected it'
  # A hint is evidence, not permission: one that disagrees with the recorded size must still refuse, or
  # the file becomes a way to wave rows through and the guard is decoration.
  T ((Get-MpRepairedSize ($dillyName + ' 8 oz') '3.25 oz') -eq '') 'a hint that disagrees with the recorded size is REFUSED (reported as a BAD HINT)'
  # And a hint cannot rescue the genuinely ambiguous two-count case - appending a weight leaves both counts.
  T ((Get-MpRepairedSize '(2 pack) Pearls Sliced Olives, 6 Pack of 6.5 oz Cans 6.5 oz' '6.5 oz') -eq '') 'a hint cannot resolve two pack counts in one name'
  # The hint FILE itself must parse and every entry must carry a review - an unreviewed hint is a guess
  # wearing a human's authority, which is the one thing this mechanism must never become.
  # Asserted UNCONDITIONALLY, not behind a Test-Path. A missing file is a broken mechanism, and a case
  # that skips itself when its subject disappears is worse than no case: the tally drops, the exit code
  # stays 0, and the suite reports green while testing less than it did yesterday. An empty hints[] is
  # fine and passes both - it is the FILE that has to exist, not any particular ruling in it.
  $hf = Join-Path $Root 'multipack-unit-hints.json'
  $hj = $null
  if (Test-Path $hf) { try { $hj = (Get-Content $hf -Raw | ConvertFrom-Json) } catch { $hj = $null } }
  T ($null -ne $hj) 'multipack-unit-hints.json exists and parses'
  $bad = @(@($hj.hints) | Where-Object { $null -ne $_ } | Where-Object { -not $_.store -or -not $_.item -or -not $_.size -or -not $_.unit_size -or -not $_.reviewed -or -not $_.why })
  T ($null -ne $hj -and $bad.Count -eq 0) 'every hint carries store/item/size/unit_size/reviewed/why'
  if ($f -gt 0) { Write-Output ('repair-multipack-sizes SELFTEST: ' + $f + ' FAILED'); exit 2 }
  Write-Output ('repair-multipack-sizes SELFTEST: all ' + $p + ' passed')
  exit 0
}

if (-not (Test-Path $RegularDir)) { Write-Output ('repair-multipack-sizes: BLIND - no regular dir at ' + $RegularDir); exit 3 }
$allFiles = @(Get-ChildItem (Join-Path $RegularDir '*-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
if ($allFiles.Count -eq 0) { Write-Output ('repair-multipack-sizes: BLIND - no *-regular-*.json in ' + $RegularDir); exit 3 }

# ---- REPAIR WHAT THE BOARD CAN ACTUALLY READ (2026-08-22) ---------------------------------------------
# This walked EVERY *-regular-*.json in the folder - 170 files, 385 MB - on every run, and today's answer
# was "0 repairable, 0 REFUSED" after 38-58 s on the SHIP path, i.e. time spent before the day's prices go
# live. The engine only ever prices from Select-RegularFileSet (the union window, currently 30 of those
# 170 files); a pack size in a file outside that window cannot reach the board, so repairing it changes
# nothing a reader will ever see.
# NOTHING IS LEFT UNREPAIRED BY THIS. Files only age OUT of the union, never into it: a capture is written
# fresh, enters the window immediately, and is walked by every run until it expires. So each file is still
# repaired on every day it can influence a price.
# ONE SOURCE FOR THE WINDOW, deliberately - the same function compare-deals and guards use. A private copy
# here is exactly how this file could start repairing a different set than the board prices from, which is
# the drift class the union self-test in compare-deals exists to catch.
$files = $allFiles
try {
  . (Join-Path $Root 'regular-fileset-lib.ps1')
  $asOfMp = (Get-Date).Date
  $sel = @(Select-RegularFileSet $allFiles $asOfMp (Get-RegularUnionDays))
  if ($sel.Count -gt 0) { $files = @($sel | Sort-Object Name) }
  else { Write-Output '  note: the engine file set came back EMPTY - repairing every capture instead, because a repair that examines nothing is worse than a slow one' }
} catch {
  # Fail OPEN to the old behaviour: a repair that silently examined a SMALLER set than it reported would
  # be the confident-ok-over-an-empty-examination shape this estate keeps rediscovering.
  Write-Output ('  note: could not resolve the engine file set (' + $_.Exception.Message + ') - repairing every capture')
}
Write-Output ('repair-multipack-sizes: examining ' + $files.Count + ' of ' + $allFiles.Count + ' capture file(s) - the ones inside the engine union window')

$allow = Get-MpAllowKeys $Root
# Reviewed per-unit weights for names that count a pack and state no weight. Keyed store|item|size so any
# drift in the store's own row voids the review. Load failures are NOT fatal and NOT silent: with no hints
# every row simply refuses exactly as it did before this file existed, which is the safe direction.
$hints = @{}
$hintFile = Join-Path $Root 'multipack-unit-hints.json'
if (Test-Path $hintFile) {
  try {
    foreach ($h in @((Get-Content $hintFile -Raw | ConvertFrom-Json).hints)) {
      if ($null -eq $h) { continue }
      $k = [string]$h.store + '|' + [string]$h.item + '|' + [string]$h.size
      if (-not $hints.ContainsKey($k)) { $hints[$k] = [string]$h.unit_size }
    }
  } catch { Write-Output ('  WARN  multipack-unit-hints.json unreadable (' + $_.Exception.Message + ') - every refusal stands') }
}
$hintsUsed = @{}
$repaired = 0; $refused = 0; $examined = 0; $hinted = 0
$refusedRows = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $files) {
  $raw = ((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) + '').Trim()
  if ($raw -eq '') { Write-Output ('  SKIP ' + $file.Name + ' - empty on disk (unreadable, not "no rows")'); continue }
  $doc = $raw | ConvertFrom-Json
  if ($null -eq $doc) { Write-Output ('  SKIP ' + $file.Name + ' - parsed to null'); continue }
  $touched = 0
  foreach ($d in @($doc.deals)) {
    if ($null -eq $d) { continue }
    $name = [string]$d.item; $size = [string]$d.size
    if ((Test-MpClassify ([string]$doc.store) $name $size $allow) -ne 'reject') { continue }
    $examined++
    $fix = Get-MpRepairedSize $name $size
    $viaHint = ''
    if ($fix -eq '') {
      # The name alone proves nothing. Ask whether a human already read the per-unit weight off the
      # package: if so, hand the SAME function a name that states it and let it do the same arithmetic.
      $hk = [string]$doc.store + '|' + $name + '|' + $size
      if ($hints.ContainsKey($hk) -and $hints[$hk]) {
        $viaHint = $hints[$hk]
        $fix = Get-MpRepairedSize ($name + ' ' + $viaHint) $size
        if ($fix -eq '') {
          # A hint that does not repair is a BAD hint - the weight does not agree with the recorded size,
          # or the name carries a second pack count. Say so; never let it pass as an ordinary refusal.
          $refused++
          $hintsUsed[$hk] = $true
          $refusedRows.Add(('  BAD HINT [' + [string]$doc.store + '] ''' + $name + ''' size=[' + $size + '] - multipack-unit-hints.json offers unit_size=[' + $viaHint + '] but that does not reconcile with the recorded size. Re-read the package; do NOT widen the hint to fit.'))
          continue
        }
        $hintsUsed[$hk] = $true
        $hinted++
      }
    }
    if ($fix -eq '') {
      $refused++
      $refusedRows.Add(('  REFUSED [' + [string]$doc.store + '] ''' + $name + ''' size=[' + $size + '] - the name does not state a per-unit weight to multiply. This stays a HARD FAIL for a human (multipack-allowlist.json, or supply the unit weight in multipack-unit-hints.json).'))
      continue
    }
    $how = if ($viaHint) { '  (per-unit weight ' + $viaHint + ' from a reviewed hint, not from the name)' } else { '' }
    Write-Output ('  REPAIR  [' + [string]$doc.store + '] ''' + $name + '''  size [' + $size + '] -> [' + $fix + ']' + $how)
    if ($Apply) {
      $d.size = $fix
      if ($d.PSObject.Properties['size_repaired']) { $d.size_repaired = $size } else { $d | Add-Member -NotePropertyName size_repaired -NotePropertyValue $size -Force }
      $touched++
    }
    $repaired++
  }
  if ($Apply -and $touched -gt 0) {
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $file.FullName -Encoding UTF8
    Write-Output ('  wrote ' + $file.Name + ' (' + $touched + ' size(s) repaired)')
  }
}
foreach ($r in $refusedRows) { Write-Output $r }
# A hint nobody used is either finished work or a review that has quietly stopped applying, and the two
# look identical from here. Name them rather than let the file accumulate rulings about rows that no
# longer exist - an unread exception is how an allowlist outlives the thing it was excusing.
foreach ($k in @($hints.Keys | Where-Object { -not $hintsUsed.ContainsKey($_) } | Sort-Object)) {
  Write-Output ('  UNUSED HINT  ' + $k + ' - no row in the union window matches this store+name+size. Either the store fixed it (delete the hint) or the row moved out of the window.')
}
Write-Output ('repair-multipack-sizes: ' + $files.Count + ' file(s), ' + $examined + ' guard-5 reject(s) examined, ' +
  $repaired + ' repairable (' + $hinted + ' via a reviewed unit-weight hint), ' + $refused + ' REFUSED (need a human)' + $(if ($Apply) { ' - APPLIED' } else { ' - dry run, pass -Apply to write' }))
exit 0
