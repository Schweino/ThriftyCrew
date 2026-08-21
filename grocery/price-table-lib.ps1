<#
  price-table-lib.ps1 - THE WIDE PRICE TABLE. One row per item; every store's everyday price, ad price
  and ad window as columns on that row.

  BRAD'S MODEL, IN HIS WORDS (2026-08-21):
      "Lets say im a bag of potatoes. I carry an every day price that people can buy at any time...
       That should be stored in db as the every day price. Sometimes, I go on sale for 7 days... That
       price needs to be stored IN THE SAME ROW as a new column for ad price, with a column for ad
       price start and ad price fall off. [Pages] need to fetch the cheaper between ad price and every
       day price. When the sale ends, the ad price needs to null out and... the potatoes go back to
       showing 1.99lb."

  AND THE FOUNDING RULE, which he called non-negotiable:
      "Ad pricing never enters the 'every day' pricing value, and every day pricing value can't
       'replace' ad pricing. Ad pricing must be null if its not on ad."

  Those are three separate promises and each one is a fixture in test-price-table.ps1:
      1. everyday NEVER holds a sale-sourced price          (ad leaking into everyday)
      2. ad NEVER holds an everyday-sourced price           (everyday replacing ad)
      3. ad is NULL the day its window closes               (a sale that will not let go)

  WHY THE THIRD ONE IS THE WHOLE POINT. Once ad_to sits on the row, a sale expires by ARITHMETIC. No
  re-capture is needed to stop publishing it. Under the 90-day carry that is the difference between a
  finished sale falling off by itself and a finished sale publishing for a quarter because the rotation
  has not come back round to it.

  SHAPE: WIDE, ON BRAD'S RULING. I recommended storing long - one row per (commodity, store) - and he
  chose wide: "Wide it is." So the stored row is the ITEM, and stores are columns. The trade is
  recorded honestly rather than re-litigated: wide costs a schema change whenever a store is added or
  dropped, and it makes "every price at Hy-Vee" a column scan instead of a filter. What it buys is that
  a shopper's actual question - "what does this item cost, everywhere, today?" - is ONE row, which is
  also the shape the board, board.json and the recipe pages already render.

  IT DOES NOT RE-DECIDE ANYTHING. Every price here is chosen by the SAME eligibility rule the board
  ranks with (Select-FreshestCaptureRows, from capture-depth-lib) applied to the SAME candidate rows.
  A second implementation of "which row wins" is how a table and the board it describes drift apart
  while both look right - and this estate has paid for that twice this week alone. Test-PriceTableParity
  exists to prove they still agree, per cell, every build.

  A STORE MAY LEGITIMATELY HAVE ONLY ONE HALF. A store that never advertises (Walmart, Sam's - ad_cycle
  'none' in stores.json) has an everyday price and a null ad, permanently and correctly. A store we have
  only ever seen on ad has an ad price and a null everyday. Neither is a defect and neither may be
  papered over by copying one column into the other - that IS the founding rule.
#>

$script:PT_SLUG = @{
  'Hy-Vee' = 'hyvee'; 'Aldi' = 'aldi'; 'Family Fare' = 'familyfare'; 'Fareway' = 'fareway'
  "Baker's" = 'bakers'; "Sam's Club" = 'sams'; 'Walmart' = 'walmart'
}

function Get-PriceTableSlug([string]$Store) {
  if ($script:PT_SLUG.ContainsKey($Store)) { return $script:PT_SLUG[$Store] }
  return (($Store -replace "[^A-Za-z0-9]", '').ToLower())
}

function Test-AdWindowLive {
  <#
    .SYNOPSIS Is this ad window open on the board's date?
    .DESCRIPTION A row with NO ad_to is live (absent evidence is not evidence of expiry - an undated
                 markdown is governed by its TTL elsewhere, not by being silently dropped here).
                 A row whose ad_to is BEFORE today is closed and its ad price must null out.
                 Judged against the BOARD's date, never the wall clock, so a pinned rebuild of an older
                 board reproduces exactly - the same discipline Test-AdWindowClosed follows.
  #>
  param([string]$AdTo, [string]$Today, [string]$AdFrom = '')
  if (-not $Today) { return $true }
  # Not started yet is also not live. A flyer captured early must not price the board before it opens.
  if ($AdFrom -match '^\d{4}-\d{2}-\d{2}$' -and ([string]$AdFrom -gt [string]$Today)) { return $false }
  if (-not ($AdTo -match '^\d{4}-\d{2}-\d{2}$')) { return $true }
  return ([string]$AdTo -ge [string]$Today)
}

