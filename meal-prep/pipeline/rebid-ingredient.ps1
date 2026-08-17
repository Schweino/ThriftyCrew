<#
  rebid-ingredient.ps1 - re-point ONE db\ingredients.json item at a different board commodity, and carry the
  same change into every db\recipes spec that costs it.

  WHY THIS EXISTS (2026-08-09): the recipe and weekly boards spell 33 shared commodities differently, and
  recipe-floor-id-map.json settles which pairs are the same thing. When the 08-08 cross-board de-dup dropped
  the recipe row, export-feed could alias the 30 pairs that share a unit - but a pair whose unit genuinely
  differs (apple priced 'each' against apples priced 'lb') cannot be aliased, because grams_per_unit is
  expressed in the served row's unit and aliasing across units serves a WRONG price instead of no price.
  Those have to move basis for real, in the db AND in the specs, which is what this does.

  A BID IS THREE FIELDS, NOT ONE. bid, unit and gpu only mean anything together: gpu is "grams in one unit
  of the priced basis", so moving 'each' (175 g per apple) to 'lb' without moving gpu to 453.592 leaves the
  item quoting a price 2.6x wrong while every guard reads green. This script refuses to move one without the
  others. See the estate memo on re-anchoring a pair.

  PROSE-SAFE. Targeted, object-scoped regex edits only - it NEVER re-serializes a spec, because the prose
  carries \uXXXX escapes that a ConvertTo-Json round trip would rewrite. Every file is parse-verified before
  it is written, and written BOM-less.

  A BID DOES NOT IDENTIFY AN ITEM (2026-08-16). Until this date the spec sweep selected blocks by matching
  "bid": "<the old bid>", on the assumption that one bid means one item. It does not: 14 bids in
  db\ingredients.json are shared by 2 or more rows (pasta by five; frozen-chopped-spinach by BOTH 'Spinach'
  and 'Frozen Chopped Spinach'; eggs by 'Eggs' and 'Egg Yolk'). Rebidding 'Spinach' from frozen to fresh
  would therefore have moved all 27 spinach recipes - including the 22 that say "thaw it and squeeze it
  dry" - onto a fresh-leaf price. The blast radius exceeded the item by 4.4x and every guard would have
  read green, because each rewritten block was individually well-formed.

  Blocks are now selected by IDENTITY: a block is rewritten only when its 'canon' (or, on the older specs
  that carry no canon, its 'item') is the row's name or one of the row's aliases. A block carrying the old
  bid whose identity is some OTHER row is listed as skipped, never touched; a block that carries neither
  canon nor item cannot be identified and REFUSES the whole run. Positive identification or nothing - the
  same rule the vocabulary plan applies to names.

  -FromBid overrides which bid to sweep for, for the case where the row has already been pointed at its new
  commodity (a fresh row added beside the frozen one) and the SPECS are what still carry the old basis.

  AFTER RUNNING, the cost basis has moved, so the rest of the chain must follow:
    engine\cost-recipes.ps1 -> pipeline\compute-v2-perserving.ps1 -> pipeline\regenerate-ingredient-map.ps1
    -> pipeline\reanchor-machine-fields.ps1 -Slugs <the touched slugs>   (display numbers)
    -> pipeline\db-build.ps1 + pipeline\audit-schema-constraints.ps1     (the FK that caught this class)
    -> grocery\export-feed.ps1, then republish the touched cards.

  Usage:
    rebid-ingredient.ps1 -Item 'Apple' -ToBid apples -ToUnit lb -ToGpu 453.592 -BuyPkgG 453.592 -BuyPkgLabel lb
    rebid-ingredient.ps1 -Item 'Apple' ... -Apply        (without -Apply it reports and writes nothing)
    rebid-ingredient.ps1 -SelfTest
