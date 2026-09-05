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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$slug = @{ "Baker's" = 'bakers'; 'Aldi' = 'aldi'; 'Fareway' = 'fareway'; 'Hy-Vee' = 'hyvee'; 'Walmart' = 'walmart'; "Sam's Club" = 'sams'; 'Family Fare' = 'familyfare' }

$drift = @((Read-JsonFile (Join-Path $root 'out\name-drift.json')).flags)
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$cmp = (Read-JsonFile $cmpF).comparison
$terms = @{}
$tf = Join-Path $root 'commodity-search.json'
# Get-PrimarySearchTerm, not [string]$p.Value: a multi-term commodity would JOIN into one dead string.
if (Test-Path $tf) { . (Join-Path $root 'search-terms-lib.ps1'); $tdoc = (Read-JsonFile $tf).terms; foreach ($p in $tdoc.PSObject.Properties) { $terms[$p.Name] = (Get-PrimarySearchTerm $tdoc $p.Name) } }

$cell = @{}
# BOTH BOARDS, AND THE FLAG'S OWN RECORD IS THE SOURCE OF `match`. This map was built from the STAPLE
# comparison only, so a flag whose id was not on the staple board hit `continue` below and vanished with no
# output of any kind. audit-name-drift started scanning out\recipe-board.json too (2026-07-30, 3d25a939) and
# immediately produced 3 flags on recipe-board-only ids - pineapple-chunks/Hy-Vee, mozzarella-cheese/Family
# Fare, cheddar-cheese/Family Fare - and this script silently dropped all three: 12 flags in, 9 chips out,
# no re-resolve worklist for the wrong links, and nothing printed to say so. MEASURED 2026-07-30 on the live
# board. `match` now comes from the FLAG (board_item) rather than from a re-read of the board: audit-name-drift
# already recorded the exact string it judged the link against, and recipe-overlay.ps1 rewrites
# recipe-board.json every morning, so re-deriving it here is a second, drifting copy of the producer's own
# record - the same lesson guards.ps1 guard 3 learned when it stopped re-deriving name-drift's scope. The board
# map survives only to enrich `size`, and it now reads `size` with a `size_text` fallback because no board cell
# has ever carried a `size_text` property: every chip emitted to date shipped size:"".
foreach ($r in $cmp) { foreach ($s in $r.stores) { $cell[([string]$r.id + '|' + [string]$s.store)] = @{ item = [string]$s.item; size = $(if ([string]$s.size) { [string]$s.size } else { [string]$s.size_text }); unit = [string]$r.unit } } }
$rbF = Join-Path $root 'out\recipe-board.json'
if (Test-Path $rbF) {
  foreach ($rr in @((Read-JsonFile $rbF).comparison)) {
    foreach ($rs in $rr.stores) {
      $rk = [string]$rr.id + '|' + [string]$rs.store
      if ($cell.ContainsKey($rk)) { continue }   # the staple row owns a shared id - the same collision rule audit-name-drift applies
      $cell[$rk] = @{ item = [string]$rs.item; size = [string]$rs.size; unit = [string]$rr.unit }
    }
  }
}

$byStore = @{}; $unmapped = New-Object System.Collections.Generic.List[string]
foreach ($f in $drift) {
  $st = [string]$f.store
  if ($Store -and $st -ne $Store) { continue }
  $k = [string]$f.id + '|' + $st
  # NEVER A SILENT DROP. The flag carries the board product name audit-name-drift compared; use it. Only a
  # flag with NO name at all is unchippable (nothing to re-resolve it BY), and that case is REPORTED below.
  $match = [string]$f.board_item
  if (-not $match -and $cell.ContainsKey($k)) { $match = [string]$cell[$k].item }
  if (-not $match) { [void]$unmapped.Add($k); continue }
  $sz = if ($cell.ContainsKey($k)) { [string]$cell[$k].size } else { '' }
  $q = if ($terms.ContainsKey([string]$f.id)) { $terms[[string]$f.id] } else { ([string]$f.id) -replace '-', ' ' }
  if (-not $byStore.ContainsKey($st)) { $byStore[$st] = New-Object System.Collections.Generic.List[object] }
  $byStore[$st].Add([pscustomobject]@{ id = [string]$f.id; q = $q; match = $match; size = $sz; reason = [string]$f.reason; was = [string]$f.link_name })
}

$dir = Join-Path $root 'out\url-inputs'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$emitted = 0; foreach ($bk in $byStore.Keys) { $emitted += $byStore[$bk].Count }
Write-Output ("build-drift-chips: " + $drift.Count + " drifted link(s) -> " + $emitted + " chip(s) across " + $byStore.Keys.Count + " store(s)")
if ($unmapped.Count -gt 0) { Write-Output ("  UNCHIPPABLE (" + $unmapped.Count + "): name-drift flagged these but recorded no board product name, so there is nothing to re-resolve them BY. They get NO worklist row and need a hand look: " + (($unmapped | Sort-Object) -join ', ')) }
if (-not $Store -and $drift.Count -gt 0 -and $emitted -eq 0) {
  Write-Output '  build-drift-chips: COULD NOT EVALUATE - name-drift reported flags and this produced ZERO chips. That is not "nothing to re-resolve", it is a scope break (check out\name-drift.json flag shape).'
  exit 3
}
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
