<#
  build-drift-chips.ps1 - assemble the BLR re-resolve worklist for the WRONG-PRODUCT links name-drift found.

  Sibling of build-nolink-chips.ps1: that one feeds chips that have NO link, this one feeds chips whose link
  points at the WRONG PRODUCT (audit-name-drift.ps1 flags). Same output shape, same consumer:
  hyvee\browser-link-resolve.js  ->  BLR.run('<store>', CHIPS).

  THE SEARCH/MATCH SPLIT MATTERS AND IS NOT OPTIONAL (it is why these links are wrong in the first place):
    q     = the commodity's GENERIC search term (commodity-search.json). Kroger/Baker's search MIS-RANKS a
            brand-specific query - searching "Filippo Berio Balsamic Vinegar Modena" returns Bertolli first and
            can omit Filippo Berio entirely. The generic term returns the full brand set.
    match = the BOARD's own product name. The link must open the product whose price we published; picking the
            cheapest (what resolve-familyfare-urls.ps1 does) is what made price and link disagree by design.

  Emits out\url-inputs\drift-<slug>.json per store + a paste-ready JS literal (names/sizes only - no URLs, so
  the tool output cannot trip the harness's URL block).

  AFTER RUNNING BLR: save rows to out\url-inputs\store-<store>-urls.json, then
    merge-product-urls.ps1 -> stamp-board-pu.ps1 -> prune-bad-links.ps1 -Tol 0.32 -> guards.ps1 -> publish
  and MOVE the store-*-urls.json into out\url-inputs-archive\ (a stale file re-merges old data forever).
#>
param([string]$Store = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$slug = @{ "Baker's" = 'bakers'; 'Aldi' = 'aldi'; 'Fareway' = 'fareway'; 'Hy-Vee' = 'hyvee'; 'Walmart' = 'walmart'; "Sam's Club" = 'sams'; 'Family Fare' = 'familyfare' }

$drift = @((Get-Content (Join-Path $root 'out\name-drift.json') -Raw | ConvertFrom-Json).flags)
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = (Get-Content $cmpF -Raw | ConvertFrom-Json).comparison
$terms = @{}
$tf = Join-Path $root 'commodity-search.json'
if (Test-Path $tf) { foreach ($p in (Get-Content $tf -Raw | ConvertFrom-Json).terms.PSObject.Properties) { $terms[$p.Name] = [string]$p.Value } }

$cell = @{}
foreach ($r in $cmp) { foreach ($s in $r.stores) { $cell[([string]$r.id + '|' + [string]$s.store)] = @{ item = [string]$s.item; size = [string]$s.size_text; unit = [string]$r.unit } } }

$byStore = @{}
foreach ($f in $drift) {
  $st = [string]$f.store
  if ($Store -and $st -ne $Store) { continue }
  $k = [string]$f.id + '|' + $st
  if (-not $cell.ContainsKey($k)) { continue }
  $q = if ($terms.ContainsKey([string]$f.id)) { $terms[[string]$f.id] } else { ([string]$f.id) -replace '-', ' ' }
  if (-not $byStore.ContainsKey($st)) { $byStore[$st] = New-Object System.Collections.Generic.List[object] }
  $byStore[$st].Add([pscustomobject]@{ id = [string]$f.id; q = $q; match = $cell[$k].item; size = $cell[$k].size; reason = [string]$f.reason; was = [string]$f.link_name })
}

$dir = Join-Path $root 'out\url-inputs'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Write-Output ("build-drift-chips: " + $drift.Count + " drifted link(s) across " + $byStore.Keys.Count + " store(s)")
Write-Output ''
foreach ($st in ($byStore.Keys | Sort-Object)) {
  $rows = $byStore[$st]
  $sl = if ($slug.ContainsKey($st)) { $slug[$st] } else { ($st -replace '[^a-z]', '').ToLower() }
  $out = Join-Path $dir ('drift-' + $sl + '.json')
  ($rows | ConvertTo-Json -Depth 4) | Set-Content $out -Encoding UTF8
  Write-Output ("=== " + $st + "  (" + $rows.Count + ")  ->  out\url-inputs\drift-" + $sl + ".json")
  $lit = ($rows | ForEach-Object { "{i:'" + $_.id + "',q:'" + ($_.q -replace "'", "\'") + "',m:'" + ($_.match -replace "'", "\'") + "'}" }) -join ','
  Write-Output ('  BLR.run(''' + $st + ''', [' + $lit + '])')
  Write-Output ''
}
