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
. (Join-Path $PSScriptRoot 'pu-lib.ps1')
# 2026-07-26 consolidation: LinkPU now DELEGATES to pu-lib's Get-LinkPerUnit (the single per-unit
# implementation; identical params; test-pu-lib.ps1 proves it matches everywhere and resolves more).
# The former local copy - one of three drifting duplicates - is gone. Keep using LinkPU at call sites.
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') { Get-LinkPerUnit -size $size -unit $unit -price $price -name $name }

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
    # ---- BOARD-CONFIRMED-FRESH GATE (2026-07-31) ------------------------------------------------------
    # THE PIN'S FOUNDING PREMISE IS "the board number is the stale/mis-parsed one". Prove it before acting
    # on it. If the store's OWN newest first-party pull still carries this cell's exact item at this cell's
    # exact price, the board is not stale - it is confirmed by the source we trust most - and the
    # disagreement is about the LINK, which is prune-bad-links' and audit-links' problem, never a reason to
    # move a published number.
    # MEASURED 2026-07-31 on the live board: three pins existed whose board item sat in that same morning's
    # own pull at the board price, and all three published a number ~30% too high for the product the card
    # names - rice-vinegar/Walmart (Kikkoman 10 fl oz, $1.87 in walmart-regular-2026-07-30, published as the
    # row's CHEAPEST at 24c/fl oz against a true 18.7c), frozen-lasagna/Walmart (Stouffer's 96 oz, $16.48,
    # published 23c/oz vs 17.2c) and bbq-sauce/Family Fare (Our Family 18 oz, $1.99 in
    # family-fare-regular-2026-07-31, published 14c/oz vs 11.1c). Five more were queued behind them the same
    # morning (baby-wipes, disinfecting-wipes, floor-cleaner, ketchup, canned-black-beans), three of which
    # would have pinned a number LOWER than the truth - the shape that mints a wrong cheapest-store crown.
    # WHY A NAME TEST WAS NOT ENOUGH: the only identity gate this script had is audit-name-drift, and it
    # flagged 3 cells out of 2,723 examined and none of those three. A bidirectional word-overlap test still
    # waved rice-vinegar through (Kikkoman vs Mizkan share "rice" and "vinegar"). This gate asks the STORE,
    # not the resolver, so no name heuristic is involved.
    # It can only ever REFUSE to move a number, never move one, so nothing it does can invent a price.
    if (-not $script:PINFEED) {
      $script:PINFEED = @{}
      $script:PINFEEDDATE = @{}
      $pinFilePat = @{ 'Walmart' = 'walmart-regular-*.json'; 'Family Fare' = 'family-fare-regular-*.json'; 'Hy-Vee' = 'hyvee-regular-*.json'; "Sam's Club" = 'sams-regular-*.json'; 'Aldi' = 'aldi-regular-*.json'; "Baker's" = 'bakers-regular-*.json'; 'Fareway' = 'fareway-regular-*.json' }
      foreach ($psKey in $pinFilePat.Keys) {
        $script:PINFEED[$psKey] = @()
        $script:PINFEEDDATE[$psKey] = ''
        try {
          $pf = Get-ChildItem (Join-Path $OutDir 'regular') -Filter $pinFilePat[$psKey] -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
          if (-not $pf -or $pf.Length -lt 3) { continue }
          $pdoc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
          $script:PINFEED[$psKey] = @($pdoc.deals)
          $pfd = ''
          foreach ($pfp in @('captured','week_of')) { if (($pdoc.PSObject.Properties.Name -contains $pfp) -and $pdoc.$pfp) { $pfd = [string]$pdoc.$pfp; break } }
          if (-not $pfd) { $pfm = [regex]::Match($pf.Name, '(\d{4}-\d{2}-\d{2})'); if ($pfm.Success) { $pfd = $pfm.Groups[1].Value } }
          $script:PINFEEDDATE[$psKey] = ($pfd -replace 'T.*$','')
        } catch { }
      }
      $pinFeedRows = 0
      foreach ($psKey in @($script:PINFEED.Keys)) { $pinFeedRows += @($script:PINFEED[$psKey]).Count }
      # ZERO-ROWS RULE: a gate that loaded nothing has refused nothing, and must say so rather than let every
      # pin below read as "checked against the store".
      if ($pinFeedRows -eq 0) { Write-Warning 'generate-board-overrides: the board-confirmed-fresh gate loaded ZERO first-party rows from out\regular - it cannot refuse a single pin this run, so every pin written below is UNCHECKED against its own store feed.' }
      Write-Output ("  board-confirmed-fresh gate: " + $pinFeedRows + " first-party rows loaded from out\regular")
    }
    $bcfHit = $false
    $bcfItem = [string]$s.item
    $bcfAd = 0.0; [void][double]::TryParse((([string]$s.ad) -replace '[^0-9.]',''), [ref]$bcfAd)
    if ($bcfItem -and $bcfAd -gt 0 -and @($script:PINFEED[$st]).Count -gt 0) {
      $bcfNorm = ((($bcfItem.ToLower()) -replace '[^a-z0-9]',' ') -replace '\s+',' ').Trim()
      $bcfFd = [string]$script:PINFEEDDATE[$st]
      $bcfCut = $null
      if ($bcfFd -match '^\d{4}-\d{2}-\d{2}$') { try { $bcfCut = ([datetime]$bcfFd).AddDays(-2) } catch { $bcfCut = $null } }
      foreach ($fr in @($script:PINFEED[$st])) {
        if (((([string]$fr.item).ToLower() -replace '[^a-z0-9]',' ') -replace '\s+',' ').Trim() -ne $bcfNorm) { continue }
        $frP = 0.0; [void][double]::TryParse((([string]$fr.ad_price) -replace '[^0-9.]',''), [ref]$frP)
        if ($frP -le 0) { [void][double]::TryParse((([string]$fr.current_price) -replace '[^0-9.]',''), [ref]$frP) }
        if ([math]::Abs($frP - $bcfAd) -gt 0.005) { continue }
        $frAo = ''
        if (($fr.PSObject.Properties.Name -contains 'as_of') -and $fr.as_of) { $frAo = [string]$fr.as_of }
        if (-not $frAo) { $frAo = $bcfFd }
        if ($bcfCut -and ($frAo -match '^\d{4}-\d{2}-\d{2}$')) { try { if (([datetime]$frAo) -lt $bcfCut) { continue } } catch { } }
        if (($fr.PSObject.Properties.Name -contains 'not_reverified') -and $fr.not_reverified) { continue }
        $bcfHit = $true
        break
      }
    }
    if ($bcfHit) {
      $skip.boardfresh = 1 + [int]$skip.boardfresh
      Write-Output ("  board-CONFIRMED-FRESH, pin REFUSED: {0} / {1}  board={2} ({3}) is in this store's own current pull - the link '{4}' ({5}) is the side that disagrees" -f $id, $st, $board, ([string]$s.ad), ([string]$e.name), [math]::Round($lpu,4))
      continue
    }
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
Write-Output ("board-overrides: wrote $($cells.Count) corrections  (skipped: sale=$($skip.sale) collision=$($skip.collision) name-drift=$($skip.namedrift) no-link=$($skip.nolink) bad-price=$($skip.badprice) already-agree=$($skip.agree) basis-gap=$($skip.basisgap) board-confirmed-fresh=$([int]$skip.boardfresh))")


