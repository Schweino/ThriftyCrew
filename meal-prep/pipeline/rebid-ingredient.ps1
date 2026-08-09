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

  AFTER RUNNING, the cost basis has moved, so the rest of the chain must follow:
    engine\cost-recipes.ps1 -> pipeline\compute-v2-perserving.ps1 -> pipeline\regenerate-ingredient-map.ps1
    -> pipeline\reanchor-machine-fields.ps1 -Slugs <the touched slugs>   (display numbers)
    -> pipeline\db-build.ps1 + pipeline\audit-schema-constraints.ps1     (the FK that caught this class)
    -> grocery\export-feed.ps1, then republish the touched cards.

  Usage:
    rebid-ingredient.ps1 -Item 'Apple' -ToBid apples -ToUnit lb -ToGpu 453.592 -BuyPkgG 453.592 -BuyPkgLabel lb
    rebid-ingredient.ps1 -Item 'Apple' ... -Apply        (without -Apply it reports and writes nothing)
#>
param(
  [Parameter(Mandatory=$true)][string]$Item,
  [Parameter(Mandatory=$true)][string]$ToBid,
  [Parameter(Mandatory=$true)][string]$ToUnit,
  [Parameter(Mandatory=$true)][double]$ToGpu,
  [double]$BuyPkgG = -1,
  [string]$BuyPkgLabel = '',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp

function Die([string]$s) { Write-Output ('rebid-ingredient: ' + $s); exit 1 }

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
$fromBid = ([regex]::Match($row, '"bid":\s*"([^"]*)"')).Groups[1].Value

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

# ---- the specs that cost this item ----
$specRx = '\{[^{}]*"bid":\s*"' + [regex]::Escape($fromBid) + '"[^{}]*\}'
$touched = New-Object System.Collections.Generic.List[object]
foreach ($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))) {
  $sraw = [IO.File]::ReadAllText($sf.FullName)
  $ms = [regex]::Matches($sraw, $specRx)
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
Write-Output ("  {0} spec(s): {1}" -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ', '))

if (-not $Apply) { Write-Output '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($ingPath, $rawNew, (New-Object Text.UTF8Encoding($false)))
foreach ($t in $touched) { [IO.File]::WriteAllText($t.path, $t.text, (New-Object Text.UTF8Encoding($false))) }
Write-Output ("  APPLIED to db\ingredients.json + {0} spec(s). Now run cost-recipes -> compute-v2-perserving -> regenerate-ingredient-map -> reanchor-machine-fields -Slugs {1} -> db-build." -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ','))