function Build-PriceTableRow {
  <#
    .SYNOPSIS One wide row: an item, with every store's everyday and ad halves as columns.
    .DESCRIPTION $Rows is every priced candidate for ONE commodity, across all stores, already carrying
                 price_type ('everyday' | 'sale'). Pure, so the fixtures reach the real decision.
  #>
  param(
    [Parameter(Mandatory)][string]$Id,
    [string]$Commodity = '',
    [string]$Unit = '',
    [object[]]$Rows = @(),
    [string]$Today = ''
  )
  $stores = [ordered]@{}
  foreach ($g in (@($Rows) | Where-Object { $null -ne $_.unit_price } | Group-Object store | Sort-Object Name)) {
    # THE SAME ELIGIBILITY THE BOARD RANKS WITH. Not a copy of it - the function itself.
    $eligible = @(Select-FreshestCaptureRows $g.Group)
    if (-not $eligible.Count) { continue }

    # THE SPLIT IS BY price_type AND NOTHING ELSE. Not by "is it cheaper", not by "does it have a
    # was-price" - by what the capture said the row IS. Deciding it by price would let a deep everyday
    # cut be filed as an ad, which is the founding rule violated in the direction nobody would notice.
    $evRows = @($eligible | Where-Object { [string]$_.price_type -eq 'everyday' })
    $adRows = @($eligible | Where-Object { [string]$_.price_type -eq 'sale' })

    # AN AD WHOSE WINDOW HAS CLOSED IS NOT AN AD. This is Brad's "the ad price needs to null out",
    # implemented as a filter rather than as a later cleanup pass, so there is no window of time in
    # which the closed price exists in the table at all.
    $adLive = @($adRows | Where-Object { Test-AdWindowLive -AdTo ([string]$_.ad_to) -AdFrom ([string]$_.ad_from) -Today $Today })

    $ev = @($evRows | Sort-Object unit_price | Select-Object -First 1)
    $ad = @($adLive | Sort-Object unit_price | Select-Object -First 1)
    if (-not $ev.Count -and -not $ad.Count) { continue }

    $evR = if ($ev.Count) { $ev[0] } else { $null }
    $adR = if ($ad.Count) { $ad[0] } else { $null }

    # WHAT A PAGE SHOWS: the cheaper of the two, exactly as Brad specified. When only one half exists
    # that half is shown; when the ad has nulled out the everyday price is shown again by arithmetic.
    $shown = $null; $shownKind = ''
    if ($null -ne $evR -and $null -ne $adR) {
      if ([double]$adR.unit_price -le [double]$evR.unit_price) { $shown = [double]$adR.unit_price; $shownKind = 'ad' }
      else { $shown = [double]$evR.unit_price; $shownKind = 'everyday' }
    } elseif ($null -ne $adR) { $shown = [double]$adR.unit_price; $shownKind = 'ad' }
    else { $shown = [double]$evR.unit_price; $shownKind = 'everyday' }

    $stores[[string]$g.Name] = [ordered]@{
      everyday          = $(if ($evR) { [double]$evR.unit_price } else { $null })
      everyday_product  = $(if ($evR) { [string]$evR.name } else { '' })
      everyday_size     = $(if ($evR) { [string]$evR.size_text } else { '' })
      everyday_price_text = $(if ($evR) { [string]$evR.price_text } else { '' })
      everyday_asof     = $(if ($evR) { [string]$evR.src_date } else { '' })
      everyday_source   = $(if ($evR) { [string]$evR.source_ad } else { '' })
      # NULL, not 0 and not ''. A missing ad must be indistinguishable from "we checked and there is
      # none", and a zero would silently win every cheaper-of comparison it took part in.
      ad                = $(if ($adR) { [double]$adR.unit_price } else { $null })
      ad_product        = $(if ($adR) { [string]$adR.name } else { '' })
      ad_size           = $(if ($adR) { [string]$adR.size_text } else { '' })
      ad_price_text     = $(if ($adR) { [string]$adR.price_text } else { '' })
      ad_from           = $(if ($adR) { [string]$adR.ad_from } else { '' })
      ad_to             = $(if ($adR) { [string]$adR.ad_to } else { '' })
      ad_basis          = $(if ($adR) { [string]$adR.ad_basis } else { '' })
      ad_source         = $(if ($adR) { [string]$adR.source_ad } else { '' })
      membership        = $(if ($adR) { [bool]$adR.membership } elseif ($evR) { [bool]$evR.membership } else { $false })
      shown             = $shown
      shown_kind        = $shownKind
    }
  }
  return [ordered]@{ id = $Id; commodity = $Commodity; unit = $Unit; stores = $stores }
}

