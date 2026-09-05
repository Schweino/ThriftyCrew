<#
  audit-board-reconciliation.ps1 - the same fact must not be published twice.

  WHY THIS EXISTS (2026-08-08). This estate keeps rediscovering one root cause under five different
  names: two-copies-of-a-rule, repair-stops-at-source-of-truth, recipe-board-blind-spot,
  orphan-name-is-never-display-only, shared-item-carrying-a-brand. Every one is the same disease -
  THE SAME FACT LIVES IN MORE THAN ONE PLACE AND NOTHING PROVES THE COPIES AGREE - and every fix so
  far has been per-instance. This is the check that covers the class.

  THE FOUNDING BUG. The site publishes two boards: the weekly staples board (comparison-*.json) and the
  recipe-ingredient board (recipe-board.json). recipe-overlay.ps1 has dropped any recipe row whose id also
  lives on the weekly board since 2026-07-30, under the rule "the fresh row owns the id", and that filter
  works - 0 rows collided by literal id. But the two namespaces spell 33 shared commodities differently
  (93-7-ground-beef against ground-beef-93-7, beef-chuck-roast against chuck-roast). Comparing raw ids
  cannot see through a rename, so 33 of the 80 recipe rows survived as stale duplicates of a fresher
  weekly row and the site served both numbers at once. Measured that day: beef chuck roast at Family Fare
  was $8.49 on one board and $10.99 on the other, diced green chiles at Hy-Vee were 39% apart.

  recipe-floor-id-map.json is the bridge that proves which pairs are the same commodity, and it is the
  same file the de-dup now consults. This audit is the independent second opinion on that: it re-derives
  the collision set from the data every run, so the day someone adds a mapping without teaching the
  de-dup about it, this fires instead of the site quietly publishing two prices again.

  UNITS ARE NORMALIZED BEFORE ANY PRICE IS CALLED A CONTRADICTION. The first pass at this measurement
  reported 15 contradictions and 6 of them were false: flour at $0.39/lb against $0.0244/oz is the SAME
  price written two ways. Weight and volume are NOT interchangeable, so oz and fl oz are never folded
  together - that difference is reported as a basis disagreement, which is its own defect class and a
  worse one, not as a price contradiction.

  EXIT CODES
    0 = ran, no commodity is published twice
    2 = a commodity is published on both boards. HARD. This is structural, not statistical: the de-dup
        either ran or it did not, there is no judgement call, and the failure mode is two contradictory
        prices in front of a shopper.
    1 = boards are de-duplicated but a price/basis contradiction was still found by another path (advisory)
    3 = could not evaluate (no boards to read, or rows existed and none were examined)
