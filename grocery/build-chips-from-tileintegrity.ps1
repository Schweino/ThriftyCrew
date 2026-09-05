<#
  build-chips-from-tileintegrity.ps1 - the BLR worklist, built from the authoritative no-link list.

  build-nolink-chips.ps1 reads out\consistency-report.json and only knows Baker's/Aldi/Fareway.
  audit-tile-integrity.ps1 is now the single source of truth for "this priced tile has no See-item link", it
  covers every store, and it is what the guards gate on - so the browser worklist must come from IT, or we
  spend a warm-browser pass on a list that disagrees with the gate we are trying to satisfy.

  Emits out\url-inputs\chips-<slug>.json  = [{id, q, match, size, pu, unit}]
    q      the GENERIC commodity term from commodity-search.json. NOT the board product name: Kroger/Baker's
           mis-ranks a brand-specific query (searching "Filippo Berio Balsamic..." returns Bertolli first and
           can OMIT Filippo Berio entirely), which silently produced wrong-brand matches. The generic term
           returns the full brand set - exactly how the price capture found it - and BLR word-matches `match`.
    match  the BOARD's product name: the thing the link MUST open, because the board's price describes it.
    size   the board's size, so BLR can reject a right-name/wrong-size candidate (the 32oz-vs-4.5oz trap).
    pu     the board's per-unit, so the result can be checked without a second lookup.

  Prints a paste-ready JS array per store: names + sizes only, NO urls - a result string containing URLs trips
  the tool's content filter (see memory grocery-browser-exfil).
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$slug = @{ "Baker's" = 'bakers'; 'Aldi' = 'aldi'; 'Fareway' = 'fareway'; 'Walmart' = 'walmart'; "Sam's Club" = 'sams'; 'Hy-Vee' = 'hyvee'; 'Family Fare' = 'familyfare' }
$terms = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$cmp = (Read-JsonFile $cmpF).comparison
$rows = @((Read-JsonFile (Join-Path $OutDir 'tile-integrity.json')).rows | Where-Object { $_.fault -eq 'NO-LINK' })

$byStore = @{}
foreach ($r in $rows) {
  $st = [string]$r.store
  $row = $cmp | Where-Object { $_.id -eq [string]$r.id } | Select-Object -First 1
  if (-not $row) { continue }
  $cell = $row.stores | Where-Object { $_.store -eq $st } | Select-Object -First 1
  if (-not $cell) { continue }
  $q = [string]$terms.([string]$r.id)
  if (-not $q) { $q = [string]$row.label }           # no registered term: fall back to the commodity label
  if (-not $q) { $q = [string]$r.id }
  if (-not $byStore.ContainsKey($st)) { $byStore[$st] = New-Object System.Collections.Generic.List[object] }
  $byStore[$st].Add([pscustomobject]@{
      id    = [string]$r.id
      q     = $q
      match = [string]$cell.item
      size  = [string]$cell.size
      pu    = [double]$cell.per_unit
      unit  = [string]$row.unit
    })
}

$dir = Join-Path $OutDir 'url-inputs'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
foreach ($st in ($byStore.Keys | Sort-Object)) {
  $sl = if ($slug.ContainsKey($st)) { $slug[$st] } else { ($st.ToLower() -replace '[^a-z0-9]', '') }
  $f = Join-Path $dir ("chips-$sl.json")
  ($byStore[$st] | ConvertTo-Json -Depth 4) | Set-Content $f -Encoding UTF8
  Write-Output ("  {0,-14}{1,3} chip(s) -> url-inputs\chips-{2}.json" -f $st, $byStore[$st].Count, $sl)
}
Write-Output ''
Write-Output ("total no-link chips to resolve: " + $rows.Count)
exit 0
