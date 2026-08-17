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
  param($EngineRow, [string]$ProseText, [double]$SpecBatch, [double]$MinLine, [double]$Tolerance, [hashtable]$DisplayNames)
  $gap = [double]$EngineRow.cost_batch - $SpecBatch
  $missing = @()
  foreach ($l in @($EngineRow.lines)) {
    if ([double]$l.util_cost -lt $MinLine) { continue }
    # THE BLOCK NEVER PRINTS THE CANON NAME when the spec carries a display override - cost-render-lib
    # renders scaler.ing[].item, and the engine keys its line on scaler.ing[].canon. So for the three
    # dangmyeon specs the block truthfully said "Korean glass noodles (dangmyeon), 14 oz dry: ~$4.76"
    # against an engine line named "Rice Noodles", and a name-only search called that money missing.
    #
    # andong-jjimdak-braised-chicken, 2026-08-16: its block summed to its own cost_batch EXACTLY, noodles
    # included, yet this guard reported it short $7.43 - because $9.70 of unrelated chicken-thigh drift
    # cleared the $4.76 lower bound. That is the r8 CLEAN TWIN inverted: the bound only holds a naming
    # variant back while the drift stays SMALLER than the variant's line. Drift has no such ceiling.
    #
    # So resolve canon -> the reader-facing name the block actually prints, and accept either. This is a
    # NAME resolution, not a loosening: MinLine and the one-sided lower bound are untouched, and a line
    # that appears under NEITHER name is still the omission the guard was built to catch.
    $names = @([string]$l.item)
    if ($DisplayNames -and $DisplayNames.ContainsKey([string]$l.item)) { $names += [string]$DisplayNames[[string]$l.item] }
    $seen = $false
    foreach ($n in $names) { if ($n -and $ProseText -match [regex]::Escape($n)) { $seen = $true; break } }
    if (-not $seen) { $missing += $l }
  }
  if (-not $missing.Count) { return $null }
  # THE MONEY MUST ACTUALLY BE GONE. A near-zero gap means the total already includes the line and the
  # prose simply names it differently - chicken-shawarma-burrito tripped this on a $0.03 gap against a
  # $0.37 pickle line, which is the total agreeing, not a missing ingredient. Without this the guard
  # cries wolf on naming variants, and a guard that cries wolf gets ignored the day it is right.
  if ($gap -lt $MinLine) { return $null }
  # A line named differently in prose ("Beef Flank/Sirloin Steak" reads as "flank steak") is NOT this bug.
  # It is only this bug if the money is missing from the total too.
  #
  # THE TEST IS ONE-SIDED, and the first cut got that wrong. It required the gap to MATCH the named-missing
  # sum within tolerance, which silently excused the compound case: hatch-green-chile-chicken-casserole
  # was missing Pepper Jack ($3.73) by name AND had Yellow Bell Pepper ($1.65) present but booked as a
  # $0.04 pantry seasoning, so the gap was $5.46 against $3.73 of named-missing money. |5.46 - 3.73| =
  # $1.73, over tolerance, and the guard returned clean on a spec that would have published $2.20 a
  # serving instead of $2.59. A wave auditor caught it by commit archaeology after my guard said clean.
  #
  # So: the gap must be AT LEAST the money that is missing by name (less tolerance), with no upper bound.
  # A gap larger than the named-missing sum means MORE is wrong, not less. The lower bound is what keeps
  # naming variants out - if prose merely calls a line something else, the money is still in the total and
  # the gap stays near zero, well under the sum.
  $sum = ($missing | Measure-Object -Property util_cost -Sum).Sum
  if ($gap -lt ($sum - $Tolerance)) { return $null }
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

  # MUST FIRE, THE COMPOUND CASE. hatch-green-chile-chicken-casserole, 2026-08-16: Pepper Jack ($3.73)
  # absent from the block by name, AND Yellow Bell Pepper ($1.65) present in the prose but booked as a
  # $0.04 pantry seasoning. Gap $5.46 against $3.73 of named-missing money. The first cut of this guard
  # required those to MATCH within tolerance, so it returned clean and a wave auditor had to find it by
  # commit archaeology. A gap LARGER than the named-missing sum means more is wrong, not less.
  $hatch = [pscustomobject]@{ cost_batch = 36.25; lines = @(
      [pscustomobject]@{ item = 'Pepper Jack Cheese'; util_cost = 3.73 }
      [pscustomobject]@{ item = 'Yellow Bell Pepper'; util_cost = 1.65 }
      [pscustomobject]@{ item = 'Chicken'; util_cost = 30.87 }) }
  $r7 = Test-CostLineCoverage $hatch 'Chicken: ~$30.87. Pantry seasonings (yellow bell pepper): ~$0.04.' 30.79 0.20 0.75
  ok ($null -ne $r7) 'MUST FIRE  a compound gap - one line missing, one misbooked - is caught' "$r7"

  # CLEAN TWIN for the loosened side: a big gap from board drift plus a naming variant must STAY quiet.
  # Here every line is in the prose except the differently-named steak, and the gap is board movement.
  # gap (10) is far below the named-missing sum (30.87), so the lower bound holds it back.
  $drift = [pscustomobject]@{ cost_batch = 43.0; lines = @(
      [pscustomobject]@{ item = 'Beef Flank/Sirloin Steak'; util_cost = 30.87 }
      [pscustomobject]@{ item = 'Garlic'; util_cost = 2.13 }) }
  $r8 = Test-CostLineCoverage $drift 'Flank steak, 4 lb: ~$25.00. Garlic: ~$2.13.' 33.0 0.20 0.75
  ok ($null -eq $r8) 'CLEAN TWIN board drift plus a naming variant is still not an omission' "$r8"

  # CLEAN TWIN, THE DISPLAY OVERRIDE. andong-jjimdak-braised-chicken, 2026-08-16. The engine keys the line
  # "Rice Noodles" (from scaler.canon); the block prints "Korean glass noodles (dangmyeon)" (from
  # scaler.item), which is the whole point of the override - the canonical name is a pricing basis and must
  # never reach a cook. The $4.76 IS in the block and the block sums to its own cost_batch exactly. The gap
  # is $7.43 of chicken-thigh drift, which cleared the $4.76 lower bound and made this report an omission.
  $jjim = [pscustomobject]@{ cost_batch = 34.16; lines = @(
      [pscustomobject]@{ item = 'Rice Noodles'; util_cost = 4.76 }
      [pscustomobject]@{ item = 'Boneless Skinless Chicken Thigh'; util_cost = 21.53 }) }
  $jprose = 'Korean glass noodles (dangmyeon), 14 oz dry: ~$4.76. Boneless Skinless Chicken Thigh, 6.75 lb: ~$11.83.'
  $jdisp  = @{ 'Rice Noodles' = 'Korean glass noodles (dangmyeon)' }
  $r9 = Test-CostLineCoverage $jjim $jprose 26.73 0.20 0.75 $jdisp
  ok ($null -eq $r9) 'CLEAN TWIN a display-override line the block DOES print is not missing, however far the board drifted' "$r9"

  # MUST FIRE: the same override, but the line really is gone - neither the canon nor the reader-facing
  # name appears. Resolving the display name must not become a blanket excuse for the class.
  $r10 = Test-CostLineCoverage $jjim 'Boneless Skinless Chicken Thigh, 6.75 lb: ~$11.83.' 11.83 0.20 0.75 $jdisp
  ok ($null -ne $r10 -and $r10.omitted.Count -eq 1) 'MUST FIRE  an override line absent under BOTH names is still an omission' $(if ($r10) { $r10.omitted.Count } else { '<null>' })

  # MUST FIRE: with no map supplied the guard behaves exactly as before - the parameter is optional and
  # its absence must not silently soften anything.
  $r11 = Test-CostLineCoverage $jjim $jprose 26.73 0.20 0.75 $null
  ok ($null -ne $r11) 'MUST FIRE  with no display map the old name-only behaviour is unchanged' "$r11"

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
  # canon -> the reader-facing name the cost block prints for it. Built from the spec's OWN scaler, so a
  # display override is recognised without any per-recipe list to keep in sync.
  $disp = @{}
  foreach ($se in @($spec.scaler.ing)) {
    $c = if (($se.PSObject.Properties.Name -contains 'canon') -and $se.canon) { [string]$se.canon } else { [string]$se.item }
    if ($c -and [string]$se.item -and $c -ne [string]$se.item -and -not $disp.ContainsKey($c)) { $disp[$c] = [string]$se.item }
  }
  $r = Test-CostLineCoverage $e ((@($spec.cost_lines) -join ' ')) ([double]$spec.cost_batch) $MinLine $Tolerance $disp
  if ($r) { $hits += [pscustomobject]@{ slug = $s; gap = $r.gap; detail = $r.detail } }
}

# A GUARD THAT SWEEPS NOTHING MUST NOT REPORT CLEAN. Passing -Slugs 'a,b' as one comma-joined string (the
# convention some sibling guards accept) matched no spec file, so this printed "clean n=0" and exited 0 -
# a green light over an empty check. Found 2026-08-16 by a wave auditor. Refusing is the only safe answer:
# the caller asked for specific slugs and got none of them.
if($targets.Count -and $checked -eq 0){
  Write-Host ("audit-cost-line-coverage: REFUSING - {0} slug(s) named but NONE matched a spec in db\recipes." -f $targets.Count)
  Write-Host  '  If you passed -Slugs as one comma-joined string, pass an array instead: -Slugs a,b or -Slugs $list.'
  Write-Host  '  A sweep of zero specs is not a clean sweep.'
  exit 1
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