#>
param([string]$OutDir = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

# oz and lb are the same physical quantity, so a per-lb price and a per-oz price ARE comparable and must
# be folded before comparison or every one of them reads as a 16x contradiction. fl oz is volume and is
# deliberately absent: it never converts to a weight unit here.
function ConvertTo-PerOz {
  param([double]$Value, [string]$Unit)
  switch (([string]$Unit).ToLower().Trim()) {
    'lb'  { return $Value / 16.0 }
    'lbs' { return $Value / 16.0 }
    'oz'  { return $Value }
    default { return $null }   # each, floz, ct, unknown: not convertible, compare only like-for-like
  }
}

function Get-ReconciliationFindings {
  param([string]$Dir, [string]$MapFile)

  $cmpF = Get-ChildItem (Join-Path $Dir 'comparison-*.json') -EA SilentlyContinue |
    Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Desc | Select-Object -First 1
  $rbF  = Join-Path $Dir 'recipe-board.json'
  if (-not $cmpF -or -not (Test-Path $rbF)) { return $null }

  $weeklyRows = @((Read-JsonFile $cmpF.FullName).comparison)
  $recipeRows = @((Read-JsonFile $rbF).comparison)

  $idMap = @{}
  if ($MapFile -and (Test-Path $MapFile)) {
    try { foreach ($p in ((Read-JsonFile $MapFile).map.PSObject.Properties)) { $idMap[[string]$p.Name] = [string]$p.Value } } catch { }
  }
  $weeklyById = @{}
  foreach ($r in $weeklyRows) { $weeklyById[[string]$r.id] = $r }

  $dupes = New-Object System.Collections.ArrayList
  $contra = New-Object System.Collections.ArrayList
  $examined = 0
  foreach ($rr in $recipeRows) {
    $rid = [string]$rr.id
    $examined++
    $wid = $null
    if ($weeklyById.ContainsKey($rid)) { $wid = $rid; $how = 'literal id' }
    elseif ($idMap.ContainsKey($rid) -and $weeklyById.ContainsKey($idMap[$rid])) { $wid = $idMap[$rid]; $how = 'recipe-floor-id-map' }
    if (-not $wid) { continue }

    $wr = $weeklyById[$wid]
    [void]$dupes.Add([pscustomobject]@{ recipe_id = $rid; weekly_id = $wid; via = $how })

    # every store the two rows share, compared like-for-like
    foreach ($rs in @($rr.stores)) {
      $ws = @($wr.stores) | Where-Object { [string]$_.store -eq [string]$rs.store } | Select-Object -First 1
      if (-not $ws) { continue }
      $rUnit = [string]$rs.unit; $wUnit = [string]$ws.unit
      $rItem = ([string]$rs.item) -replace '\s+',' '
      $wItem = ([string]$ws.item) -replace '\s+',' '
      if ($rItem -ne $wItem -or -not $rItem) { continue }   # different products can legitimately differ

      $rOz = ConvertTo-PerOz -Value ([double]$rs.per_unit) -Unit $rUnit
      $wOz = ConvertTo-PerOz -Value ([double]$ws.per_unit) -Unit $wUnit
      if ($null -eq $rOz -or $null -eq $wOz) {
        # not convertible to a shared basis. Only a finding when the units actually disagree - the same
        # unit compares directly, and a weight-against-volume pair is a BASIS defect, reported as such.
        if ($rUnit -ne $wUnit) {
          [void]$contra.Add([pscustomobject]@{ kind='basis'; weekly_id=$wid; store=[string]$rs.store
            weekly=("{0}/{1}" -f $ws.per_unit, $wUnit); recipe=("{0}/{1}" -f $rs.per_unit, $rUnit); item=$wItem })
        } elseif ([double]$rs.per_unit -ne [double]$ws.per_unit) {
          [void]$contra.Add([pscustomobject]@{ kind='price'; weekly_id=$wid; store=[string]$rs.store
            weekly=("{0}/{1}" -f $ws.per_unit, $wUnit); recipe=("{0}/{1}" -f $rs.per_unit, $rUnit); item=$wItem })
        }
        continue
      }
      # half-cent-per-oz floor: below that the two sides cannot express a difference, same rule as
      # audit-everyday-mismatch. Anything above it on an identical product string is a real disagreement.
      if ([Math]::Abs($rOz - $wOz) -gt 0.005) {
        [void]$contra.Add([pscustomobject]@{ kind='price'; weekly_id=$wid; store=[string]$rs.store
          weekly=("{0}/{1}" -f $ws.per_unit, $wUnit); recipe=("{0}/{1}" -f $rs.per_unit, $rUnit); item=$wItem })
      }
    }
  }
  [pscustomobject]@{
    Duplicates = $dupes.ToArray(); Contradictions = $contra.ToArray()
    Eligible = $recipeRows.Count; Examined = $examined; WeeklyRows = $weeklyRows.Count
  }
}

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $fail = 0
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("recon-selftest-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $mapF = Join-Path $tmp 'map.json'
    '{"map":{"beef-chuck-roast":"chuck-roast","all-purpose-flour":"flour"}}' | Set-Content $mapF -Encoding UTF8

    # The weekly board, frozen at the 2026-08-08 values that exposed this.
    $weekly = @{ built_at='x'; comparison=@(
      @{ id='chuck-roast'; unit='lb'; stores=@(@{ store='Family Fare'; per_unit=8.49;  unit='lb'; item='Fresh Beef Chuck Roast, Boneless' }) },
      @{ id='flour';       unit='lb'; stores=@(@{ store='Aldi';        per_unit=0.39;  unit='lb'; item='Baker S Corner All Purpose Flour 5 LB' }) }
    )}
    ($weekly | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $tmp 'comparison-2026-08-08.json') -Encoding UTF8

    # MUST FIRE: the recipe board still carries both commodities under their other spelling. chuck-roast
    # is a genuine price contradiction; flour is the SAME price in a different unit and must NOT be one.
    $recipe = @{ built_at='x'; comparison=@(
      @{ id='beef-chuck-roast';  unit='lb'; stores=@(@{ store='Family Fare'; per_unit=10.99;  unit='lb'; item='Fresh Beef Chuck Roast, Boneless' }) },
      @{ id='all-purpose-flour'; unit='oz'; stores=@(@{ store='Aldi';        per_unit=0.0244; unit='oz'; item='Baker S Corner All Purpose Flour 5 LB' }) }
    )}
    ($recipe | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $tmp 'recipe-board.json') -Encoding UTF8

    $r = Get-ReconciliationFindings -Dir $tmp -MapFile $mapF
    if ($r.Duplicates.Count -eq 2) { Write-Output '  ok   must-fire: both renamed commodities are caught as duplicates' }
    else { Write-Output ("  FAIL must-fire: expected 2 duplicates, got " + $r.Duplicates.Count); $fail++ }

    $priceHits = @($r.Contradictions | Where-Object { $_.kind -eq 'price' })
    if ($priceHits.Count -eq 1 -and $priceHits[0].weekly_id -eq 'chuck-roast') {
      Write-Output '  ok   must-fire: the $8.49-vs-$10.99 chuck roast is reported as a price contradiction'
    } else { Write-Output ("  FAIL must-fire: expected exactly the chuck-roast contradiction, got " + $priceHits.Count); $fail++ }

    # THE FALSE POSITIVE THIS AUDIT WAS BORN MAKING. $0.39/lb and $0.0244/oz are the same price. The first
    # measurement counted 6 of these as defects; without this assertion the audit would do it forever.
    if (-not (@($r.Contradictions | Where-Object { $_.weekly_id -eq 'flour' }).Count)) {
      Write-Output '  ok   per-lb against per-oz at the same real price is NOT reported'
    } else { Write-Output '  FAIL a unit rewrite of the same price was reported as a contradiction'; $fail++ }

    # CLEAN TWIN: the de-dup did its job, so the recipe board carries neither commodity.
    $twin = @{ built_at='x'; comparison=@(@{ id='sumac'; unit='oz'; stores=@(@{ store='Aldi'; per_unit=0.5; unit='oz'; item='Sumac' }) }) }
    ($twin | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $tmp 'recipe-board.json') -Encoding UTF8
    $c = Get-ReconciliationFindings -Dir $tmp -MapFile $mapF
    if ($c.Duplicates.Count -eq 0 -and $c.Contradictions.Count -eq 0 -and $c.Examined -eq 1) {
      Write-Output '  ok   clean twin: a de-duplicated pair of boards reports nothing, over 1 examined row'
    } else { Write-Output ("  FAIL clean twin: dupes=" + $c.Duplicates.Count + " contra=" + $c.Contradictions.Count + " examined=" + $c.Examined); $fail++ }

    # WEIGHT IS NOT VOLUME: oz against fl oz on the same product is a basis defect, never silently folded.
    $vol = @{ built_at='x'; comparison=@(@{ id='beef-chuck-roast'; unit='floz'; stores=@(@{ store='Family Fare'; per_unit=8.49; unit='floz'; item='Fresh Beef Chuck Roast, Boneless' }) }) }
    ($vol | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $tmp 'recipe-board.json') -Encoding UTF8
    $v = Get-ReconciliationFindings -Dir $tmp -MapFile $mapF
    if (@($v.Contradictions | Where-Object { $_.kind -eq 'basis' }).Count -eq 1) {
      Write-Output '  ok   oz against fl oz is reported as a BASIS defect, not folded into a price match'
    } else { Write-Output '  FAIL a weight-against-volume pair was not reported as a basis defect'; $fail++ }

    # NO BOARDS AT ALL must be could-not-evaluate, never a clean pass.
    Remove-Item (Join-Path $tmp 'recipe-board.json') -Force
    if ($null -eq (Get-ReconciliationFindings -Dir $tmp -MapFile $mapF)) {
      Write-Output '  ok   a missing board returns could-not-evaluate rather than a clean result'
    } else { Write-Output '  FAIL a missing board did not return could-not-evaluate'; $fail++ }
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue } }

  if ($fail) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $fail); exit 1 }
  Write-Output 'board-reconciliation self-test: 6/6 ok'
  exit 0
}