function Test-PriceTableParity {
  <#
    .SYNOPSIS Does the wide table's `shown` price equal the price the board published, per cell?
    .DESCRIPTION Returns an array of disagreements (empty = agree). This is the invariant that keeps
                 the table honest: it is DERIVED from the same rows by the same eligibility rule, so
                 any divergence means one of the two selections has drifted - and a price table that
                 quietly disagrees with the board it describes is worse than no table, because it will
                 be believed. Compared on unit_price to 4dp, the precision the board itself carries.
  #>
  param([object[]]$Table, $Comparison)
  $bad = @()
  $cell = @{}
  foreach ($r in @($Comparison.comparison)) {
    foreach ($s in @($r.stores)) { $cell[([string]$r.id + '|' + [string]$s.store)] = $s }
  }
  $seen = @{}
  foreach ($row in @($Table)) {
    foreach ($st in $row.stores.Keys) {
      $k = [string]$row.id + '|' + $st
      $seen[$k] = $true
      $t = $row.stores[$st]
      if (-not $cell.ContainsKey($k)) {
        $bad += [pscustomobject]@{ id = $row.id; store = $st; kind = 'table-only'; table = $t.shown; board = $null
          why = 'the table prices a cell the board does not publish' }
        continue
      }
      $b = [double]$cell[$k].per_unit
      if ([math]::Abs([double]$t.shown - $b) -gt 0.00005) {
        $bad += [pscustomobject]@{ id = $row.id; store = $st; kind = 'price'; table = $t.shown; board = $b
          why = ("the table shows {0} where the board published {1}" -f $t.shown, $b) }
      }
    }
  }
  foreach ($k in $cell.Keys) {
    if (-not $seen.ContainsKey($k)) {
      $p = $k -split '\|', 2
      $bad += [pscustomobject]@{ id = $p[0]; store = $p[1]; kind = 'board-only'; table = $null; board = [double]$cell[$k].per_unit
        why = 'the board publishes a cell the table has no row for' }
    }
  }
  return $bad
}

function ConvertTo-PriceTableCsv {
  <#
    .SYNOPSIS The wide table flattened to columns, for anything that wants a table rather than a tree.
    .DESCRIPTION DERIVED, never authored. The JSON is the stored fact; this is a rendering of it, and
                 it is regenerated from the JSON every build so the two cannot disagree. Column order
                 follows stores.json order so a diff between two days is readable.
  #>
  param([object[]]$Table, [string[]]$StoreOrder)
  $cols = New-Object System.Collections.Generic.List[string]
  [void]$cols.Add('id'); [void]$cols.Add('commodity'); [void]$cols.Add('unit')
  foreach ($s in $StoreOrder) {
    $g = Get-PriceTableSlug $s
    foreach ($suffix in @('everyday', 'ad', 'ad_from', 'ad_to', 'shown')) { [void]$cols.Add($g + '_' + $suffix) }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add(($cols -join ','))
  foreach ($row in @($Table)) {
    $vals = New-Object System.Collections.Generic.List[string]
    [void]$vals.Add((ConvertTo-PtCsvField ([string]$row.id)))
    [void]$vals.Add((ConvertTo-PtCsvField ([string]$row.commodity)))
    [void]$vals.Add((ConvertTo-PtCsvField ([string]$row.unit)))
    foreach ($s in $StoreOrder) {
      $t = $row.stores[$s]
      if ($null -eq $t) { [void]$vals.Add(''); [void]$vals.Add(''); [void]$vals.Add(''); [void]$vals.Add(''); [void]$vals.Add(''); continue }
      [void]$vals.Add($(if ($null -eq $t.everyday) { '' } else { [string]$t.everyday }))
      [void]$vals.Add($(if ($null -eq $t.ad) { '' } else { [string]$t.ad }))
      [void]$vals.Add([string]$t.ad_from)
      [void]$vals.Add([string]$t.ad_to)
      [void]$vals.Add($(if ($null -eq $t.shown) { '' } else { [string]$t.shown }))
    }
    [void]$lines.Add(($vals -join ','))
  }
  return ($lines -join "`n")
}

function ConvertTo-PtCsvField([string]$s) {
  if ($null -eq $s) { return '' }
  if ($s -match '[",\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
  return $s
}
