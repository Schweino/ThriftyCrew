<#
  apply-category-excludes.ps1 - bake the category-exclude LIBRARY (category-excludes.json) into every
  commodity's own exclude list, by category. This is how NEW commodities are born with the guardrails instead of
  earning them after a wrong match ships (the blueberries-as-Bai-beverage class). Idempotent - safe to re-run
  any time; it only ever ADDS patterns that are missing, never removes or reorders what a commodity already has.

  THE WORKFLOW FOR NEW ITEMS: register the commodity in commodities.json + its category in categories.json,
  then run THIS, then compare-deals. audit-food-category.ps1 (same library) hard-fails the publish if a
  wrong-class product still slips through some other way.

  After running, ALWAYS re-run compare-deals and diff the board (diff-board.ps1 out\vetbase.json <new>) - an
  exclude that drops a store's only match turns a priced cell into "no price", and that must be a reviewed
  correction, not a surprise.
#>
param([switch]$WhatIf, [string]$Root = '')
$ErrorActionPreference = 'Stop'
# -Root exists ONLY so test-auditors can point this script at a frozen fixture tree and prove the drift
# detector still detects drift. Live behaviour is byte-identical: with no -Root it is $PSScriptRoot, as before.
# PowerShell variable names are CASE-INSENSITIVE, so $Root and $root are the SAME variable - this one line
# both honours an explicit -Root and defaults it. Do not "tidy" it into two names; they cannot be two names.
if (-not $root) { $root = $PSScriptRoot }
$lib = Get-Content (Join-Path $root 'category-excludes.json') -Raw | ConvertFrom-Json
$cat = @{}
foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) {
  foreach ($id in @($c.commodities)) { $cat[[string]$id] = [string]$c.label }
}
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$added = 0; $touched = 0
foreach ($cm in $commods) {
  $label = $cat[[string]$cm.id]
  if (-not $label) { continue }
  $classes = $null
  foreach ($a in $lib.apply) { if ($label -match [string]$a.categories) { $classes = @($a.classes); break } }
  if (-not $classes) { continue }
  $have = @($cm.exclude)
  $new = @()
  foreach ($cl in $classes) {
    $ex = [string]$lib.exempt.$cl
    if ($ex -and ([string]$cm.id -match $ex)) { continue }
    foreach ($pat in @($lib.classes.$cl)) { if (($have -notcontains $pat) -and ($new -notcontains $pat)) { $new += $pat } }
  }
  if ($new.Count) { $cm.exclude = @($have + $new); $added += $new.Count; $touched++ }
}
Write-Output ("category-exclude library: +$added patterns across $touched commodities")
if ($WhatIf) { Write-Output 'WhatIf: commodities.json not written'; return }
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
$null = Get-Content (Join-Path $root 'commodities.json') -Raw -Encoding UTF8 | ConvertFrom-Json   # validate round-trip
Write-Output 'commodities.json updated (JSON validated)'
