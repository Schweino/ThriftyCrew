<#
  audit-cost-line-coverage.ps1 - every ingredient the ENGINE priced must be accounted for in the SPEC's
  cost block.

  WHY THIS EXISTS. On 2026-08-16 slow-cooker-boneless-beef-short-ribs was one audit away from publishing
  at $0.30 a serving. Its real cost was $6.30. Seven pounds of short ribs - $83.93, the entire protein -
  were priced correctly by the engine and simply absent from the spec's cost block, because the ingredient
  was wired into the vocabulary AFTER the spec was rendered and nothing re-rendered it.

  Three guards ran on that recipe and all three passed, because each asked a different question:
    audit-unbid-ingredients   does every scaler ingredient carry a bid?        yes - it did
    audit-vocab-integrity     does every canon name resolve to a bid row?      yes - it did
    audit-cost-plausibility   is the ENGINE's costing sane?                    yes - $88.22 was right
  Nobody asked whether the spec's own cost block still agreed with the engine row it was rendered from.
  That is the gap this closes.

  IT DOES NOT COMPARE TOTALS. A spec's cost block is a SNAPSHOT frozen at its last build and costed.json
  is regenerated daily against the live board, so on 2026-08-05 all 513 specs disagreed on cost_batch by
  up to $14.17 - that is what the field means, not a defect. Flagging drift would bury the real signal
  under the whole catalog: a totals sweep today reports 477 of 574 specs, and 472 of those are just the
  board moving.

  The defect has a SHAPE, and the shape is what gets flagged: a materially priced line is missing from
  the block AND its value accounts for the gap in the total. Both halves, or it is not this bug. That
  test finds 5 specs out of 574 - and every one is real.
