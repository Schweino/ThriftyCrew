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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
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
$staple = @((Read-JsonFile $cmpF).comparison)
$recipe = @()
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $recipe = @((Read-JsonFile $riF).comparison) }
$pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items

# ids that appear in BOTH boards = collision (one link can't be right for two per-units) -> skip
$stapleIds = @{}; foreach ($r in $staple) { $stapleIds[[string]$r.id] = $true }
$recipeIds = @{}; foreach ($r in $recipe) { $recipeIds[[string]$r.id] = $true }
$collision = @{}; foreach ($k in $stapleIds.Keys) { if ($recipeIds.ContainsKey($k)) { $collision[$k] = $true } }

# The stores the board actually carries, read off the board rather than kept as a literal list. The
# board-confirmed-fresh gate below reports per-store when it loaded nothing, and a hard-coded roster is how it
# would go on reporting "ok" about a store the board had started or stopped pricing.
$boardStores = @{}
foreach ($bsIt in ($staple + $recipe)) { foreach ($bsS in $bsIt.stores) { if ([string]$bsS.store) { $boardStores[[string]$bsS.store] = $true } } }
$boardStores = @($boardStores.Keys | Sort-Object)

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
foreach ($d in (Read-JsonFile $ndF).flags) { $drift[([string]$d.id + '|' + [string]$d.store)] = $true }
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
      # THE GATE MUST OPEN THE SAME FILES THE ENGINE PRICED FROM (2026-08-30). This block kept a private
      # store -> filename map ("newest out\regular file per store"), a THIRD copy of the rule
      # regular-fileset-lib.ps1 was written to own - and it was wrong in two directions at once:
      #   * WALMART is unioned by the engine across the whole 90-day carry and was read newest-only here, so a
      #     Walmart cell priced from any older capture could not be confirmed and its pin sailed through.
      #   * SAM'S HAS NO out\regular FILE AT ALL. Its everyday club prices come only from
      #     out\sams\sams-deals-*.json (compare-deals.ps1 says so in as many words). The map sent it to
      #     'sams-regular-*.json', where two orphan July/August files still sit, so the gate loaded 60 rows the
      #     board has never priced from, matched nothing, and FAILED OPEN for every Sam's cell - silently,
      #     because the zero-rows warning below was estate-wide and six other stores kept the total non-zero.
      # MEASURED that morning: frozen-fruit / Sam's was pinned to its link's "Member's Mark Triple Berry Blend,
      # Frozen, 64 oz." at 16.34c/oz, over the board's own "Member's Mark Natural Sliced Strawberries, Frozen,
      # 4 lbs." at 12.47c/oz. A DIFFERENT product - and one sitting in the SAME capture as the board's row
      # (sams-deals-2026-08-15), which the board had correctly picked as the cheaper of the two. Pointed at the
      # engine's own fileset, the gate finds the board's exact item at its exact price and refuses the pin.
      # The store name is read off the ROWS, never from a filename map: a filename map is what just drifted.
      . (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')
      $pinFiles = @(Select-EngineRegularFiles $OutDir (Get-Date)) + @(Select-EngineSamsFiles $OutDir (Get-Date))
      foreach ($pf in $pinFiles) {
        try {
          if (-not $pf -or $pf.Length -lt 3) { continue }
          $pdoc = Read-JsonFile $pf.FullName
          # EACH FILE'S OWN DATE AND ITS OWN -2d CARRY CUTOFF, applied here at load. The old code kept one date
          # per store because it only ever held one file per store; under a union the cutoff has to travel with
          # the file, or the oldest member of the union decides the freshness of rows from the newest.
          $pfd = ''
          foreach ($pfp in @('captured','week_of')) { if (($pdoc.PSObject.Properties.Name -contains $pfp) -and $pdoc.$pfp) { $pfd = [string]$pdoc.$pfp; break } }
          if (-not $pfd) { $pfm = [regex]::Match($pf.Name, '(\d{4}-\d{2}-\d{2})'); if ($pfm.Success) { $pfd = $pfm.Groups[1].Value } }
          $pfd = ($pfd -replace 'T.*$','')
          $pfCut = $null
          if ($pfd -match '^\d{4}-\d{2}-\d{2}$') { try { $pfCut = ([datetime]$pfd).AddDays(-2) } catch { $pfCut = $null } }
          $docStore = [string]$pdoc.store
          foreach ($fr in @($pdoc.deals)) {
            $frAo = ''
            if (($fr.PSObject.Properties.Name -contains 'as_of') -and $fr.as_of) { $frAo = ([string]$fr.as_of) -replace 'T.*$','' }
            if (-not $frAo) { $frAo = $pfd }
            if ($pfCut -and ($frAo -match '^\d{4}-\d{2}-\d{2}$')) { try { if (([datetime]$frAo) -lt $pfCut) { continue } } catch { } }
            if (($fr.PSObject.Properties.Name -contains 'not_reverified') -and $fr.not_reverified) { continue }
            $frSt = if (($fr.PSObject.Properties.Name -contains 'store') -and $fr.store) { [string]$fr.store } else { $docStore }
            if (-not $frSt) { continue }
            # ArrayList, NOT List[object]. Windows PowerShell 5.1 throws "Argument types do not match" on the
            # array-subexpression operator applied to a Generic.List[object] - `@($someList)` is an outright
            # ArgumentException, while List[string] and ArrayList are both fine. Every read of these buckets
            # below is written `@(...)` in this file's house style, so a List[object] here would blow up the
            # gate at its first count and leave the pins unwritten.
            if (-not $script:PINFEED.ContainsKey($frSt)) { $script:PINFEED[$frSt] = New-Object System.Collections.ArrayList }
            [void]$script:PINFEED[$frSt].Add($fr)
          }
        } catch { }
      }
      $pinFeedRows = 0
      foreach ($psKey in @($script:PINFEED.Keys)) { $pinFeedRows += @($script:PINFEED[$psKey]).Count }
      # ZERO-ROWS RULE: a gate that loaded nothing has refused nothing, and must say so rather than let every
      # pin below read as "checked against the store".
      if ($pinFeedRows -eq 0) { Write-Warning 'generate-board-overrides: the board-confirmed-fresh gate loaded ZERO first-party rows - it cannot refuse a single pin this run, so every pin written below is UNCHECKED against its own store feed.' }
      # PER STORE, not just estate-wide. Sam's was blind behind a total six other stores kept comfortably
      # non-zero, which is exactly how a dead gate reads as a live one. A gate that is dead for ONE store has
      # to name that store, because every pin it writes there is unchecked.
      foreach ($psKey in @($boardStores)) {
        if (-not $script:PINFEED.ContainsKey($psKey) -or @($script:PINFEED[$psKey]).Count -eq 0) {
          Write-Warning ("generate-board-overrides: the board-confirmed-fresh gate loaded ZERO first-party rows for " + $psKey + " - every pin at that store this run is UNCHECKED against its own store feed.")
        }
      }
      Write-Output ("  board-confirmed-fresh gate: " + $pinFeedRows + " first-party rows from " + @($pinFiles).Count + " engine input file(s)  [" + ((@($script:PINFEED.Keys) | Sort-Object | ForEach-Object { $_ + '=' + @($script:PINFEED[$_]).Count }) -join ' ') + "]")
    }
    $bcfHit = $false
    $bcfItem = [string]$s.item
    $bcfAd = 0.0; [void][double]::TryParse((([string]$s.ad) -replace '[^0-9.]',''), [ref]$bcfAd)
    if ($bcfItem -and $bcfAd -gt 0 -and $script:PINFEED.ContainsKey($st) -and @($script:PINFEED[$st]).Count -gt 0) {
      $bcfNorm = ((($bcfItem.ToLower()) -replace '[^a-z0-9]',' ') -replace '\s+',' ').Trim()
      foreach ($fr in @($script:PINFEED[$st])) {
        if (((([string]$fr.item).ToLower() -replace '[^a-z0-9]',' ') -replace '\s+',' ').Trim() -ne $bcfNorm) { continue }
        $frP = 0.0; [void][double]::TryParse((([string]$fr.ad_price) -replace '[^0-9.]',''), [ref]$frP)
        if ($frP -le 0) { [void][double]::TryParse((([string]$fr.current_price) -replace '[^0-9.]',''), [ref]$frP) }
        if ([math]::Abs($frP - $bcfAd) -gt 0.005) { continue }
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


