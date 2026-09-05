<#
  heal-missing-products.ps1 - restore verified products a store's catalogue pull failed to return.

  A store's regular file is whatever its pull happened to bring back that day. When a pull is partial - or a
  product simply never surfaces for the search terms we use - a product the store really sells goes missing
  from the catalogue. If that product was the CHEAPEST one for its commodity, the engine falls back to a
  pricier one and the board starts OVERSTATING the store. It published Family Fare coffee at $1.04/oz while
  the store sells a 30.5 oz Folgers at $0.59/oz, and Family Fare eggs at $2.16/dozen against a real $1.85.
  Nothing looked broken: the number was self-consistent, and the guard only fires past 1.5x.

  Every row restored here comes from product-urls.json - a product resolved on that store's own site, with a
  live URL, a captured shelf price and a captured size. Nothing is estimated. If the captured size yields no
  per-unit, the row is left out rather than guessed at.

  Only restores where it FIXES something: the store has no cell for the commodity, or the board is dearer
  than what the store actually charges. A product dearer than the engine's current pick changes no published
  number (the engine takes the cheapest), so there is no reason to touch the file for it.

  Re-runnable: a product already in the file is left alone.
#>
param([string]$Store = 'Family Fare', [switch]$WhatIf, [switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')

$PREFIX = @{ 'Family Fare'='family-fare'; "Baker's"='bakers'; 'Hy-Vee'='hyvee'; 'Walmart'='walmart'; 'Aldi'='aldi'; "Sam's Club"='sams'; 'Fareway'='fareway' }
if (-not $PREFIX.ContainsKey($Store)) { throw ("unknown store '$Store' - add it to the PREFIX map") }

$regDir = Join-Path $root 'out\regular'
$curF = (Get-ChildItem (Join-Path $regDir ($PREFIX[$Store] + '-regular-*.json')) |
  Where-Object { $_.BaseName -match '-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1)
if (-not $curF) { throw ("no regular file for $Store") }
$doc = Read-JsonFile $curF.FullName

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Read-JsonFile $cmpF).comparison)
$pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items
$today = (Get-Date -Format 'yyyy-MM-dd')

$have = @{}
foreach ($r in $doc.deals) { $have[([string]$r.item).ToLower().Trim()] = $true }

$rows = New-Object System.Collections.ArrayList
foreach ($d in $doc.deals) {
  $h = [ordered]@{ store=[string]$d.store; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','carried_forward','restored')) { if ($d.$k) { $h[$k] = $d.$k } }
  [void]$rows.Add($h)
}

$added = 0; $skipUnparseable = 0; $skipDearer = 0; $skipOnSale = 0; $skipNoPackSize = 0
$expect = @{}
foreach ($it in $board) {
  $id = [string]$it.id; $unit = [string]$it.unit
  $e = $pd.$id.$Store
  if (-not ($e -and $e.name -and $e.price -and $e.url)) { continue }
  $name = [string]$e.name
  if ($have.ContainsKey($name.ToLower().Trim())) { continue }

  $lp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$lp)
  $linkPu = Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $lp -name $name
  if (($null -eq $linkPu) -or ($lp -le 0)) { $skipUnparseable++; continue }

  # THE SIZE WE WRITE MUST BE A SIZE THE ENGINE CAN READ, not just one pu-lib can.
  # Some links record the store's UNIT PRICE in the size field ("$1.99/lb", "$0.22/oz"). pu-lib understands
  # that, so the row looked fine here - but compare-deals cannot parse it as a quantity, so it dropped both
  # rows on the floor and the board never moved. The restore silently did nothing.
  #   * per-POUND commodity, unit price also per lb: that IS the row. Store it the way every other per-lb row
  #     is stored (ad_price "$1.99", size "lb") and the per-unit comes out exactly right.
  #   * anything else: the unit price does NOT tell us the pack size. $6.99 at "$0.22/oz" implies ~31.8 oz,
  #     which is a GUESS at a 32 oz pack. We do not guess sizes onto a price board. Skip and report it.
  $adPrice = ('$' + $lp)
  $sizeOut = [string]$e.size
  $isUnitPriceSize = ($sizeOut -match '^\s*\$?\s*[0-9.]+\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)\s*$')
  if ($isUnitPriceSize) {
    if ($unit -eq 'lb' -and $sizeOut -match '/\s*lb\s*$') {
      $adPrice = ('$' + [math]::Round([double]$linkPu, 2))
      $sizeOut = 'lb'
    } else {
      $skipNoPackSize++
      Write-Output ('  skip {0,-22} link records only a unit price ("{1}") - the pack size is unknown and will not be guessed' -f $id, ([string]$e.size))
      continue
    }
  }

  $ev  = $it.stores | Where-Object { $_.store -eq $Store -and $_.type -eq 'everyday' } | Select-Object -First 1
  $any = $it.stores | Where-Object { $_.store -eq $Store } | Select-Object -First 1
  $boardPu = if ($ev) { [double]$ev.per_unit } else { 0 }

  # A SALE cell already shows this store at a price BELOW its shelf price - the number a shopper actually
  # pays. Restoring the shelf price there changes nothing this week and is not a repair, so skip it.
  if (($boardPu -le 0) -and $any) { $skipOnSale++; continue }
  if ($boardPu -gt 0 -and ([double]$linkPu) -ge ($boardPu * 0.98)) { $skipDearer++; continue }

  [void]$rows.Add([ordered]@{
    store     = $Store
    item      = $name
    ad_price  = $adPrice
    size      = $sizeOut
    regular   = $lp
    source_ad = 'everyday shelf price'
    as_of     = $today
    restored  = ('verified ' + $Store + ' product (product-urls.json, live URL) that the catalogue pull did not return')
    # The commodity this row exists to fix. verify-heal needs it to tell "outranked by a cheaper product or a
    # sale" (fine) from "matched no commodity at all" (a silent failure - the row sits in the file doing
    # nothing). Without it the verifier can only look for the row's own name among the winning cells, which
    # reports a row that lost to a cheaper sibling as though the restore had failed.
    restored_for = $id
  })
  $have[$name.ToLower().Trim()] = $true
  $expect[$id] = [double]$linkPu
  $added++
  Write-Output ('  + {0,-22} {1,-9} {2,-14} {3}' -f $id, $adPrice, $sizeOut, $name)
}

Write-Output ''
Write-Output ("$Store  restored: $added   skipped: $skipUnparseable no-size, $skipNoPackSize unit-price-only, $skipDearer not-cheaper, $skipOnSale already-on-sale")
# SAFETY RAIL: a heal REPAIRS a catalogue, it does not REBUILD one.
# Run unguarded against Sam's Club this restored 201 rows into a 29-row file - because we hold Sam's product
# URLs for most staple commodities while its catalogue pull only ever covered a handful. That is not a repair:
# it is a 7x coverage expansion of a MEMBERSHIP warehouse whose bulk per-unit prices win most head-to-heads,
# so it would have silently rewritten "cheapest store" verdicts across the board. It also dragged in rows the
# ENGINE misprices (Member's Mark peanut butter, "40 oz., 2 pk" -> priced as 40 oz, exactly 2x).
# Expanding a store's coverage is a real opportunity, but it is a decision, not a side effect of a bug fix.
$cap = [math]::Max(15, [int](@($doc.deals).Count * 0.15))
if (($added -gt $cap) -and (-not $Force)) {
  Write-Output ''
  Write-Output ("REFUSING TO WRITE: $added restores into a " + @($doc.deals).Count + "-row $Store catalogue exceeds the $cap-row cap.")
  Write-Output ("This is a coverage EXPANSION, not a repair - it would change what the board says about $Store across many commodities.")
  Write-Output ("Re-run with -Force if that is genuinely intended, after checking the engine prices these rows correctly.")
  return
}

if ($WhatIf) { Write-Output 'WhatIf: nothing written'; return }

if ($added -gt 0) {
  $doc.deals = $rows.ToArray()
  $doc | Add-Member -NotePropertyName deal_count -NotePropertyValue @($rows).Count -Force
  ($doc | ConvertTo-Json -Depth 6) | Set-Content $curF.FullName -Encoding UTF8
  Write-Output ("$Store file now " + @($rows).Count + " rows -> " + $curF.Name)
}

# The expectation list is what verify-heal.ps1 checks. Entries carry the STORE as well as the commodity - an
# id-keyed map would make the verifier check a Baker's restore against a Family Fare cell the moment a second
# store was healed.
# REPLACE this store's entries wholesale rather than merging into them, and do it even when nothing was
# restored. Merging left a STALE expectation behind: an earlier run restored Baker's shredded-cheese with an
# unreadable size, the fixed run correctly skipped it, and the old entry survived to fail the verifier over a
# cell nobody had touched. The expectation file must say what THIS run did, not what some previous run did.
$expF = Join-Path $root 'out\heal-expected.json'
$all = New-Object System.Collections.ArrayList
if (Test-Path $expF) {
  foreach ($x in @((Read-JsonFile $expF))) {
    if ($x.id -and $x.store -and ([string]$x.store -ne $Store)) { [void]$all.Add($x) }
  }
}
foreach ($k in $expect.Keys) { [void]$all.Add([pscustomobject]@{ id=$k; store=$Store; want=$expect[$k] }) }
($all.ToArray() | ConvertTo-Json -Depth 4) | Set-Content $expF -Encoding UTF8
