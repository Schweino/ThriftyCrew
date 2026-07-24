<#
  generate-board-overrides.ps1 - DERIVES board-price-overrides.json instead of hand-maintaining it.

  The bug Brad caught: a board price and its "See item" link can describe different products/prices. The strict
  build guard already HIDES a link whose per-unit is >30% off the board - but that leaves the chip with no link
  and, worse, still showing a stale board number. This script closes the loop for the safe, common case:

    For every EVERYDAY board cell that has a durable product-urls link, if the link's per-unit disagrees with the
    board by >Tol, the board number is the stale/mis-parsed one (the link is a verified product page we resolved).
    We pin the board to the link's correctly-computed per-unit so price == link == the real shelf product.

  Safety gates so this can never re-introduce a wrong price the way blindly trusting a link would:
    - EVERYDAY only            : a live weekly-ad SALE is never overridden (its low price must stand).
    - name-drift NOT flagged   : if audit-name-drift says the link is the wrong product (fresh->frozen, form-flip),
                                 we do NOT trust its price - the cell stays hidden, exactly as Brad wants.
    - single-board only        : ids that live in BOTH the staple and recipe board (different representative
                                 sizes) are skipped - one link can't be correct for two different per-units.
    - valid pack price + size  : price>0 and the size parses to a real qty+unit, so LinkPU is meaningful.

  Output: board-price-overrides.json { readme, updated, cells:[{id,store,per_unit,source,board_was,link_name,set}] }
  Re-runnable and idempotent: run it before every publish so the corrections always reflect current data.