#>
param(
  [string]$Item = '',
  [string]$ToBid = '',
  [string]$ToUnit = '',
  [double]$ToGpu = 0,
  [string]$FromBid = '',
  [double]$BuyPkgG = -1,
  [string]$BuyPkgLabel = '',
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp

function Die([string]$s) { Write-Output ('rebid-ingredient: ' + $s); exit 1 }

# Which ingredient row does one scaler.ing block belong to? 'canon' is the resolved row name and is
# authoritative when present; ~36% of blocks (the pre-canon r300 era) carry only 'item', which on those
# specs IS the row name. Returns '' when the block declares neither, which is a refusal, not a default.
function Get-BlockIdentity([string]$block) {
  $c = ([regex]::Match($block, '"canon":\s*"([^"]*)"')).Groups[1].Value
  if ($c) { return $c }
  return ([regex]::Match($block, '"item":\s*"([^"]*)"')).Groups[1].Value
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $withCanon = '{"item":"Baby Spinach","canon":"Spinach","grams":397,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $noCanon   = '{"item":"Spinach","grams":200,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $frozen    = '{"item":"Frozen Chopped Spinach","grams":595,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $blankBoth = '{"grams":100,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  T 'canon wins over item when both are present'   ((Get-BlockIdentity $withCanon) -eq 'Spinach')            (Get-BlockIdentity $withCanon)
  T 'item stands in when canon is absent'          ((Get-BlockIdentity $noCanon)   -eq 'Spinach')            (Get-BlockIdentity $noCanon)
  T 'a sibling row on the same bid reads as itself' ((Get-BlockIdentity $frozen)   -eq 'Frozen Chopped Spinach') (Get-BlockIdentity $frozen)
  # MUST FIRE: the whole point. Same bid, different item - selecting on bid alone would sweep this one in.
  T 'MUST FIRE  sibling identity is NOT the target' ((Get-BlockIdentity $frozen)   -ne 'Spinach')            (Get-BlockIdentity $frozen)
  T 'MUST FIRE  an unidentifiable block returns empty' ((Get-BlockIdentity $blankBoth) -eq '')               '(empty)'
  if ($bad) { Write-Output ("rebid-ingredient SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'rebid-ingredient SELF-TEST PASS'; exit 0
}

if (-not $Item)   { Die 'pass -Item <name> (or -SelfTest)' }
if (-not $ToBid)  { Die 'pass -ToBid <commodity id>' }
if (-not $ToUnit) { Die 'pass -ToUnit <unit>' }
if ($ToGpu -le 0) { Die 'pass -ToGpu <grams per one unit of the priced basis>' }

# THE TARGET MUST BE PRICEABLE BEFORE WE POINT AT IT. The whole failure class this script answers is a bid
# that names nothing, so refusing to create a NEW dangling bid is the one check that must never be optional.
$feedPath = Join-Path $repo 'grocery\out\smp-feed.json'
if (-not (Test-Path $feedPath)) { Die "no grocery\out\smp-feed.json - cannot verify that '$ToBid' is priceable" }
$feed = (Get-Content $feedPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
$fr = $feed.PSObject.Properties[$ToBid]
if (-not $fr) { Die "'$ToBid' is not in the feed - it would be a dangling bid, which is the bug this script fixes" }
if ([string]$fr.Value.unit -ne $ToUnit) { Die "unit mismatch: feed serves '$ToBid' per '$($fr.Value.unit)', you asked for '$ToUnit'. gpu is expressed in the SERVED unit, so this would price the item wrong." }

$ingPath = Join-Path $mp 'db\ingredients.json'
$raw = [IO.File]::ReadAllText($ingPath)
$rowRx = '\{[^{}]*"item":\s*"' + [regex]::Escape($Item) + '",[^{}]*\}'
$m = [regex]::Match($raw, $rowRx)
if (-not $m.Success) { Die "no db\ingredients.json row for item '$Item' (or the row holds a nested object, which this editor will not touch)" }
$row = $m.Value
$rowBid  = ([regex]::Match($row, '"bid":\s*"([^"]*)"')).Groups[1].Value
$fromBid = if ($FromBid) { $FromBid } else { $rowBid }

# The names this row answers to. A spec's canon may be an adjudicated alias rather than the row's own name
# ('Andouille Smoked Sausage' -> row 'Pork Smoked Sausage'), so aliases are identity too.
$identity = @{}
$identity[$Item] = $true
foreach ($a in [regex]::Matches($row, '"aliases":\s*\[(?<b>[^\]]*)\]') | ForEach-Object { $_.Groups['b'].Value }) {
  foreach ($q in [regex]::Matches($a, '"([^"]*)"')) { $identity[$q.Groups[1].Value] = $true }
}

$new = $row
$new = [regex]::Replace($new, '("bid":\s*")[^"]*(")',  ('${1}' + $ToBid + '${2}'))
$new = [regex]::Replace($new, '("unit":\s*")[^"]*(")', ('${1}' + $ToUnit + '${2}'))
$new = [regex]::Replace($new, '("gpu":\s*)[0-9.]+',    ('${1}' + $ToGpu))
# board is 'recipe' only while the id lives on the recipe board; a moved bid is on the weekly one by definition
$new = [regex]::Replace($new, '("board":\s*")[^"]*(")', '${1}weekly${2}')
if ($BuyPkgG -ge 0)   { $new = [regex]::Replace($new, '("buy_pkg_g":\s*)[0-9.]+', ('${1}' + $BuyPkgG)) }
if ($BuyPkgLabel)     { $new = [regex]::Replace($new, '("buy_pkg_label":\s*")[^"]*(")', ('${1}' + $BuyPkgLabel + '${2}')) }
$rawNew = $raw.Substring(0, $m.Index) + $new + $raw.Substring($m.Index + $m.Length)
$null = $rawNew | ConvertFrom-Json

Write-Output ("rebid-ingredient: '{0}'  bid {1} -> {2}, unit -> {3}, gpu -> {4}" -f $Item, $fromBid, $ToBid, $ToUnit, $ToGpu)
if ($rowBid -eq $ToBid) { Write-Output "  (the row already bids '$ToBid' - this run moves the SPECS only)" }
Write-Output ('  identity: ' + (($identity.Keys | Sort-Object) -join ' | '))

# ---- the specs that cost this item ----
# Candidates carry the old bid; only those whose IDENTITY is this row are rewritten. See the header note.
$specRx = '\{[^{}]*"bid":\s*"' + [regex]::Escape($fromBid) + '"[^{}]*\}'
$touched = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$blind   = New-Object System.Collections.Generic.List[object]
foreach ($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))) {
  $sraw = [IO.File]::ReadAllText($sf.FullName)
  $ms = @([regex]::Matches($sraw, $specRx) | Where-Object {
    $who = Get-BlockIdentity $_.Value
    if (-not $who) { $blind.Add(($sf.BaseName + ' (a block on bid ' + $fromBid + ' declares neither canon nor item)')); return $false }
    if (-not $identity.ContainsKey($who)) { $skipped.Add(($sf.BaseName + ' :: ' + $who)); return $false }
    return $true
  })
  if ($ms.Count -eq 0) { continue }
  $out = $sraw; $off = 0
  foreach ($sm in $ms) {
    $blk = $sm.Value
    $nb = [regex]::Replace($blk, '("bid":\s*")[^"]*(")', ('${1}' + $ToBid + '${2}'))
    $nb = [regex]::Replace($nb,  '("gpu":\s*")[^"]*(")', ('${1}' + ('{0:0.000}' -f $ToGpu) + '${2}'))
    $out = $out.Substring(0, $sm.Index + $off) + $nb + $out.Substring($sm.Index + $off + $blk.Length)
    $off += ($nb.Length - $blk.Length)
  }
  $null = $out | ConvertFrom-Json
  $touched.Add([pscustomobject]@{ slug = $sf.BaseName; path = $sf.FullName; text = $out; n = $ms.Count })
}
# An unidentifiable block is the one case with no safe default: leaving it behind splits one item across two
# bases, and sweeping it in is the very over-reach this scoping exists to stop. Refuse and let a human name it.
if ($blind.Count -gt 0) {
  Die ('CANNOT IDENTIFY ' + $blind.Count + ' block(s) carrying bid ' + $fromBid + ' - no canon, no item: ' +
       ((@($blind) | Select-Object -First 5) -join '; ') + '. Nothing written.')
}
Write-Output ("  {0} spec(s) rewritten: {1}" -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ', '))
if ($skipped.Count -gt 0) {
  Write-Output ("  {0} block(s) left on '{1}' - they belong to a DIFFERENT row sharing that bid:" -f $skipped.Count, $fromBid)
  foreach ($g in ($skipped | Group-Object { ($_ -split ' :: ')[1] })) {
    Write-Output ('      ' + $g.Name + '  x' + $g.Count)
  }
}

if (-not $Apply) { Write-Output '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($ingPath, $rawNew, (New-Object Text.UTF8Encoding($false)))
foreach ($t in $touched) { [IO.File]::WriteAllText($t.path, $t.text, (New-Object Text.UTF8Encoding($false))) }
Write-Output ("  APPLIED to db\ingredients.json + {0} spec(s). Now run cost-recipes -> compute-v2-perserving -> regenerate-ingredient-map -> reanchor-machine-fields -Slugs {1} -> db-build." -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ','))