# ---------------------------------------------------------------------------------------------------
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
# -OutDir wins so a fixture can ship its own map; production falls through to the real file.
$mapFile = Join-Path $OutDir 'recipe-floor-id-map.json'
if (-not (Test-Path $mapFile)) { $mapFile = Join-Path $root 'recipe-floor-id-map.json' }

$res = Get-ReconciliationFindings -Dir $OutDir -MapFile $mapFile
if ($null -eq $res) {
  Write-Output 'board-reconciliation: COULD NOT EVALUATE - need both comparison-*.json and recipe-board.json'
  Write-GuardComplete -Name 'board-reconciliation' -Summary 'blind=no-boards'
  exit 3
}

Write-Output ("weekly rows {0}   recipe rows {1} (examined {2})" -f $res.WeeklyRows, $res.Eligible, $res.Examined)

try {
  $covLib = Join-Path $root 'coverage-lib.ps1'
  if (Test-Path $covLib) {
    . $covLib
    if ($res.Examined -le 0 -and $res.Eligible -gt 0) {
      Write-CoverageRecord -Check 'audit-board-reconciliation' -OutDir $OutDir -Eligible $res.Eligible -Examined $res.Examined -Detail 'recipe rows checked for a duplicate commodity on the weekly board' -Blind
    } else {
      Write-CoverageRecord -Check 'audit-board-reconciliation' -OutDir $OutDir -Eligible $res.Eligible -Examined $res.Examined -Detail 'recipe rows checked for a duplicate commodity on the weekly board'
    }
  }
} catch { }

