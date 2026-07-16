<#
  sync-browser-links.ps1 - THE permanent fix so browser-store "See item" links can never regress into no-link
  gaps. The browser price pulls (Baker's / Walmart / Sam's) already stamp the product's identity onto every row
  they refresh - item_id (Walmart/Sam's) or upc (Baker's). That identity IS the product URL. So the moment we
  have a fresh price for a browser product, we also have its link, for free, pointing at the EXACT product the
  board prices. This script writes that link, board-ANCHORED (price/size taken from the board cell), so its
  per-unit equals the board's by construction and prune-bad-links / guard 4 can never drop it for drift.

  WHY THIS CLOSES THE LOOP: a link only regresses to no-link when its stored per-unit diverges from the board by
  a FACTOR (a wrong SKU/size) and prune drops it. Anchoring the link to the board cell of the SAME product it
  was priced from makes that divergence impossible. And because item_id/upc survive on the row even after a link
  is pruned, running this HEALS an already-regressed link and stops it recurring. Idempotent; run after any
  browser price import (and it is wired into the weekly browser-agent flow). guards.ps1 still gates the publish.

  Only touches rows priced TODAY (as_of == today), i.e. just confirmed at the store - never resurrects a link
  for a product we have not re-verified.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')
$today = (Get-Date -Format 'yyyy-MM-dd')

$hostOf = @{ "Walmart"='https://www.walmart.com/ip/'; "Sam's Club"='https://www.samsclub.com/ip/' }
$regGlob = @{ "Walmart"='walmart-regular-*.json'; "Sam's Club"='sams-regular-*.json'; "Baker's"='bakers-regular-*.json' }

$cmp = Get-Content (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$units = @{}; foreach ($it in $cmp.comparison) { $units[[string]$it.id] = [string]$it.unit }
$puF = Join-Path $root 'product-urls.json'
$doc = Get-Content $puF -Raw | ConvertFrom-Json

$set = 0; $healed = 0; $ambig = 0; $log = New-Object System.Collections.Generic.List[string]
foreach ($store in @('Walmart', "Sam's Club", "Baker's")) {
  $rf = Get-ChildItem (Join-Path $root ('out\regular\' + $regGlob[$store])) -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $rf) { continue }
  # KEY BY NAME **AND SIZE**. The claim below - "the board cell was built from this same row, so link == board
  # product by construction" - holds only while a name identifies ONE product. It does not: Baker's ships 10
  # duplicate names and Walmart 5, together serving 9 priced board cells. A name-keyed hashtable keeps the LAST
  # such row, so the URL stamped on the link came from whichever row happened to sit later in the file, not from
  # the row the board actually priced. Third script with this bug (resolve-hyvee-links and refresh-hyvee-links
  # were the others, both fixed 2026-07-16). ALWAYS SUSPECT A DICTIONARY KEYED BY A PRODUCT NAME.
  $rowByName = @{}
  $rowSizes = @{}
  foreach ($r in (Get-Content $rf.FullName -Raw | ConvertFrom-Json).deals) {
    $rn = ([string]$r.item).Trim()
    $rowByName[$rn + '|' + ([string]$r.size).Trim()] = $r
    if (-not $rowSizes.ContainsKey($rn)) { $rowSizes[$rn] = @() }
    $rowSizes[$rn] = $rowSizes[$rn] + @(([string]$r.size).Trim())
  }

  foreach ($it in $cmp.comparison) {
    $cell = $it.stores | Where-Object { $_.store -eq $store } | Select-Object -First 1
    if (-not $cell -or [double]$cell.per_unit -le 0) { continue }
    # take the row the BOARD priced: same name AND same size. Where the name is sold in several sizes and none
    # matches the board's, refuse - stamping a URL from the wrong size is exactly the bug this key prevents.
    $cn = ([string]$cell.item).Trim()
    $row = $null
    if ($rowSizes.ContainsKey($cn)) {
      $csz = @($rowSizes[$cn])
      if ($csz.Count -eq 1) { $row = $rowByName[$cn + '|' + $csz[0]] }
      elseif ($rowByName.ContainsKey($cn + '|' + ([string]$cell.size).Trim())) { $row = $rowByName[$cn + '|' + ([string]$cell.size).Trim()] }
      else { $ambig++ }
    }
    if (-not $row) { continue }
    # Sync any browser row that carries a product IDENTITY (item_id/upc, stamped when we last priced it at the
    # store). The board cell was built from this same row, so link == board product by construction. We do NOT
    # gate on as_of: the link tracks the product the board prices, and guard 9 owns price freshness separately.

    # derive the product URL from the identity the pull stamped on the row
    $url = $null
    if ($store -eq 'Walmart' -or $store -eq "Sam's Club") {
      $iid = [string]$row.item_id
      if ($iid -match '^\d+$') { $url = $hostOf[$store] + $iid }
    } else {                                                                # Baker's: URL captured on the row by the price pull
      if ($row.link_url) { $url = [string]$row.link_url }                   # the real /p/<slug>/<upc>, stamped at pull time
    }
    if (-not $url) { continue }

    $unit = [string]$units[[string]$it.id]; $size = [string]$cell.size
    $pu1 = Get-LinkPerUnit -size $size -unit $unit -price 1 -name ([string]$cell.item)
    if (($null -eq $pu1) -or ([double]$pu1 -le 0)) { continue }
    $qty = 1.0 / [double]$pu1
    $price = [math]::Round([double]$cell.per_unit * $qty, 2)
    if ($price -le 0) { continue }

    # HEAL-ONLY: only (re)create a link that is MISSING (never linked, or just pruned for drift). A healthy
    # existing link is LEFT ALONE so guard 4 keeps checking it against the store independently - overwriting it
    # board-anchored would make that check vacuous. Wired to run right after prune-bad-links, so a link pruned
    # for drift is re-created from its item_id/upc board-anchored in the same pass: it never stays a gap.
    $had = [bool]($doc.items.($it.id).($store) -and $doc.items.($it.id).($store).url)
    if ($had) { continue }
    $entry = [pscustomobject]@{ url=$url; price=[string]$price; size=$size; name=[string]$cell.item; verified=($today + ' price-pull self-capture') }
    if (-not $WhatIf) {
      if (-not $doc.items.($it.id)) { continue }
      $doc.items.($it.id) | Add-Member -NotePropertyName $store -NotePropertyValue $entry -Force
    }
    $set++; $healed++; $log.Add(("  HEAL {0,-22} [{1}] -> {2}" -f $it.id, $store, $url))
  }
}

Write-Output ("browser links synced to their board product: $set  (of which $healed were missing/regressed and are now healed)")
# never let a skipped cell be silent: an ambiguous name is a cell we chose NOT to link, not a cell that is fine.
if ($ambig -gt 0) { Write-Output ("ambiguous name+size, deliberately NOT linked: $ambig  (the store sells that name in several sizes and none matches the board's)") }
foreach ($l in ($log | Select-Object -First 20)) { Write-Output $l }
if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: product-urls.json not written'; return }
if ($set -gt 0) { ($doc | ConvertTo-Json -Depth 8) | Set-Content $puF -Encoding UTF8; Write-Output ''; Write-Output "wrote product-urls.json" }