#>
[CmdletBinding()]
param(
  [string[]]$Slugs,
  [double]$MinLine = 0.20,        # below this a line is rounding, not a missing protein
  [double]$Tolerance = 0.75,      # how closely the omission must explain the gap
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here

# The whole check, over shapes rather than files, so the fixtures can drive it without a repo on disk.
function Test-CostLineCoverage {
  param($EngineRow, [string]$ProseText, [double]$SpecBatch, [double]$MinLine, [double]$Tolerance)
  $gap = [double]$EngineRow.cost_batch - $SpecBatch
  $missing = @()
  foreach ($l in @($EngineRow.lines)) {
    if ([double]$l.util_cost -lt $MinLine) { continue }
    if ($ProseText -notmatch [regex]::Escape([string]$l.item)) { $missing += $l }
  }
  if (-not $missing.Count) { return $null }
  # THE MONEY MUST ACTUALLY BE GONE. A near-zero gap means the total already includes the line and the
  # prose simply names it differently - chicken-shawarma-burrito tripped this on a $0.03 gap against a
  # $0.37 pickle line, which is the total agreeing, not a missing ingredient. Without this the guard
  # cries wolf on naming variants, and a guard that cries wolf gets ignored the day it is right.
  if ($gap -lt $MinLine) { return $null }
  # A line named differently in prose ("Beef Flank/Sirloin Steak" reads as "flank steak") is NOT this bug.
  # It is only this bug if the money is missing from the total too.
  $sum = ($missing | Measure-Object -Property util_cost -Sum).Sum
  if ([math]::Abs($gap - $sum) -gt $Tolerance) { return $null }
  return [pscustomobject]@{
    gap = [math]::Round($gap, 2); omitted = @($missing)
    detail = (@($missing | ForEach-Object { "{0} `${1}" -f $_.item, $_.util_cost }) -join '; ')
  }
}

if ($SelfTest) {
  $fails = 0
  function ok($c, $m, $g) { if ($c) { Write-Host "  ok    $m" } else { $script:fails++; Write-Host "  FAIL  $m   got: $g" } }

  $ribs = [pscustomobject]@{ cost_batch = 88.22; lines = @(
      [pscustomobject]@{ item = 'Boneless Beef Short Ribs'; util_cost = 83.93 }
      [pscustomobject]@{ item = 'Garlic'; util_cost = 0.27 }) }

  # MUST FIRE: the real defect. The protein is absent from the prose and absent from the total.
  $r = Test-CostLineCoverage $ribs 'Garlic, 7 cloves: ~$0.27.' 4.22 0.20 0.75
  ok ($null -ne $r -and $r.omitted.Count -eq 1) 'MUST FIRE  an omitted protein line is caught' $(if ($r) { $r.omitted.Count } else { '<null>' })
  ok ($null -ne $r -and [math]::Abs($r.gap - 84.0) -lt 0.01) 'MUST FIRE  the gap reported is the money actually missing' $(if ($r) { $r.gap } else { '<null>' })

  # CLEAN TWIN: the same recipe once the block is re-rendered. Nothing missing, nothing flagged.
  $r2 = Test-CostLineCoverage $ribs 'Boneless Beef Short Ribs, 7 lb: ~$83.93. Garlic: ~$0.27.' 88.22 0.20 0.75
  ok ($null -eq $r2) 'CLEAN TWIN a correctly rendered block is silent' "$r2"

  # CLEAN TWIN: board drift. Every line IS in the prose; the total differs because the board moved.
  # This is the case that must stay quiet, or the guard reports 477 specs and gets ignored.
  $r3 = Test-CostLineCoverage $ribs 'Boneless Beef Short Ribs, 7 lb: ~$70.00. Garlic: ~$0.20.' 70.20 0.20 0.75
  ok ($null -eq $r3) 'CLEAN TWIN a spec that is merely stale against a moved board is NOT flagged' "$r3"

  # CLEAN TWIN: a naming variant. The prose says "flank steak"; the engine says "Beef Flank/Sirloin Steak".
  # The name does not match, but the money is all present, so it is not this bug.
  $flank = [pscustomobject]@{ cost_batch = 33.0; lines = @(
      [pscustomobject]@{ item = 'Beef Flank/Sirloin Steak'; util_cost = 30.87 }
      [pscustomobject]@{ item = 'Garlic'; util_cost = 2.13 }) }
  $r4 = Test-CostLineCoverage $flank 'Flank steak, 4 lb: ~$30.87. Garlic: ~$2.13.' 33.0 0.20 0.75
  ok ($null -eq $r4) 'CLEAN TWIN a line named differently in prose is not a missing line' "$r4"

  # A sub-threshold line is rounding, not a defect.
  $tiny = [pscustomobject]@{ cost_batch = 10.05; lines = @(
      [pscustomobject]@{ item = 'Salt'; util_cost = 0.05 }
      [pscustomobject]@{ item = 'Beef'; util_cost = 10.0 }) }
  $r5 = Test-CostLineCoverage $tiny 'Beef: ~$10.00.' 10.0 0.20 0.75
  ok ($null -eq $r5) 'CLEAN TWIN a sub-threshold seasoning line is rounding, not an omission' "$r5"

  # CLEAN TWIN, from the field: chicken-shawarma-burrito. The prose does not say "Dill Pickles" but the
  # total is only $0.03 apart, so the money IS in there - the name just differs. An early cut of this
  # guard flagged it, which is the shape of a guard that gets switched off.
  $pickle = [pscustomobject]@{ cost_batch = 20.00; lines = @(
      [pscustomobject]@{ item = 'Dill Pickles'; util_cost = 0.37 }
      [pscustomobject]@{ item = 'Chicken'; util_cost = 19.60 }) }
  $r6 = Test-CostLineCoverage $pickle 'Chicken: ~$19.60. Pickle spears: ~$0.37.' 19.97 0.20 0.75
  ok ($null -eq $r6) 'CLEAN TWIN a near-zero gap means the money is present, whatever the prose calls it' "$r6"

  if ($fails) { Write-Host "SELFTEST: $fails FAILED"; exit 1 }
  Write-Host 'audit-cost-line-coverage SELF-TEST PASS'
  exit 0
}

$costedPath = Join-Path $mp 'db\costed.json'
if (-not (Test-Path $costedPath)) { throw "no costed.json at $costedPath" }
# ASSIGN, THEN WRAP. @(Get-Content ... | ConvertFrom-Json) collapses a 574-row array to Count 1, which
# reads as an empty catalog and passes everything. This estate has been bitten by it repeatedly.
$costedRaw = Get-Content $costedPath -Raw
$costedParsed = ConvertFrom-Json $costedRaw
$engine = @{}
foreach ($r in @($costedParsed)) { $engine[[string]$r.slug] = $r }
if ($engine.Count -lt 50) { throw "costed.json read as only $($engine.Count) row(s) - refusing to certify a catalog that cannot be that small" }

$specDir = Join-Path $mp 'db\recipes'
$targets = if ($Slugs -and @($Slugs).Count) { @($Slugs) } else { @(Get-ChildItem $specDir -Filter *.json | ForEach-Object { $_.BaseName }) }

$hits = @(); $checked = 0
foreach ($s in $targets) {
  $f = Join-Path $specDir "$s.json"
  if (-not (Test-Path $f)) { Write-Host "  ?? no spec for $s"; continue }
  $e = $engine[[string]$s]
  if (-not $e) { continue }
  $specRaw = Get-Content $f -Raw
  $spec = ConvertFrom-Json $specRaw
  $checked++
  $r = Test-CostLineCoverage $e ((@($spec.cost_lines) -join ' ')) ([double]$spec.cost_batch) $MinLine $Tolerance
  if ($r) { $hits += [pscustomobject]@{ slug = $s; gap = $r.gap; detail = $r.detail } }
}

Write-Host "audit-cost-line-coverage: swept $checked spec(s)"
if ($hits.Count) {
  foreach ($h in ($hits | Sort-Object -Property gap -Descending)) {
    Write-Host ("  OMITTED LINE  {0}" -f $h.slug)
    Write-Host ("      the block is short `${0} and does not name: {1}" -f $h.gap, $h.detail)
  }
  Write-Host ("AUDIT-COST-LINE-COVERAGE-COMPLETE omitted={0}" -f $hits.Count)
  exit 1
}
Write-Host '  ok - every materially priced engine line is accounted for in its spec cost block'
Write-Host ("AUDIT-COST-LINE-COVERAGE-COMPLETE clean n={0}" -f $checked)