if ($res.Eligible -gt 0 -and $res.Examined -eq 0) {
  Write-Output 'board-reconciliation: COULD NOT EVALUATE - the recipe board had rows and none were examined'
  Write-GuardComplete -Name 'board-reconciliation' -Summary 'blind=examined-zero'
  exit 3
}

Write-Output ("COMMODITIES PUBLISHED ON BOTH BOARDS: {0}" -f $res.Duplicates.Count)
foreach ($d in $res.Duplicates) { Write-Output ("  {0,-28} = {1,-24} (via {2})" -f $d.recipe_id, $d.weekly_id, $d.via) }
Write-Output ("CONTRADICTIONS ON AN IDENTICAL PRODUCT STRING: {0}" -f $res.Contradictions.Count)
foreach ($x in $res.Contradictions) {
  Write-Output ("  [{0}] {1,-24} {2,-13} weekly={3,-14} recipe={4,-14} {5}" -f $x.kind, $x.weekly_id, $x.store, $x.weekly, $x.recipe, $x.item)
}

$outF = Join-Path $OutDir 'board-reconciliation.json'
([pscustomobject]@{ duplicates = $res.Duplicates; contradictions = $res.Contradictions } | ConvertTo-Json -Depth 6) | Set-Content $outF -Encoding UTF8
Write-Output ('saved -> ' + $outF)

Write-GuardComplete -Name 'board-reconciliation' -Summary ("dupes={0} contra={1}" -f $res.Duplicates.Count, $res.Contradictions.Count)
if ($res.Duplicates.Count -gt 0) { exit 2 }
if ($res.Contradictions.Count -gt 0) { exit 1 }
exit 0