#>
param([double]$Tol = 0.30, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# EXACT LinkPU from build-deals-page.ps1 / audit-board-consistency.ps1 - keep these three in lockstep.
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') {
  $s = ([string]$size).ToLower().Trim()
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) { $v=[double]$up.Groups[1].Value; $un=($up.Groups[2].Value -replace '\s','') -replace 'fl',''; switch ($unit) { 'lb'{if($un -eq 'lb'){return $v}; if($un -eq 'oz'){return $v*16}} 'oz'{if($un -eq 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'floz'{if($un -match 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'each'{if($un -match '^(ea|each|ct|count)$'){return $v}; return $price} 'dozen'{if($un -match '^(ea|each|ct|count)$'){return $v*12}; return $price} } }
  if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') -replace 'fl','' } else { '' }
  if (-not $q.Success) { $bu=[regex]::Match($s,'\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n=1; $un=$bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b'); if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  # MULTIPACK IN THE NAME: a link whose size is just "each" but whose NAME says "24 Pack" is 24 items,
  # not 1. Without this the whole pack price is published as the per-item price (Fareway bottled water
  # went out at $3.87 EACH). Only for 'each' commodities, and only when the size carries no count.
  if ($unit -eq 'each' -and $name -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) {
      $cnt = [double]$pn.Groups[1].Value
      if ($cnt -gt 1) { return $price / $cnt }
    }
  }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$' -and $n) { return $price/$n }; if ($un -eq 'oz' -and $n) { return $price/($n/16) }; return $null }
    'oz'    { if ($un -eq 'oz' -and $n) { return $price/$n }; if ($un -match '^lbs?$' -and $n) { return $price/(16*$n) }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'floz'  { if ($un -match 'oz' -and $n) { return $price/$n }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price/$n }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($n -eq 1) { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$' -and $n) { return $price/($n/12) }; if ($n -eq 1) { return $price }; return $null }
    'gallon'{ if ($un -eq 'gal' -and $n) { return $price/$n }; if ($n -eq 1) { return $price }; return $null }
    default { return $null }
  }
  return $null
}

# boards
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$staple = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)
$recipe = @()
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $recipe = @((Get-Content $riF -Raw | ConvertFrom-Json).comparison) }
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# ids that appear in BOTH boards = collision (one link can't be right for two per-units) -> skip
$stapleIds = @{}; foreach ($r in $staple) { $stapleIds[[string]$r.id] = $true }
$recipeIds = @{}; foreach ($r in $recipe) { $recipeIds[[string]$r.id] = $true }
$collision = @{}; foreach ($k in $stapleIds.Keys) { if ($recipeIds.ContainsKey($k)) { $collision[$k] = $true } }

# name-drift: links flagged as the WRONG product must NOT have their price trusted.
#
# THIS CHECK WAS DEAD FOR ITS ENTIRE LIFE, AND IT FAILED OPEN (2026-07-16). It looked for name-drift.json in
# $root; audit-name-drift.ps1 writes it to $root\out. Test-Path simply returned false, there was no else, and an
# ABSENT FILE READ AS "NOTHING IS FLAGGED" - so the only defence this generator has against a wrong-product link
# never ran once, while the readme (and the report line "name-drift=N") stated it did.
#
# What it cost: Aldi's FRESH blueberries were linked to "Season's Choice FROZEN Blueberries", so this generator
# "corrected" the board to the frozen price and the page published Aldi fresh blueberries at 16c/oz WITH A
# CHEAPEST FLAG - a wrong number that a pin makes authoritative, because a pin beats the engine by design.
#
# So it now resolves the real path AND REFUSES TO RUN without it. A safety check that cannot find its input must
# stop, never shrug: writing pins with no drift data is precisely the failure this file was built to prevent.
$drift = @{}
$ndF = Join-Path $root 'out\name-drift.json'
if (-not (Test-Path $ndF)) {
  Write-Error ("generate-board-overrides: REFUSING to run - name-drift data not found at $ndF. Pins beat the engine, so writing them without the wrong-product check is how a frozen-blueberry price gets published as fresh. Run audit-name-drift.ps1 first.")
  exit 2
}
foreach ($d in (Get-Content $ndF -Raw | ConvertFrom-Json).flags) { $drift[([string]$d.id + '|' + [string]$d.store)] = $true }
if ($drift.Count -eq 0) { Write-Warning 'generate-board-overrides: name-drift flagged NOTHING - verify that is real before trusting these pins.' }

$cells = New-Object System.Collections.Generic.List[object]
$skip  = [ordered]@{ collision=0; sale=0; namedrift=0; nolink=0; badprice=0; agree=0; basisgap=0 }
$now = (Get-Date -Format 'yyyy-MM-dd')

foreach ($it in ($staple + $recipe)) {
  $id=[string]$it.id; $unit=[string]$it.unit
  if ($collision.ContainsKey($id)) { $skip.collision += @($it.stores).Count; continue }
  foreach ($s in $it.stores) {
    $st=[string]$s.store; $board=[double]$s.per_unit; if ($board -le 0) { continue }
    if (([string]$s.type) -ne 'everyday') { $skip.sale++; continue }
    $e = $pd.$id.$st; if (-not ($e -and $e.url)) { $skip.nolink++; continue }
    if ($drift.ContainsKey($id + '|' + $st)) { $skip.namedrift++; continue }
    $price=0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$price)
    if ($price -le 0) { $skip.badprice++; continue }
    $lpu = LinkPU ([string]$e.size) $unit $price ([string]$e.name)
    if ($null -eq $lpu -or $lpu -le 0) { $skip.badprice++; continue }
    $off = [math]::Abs($lpu - $board) / $board
    if ($off -le $Tol) { $skip.agree++; continue }
    # RATIO CAP (2026-07-23): a genuinely stale board price drifts by percents; a 2x+ gap means the LINK
    # side is the broken one (pack price parsed as per-item: bottled water 24x, dryer sheets 120x, facial
    # tissues 107x all minted as "corrections" tonight). Never pin across a basis-sized gap - leave the
    # disagreement for prune-bad-links to drop, which is honest (search link) instead of wrong (bad price).
    $ratio = $lpu / $board
    if ($ratio -gt 2.0 -or $ratio -lt 0.5) { $skip.basisgap++; Write-Output ("  basis-gap SKIPPED (not pinned): {0} / {1}  board={2} link={3}  ({4:0.0}x)" -f $id, $st, $board, [math]::Round($lpu,4), $ratio); continue }
    $cells.Add([ordered]@{ id=$id; store=$st; per_unit=[math]::Round($lpu,4); source='derived: verified product-urls link (board was stale)'; board_was=[math]::Round($board,4); link_name=[string]$e.name; set=$now })
  }
}

$obj = [ordered]@{
  readme = 'DERIVED by generate-board-overrides.ps1 - do not hand-edit. Per-cell EVERYDAY per-unit corrections: when a board price disagrees >30% with the verified product its See-item link opens (and name-drift confirms the link is the right product), the board number is stale and is pinned here to the link''s per-unit so price==link==shelf. build-deals-page applies these to EVERYDAY cells only (a live sale always wins) and survives daily regeneration. Sales, wrong-product links (name-drift), and ids present in both the staple+recipe board are intentionally excluded.'
  updated = $now
  tol = $Tol
  count = $cells.Count
  cells = $cells
}
$obj | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'board-price-overrides.json') -Encoding UTF8
Write-Output ("board-overrides: wrote $($cells.Count) corrections  (skipped: sale=$($skip.sale) collision=$($skip.collision) name-drift=$($skip.namedrift) no-link=$($skip.nolink) bad-price=$($skip.badprice) already-agree=$($skip.agree) basis-gap=$($skip.basisgap))")


