<#
  import-walmart-batch.ps1 - turn the Walmart __NEXT_DATA__ capture (name~~linePrice~~unitPrice~~usItemId per
  product, tab-keyed by commodity) into walmart-regular rows. Walmart gives the UNIT price ("17.9 ¢/oz",
  "$5.31/lb"), not a size, so we back the size out: size = linePrice / per-unit. compare-deals then matches by
  the same rules and recomputes per-unit (which equals Walmart's, by construction). Also stashes name->usItemId
  so the winning product's /ip/<id> link can be resolved after compare-deals picks the cell.
  NOTE: store is Bellevue 68123 (Omaha metro, Brad OK'd 2026-07-15 - Walmart zone-prices are uniform across the
  metro). Usage: .\import-walmart-batch.ps1 ; then compare-deals -> diff-board -> vet.
#>
param([string]$Raw = 'out\staples500\walmart-batch1-raw.txt', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$regDir = Join-Path $root 'out\regular'

function Parse-WMSize([string]$unitStr, [double]$total) {
  # ASCII-only: the cents symbol encodes unreliably, so detect cents by the ABSENCE of a '$' (Walmart shows
  # "17.9 (cent)/oz" vs "$5.31/lb"). \D* swallows whatever the cents glyph decoded to, between number and '/'.
  $hasDollar = $unitStr.Contains('$')
  $m = [regex]::Match($unitStr, '([\d.]+)\D*/\s*(fl\s*oz|floz|oz|lb|ea|ct|each|count)', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $num = [double]$m.Groups[1].Value
  $unit = ($m.Groups[2].Value.ToLower() -replace '\s+', ' ')
  if ($unit -match '^(ea|each|ct|count)$') { return $null }   # per-each basis: no weight to back out
  $perunit = $num; if (-not $hasDollar) { $perunit = $num / 100.0 }
  if ($perunit -le 0) { return $null }
  $qty = [math]::Round($total / $perunit, 1)
  if ($qty -le 0) { return $null }
  $u = 'oz'; if ($unit -match 'fl') { $u = 'fl oz' } elseif ($unit -match 'lb') { $u = 'lb' }
  return ("$qty $u")
}

# Walmart's own unit price is occasionally WRONG, and backing the size out of it then ships a wrong
# per-unit price (2026-07-27: "Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz" was listed at 28.4 c/fl oz,
# which backs out to 10 fl oz - the store page itself says 6.8 fl oz, so we published $0.284/fl oz
# instead of $0.418, understating by 32%). The product NAME is the seller's stated pack size and beat
# the computed unit price every time we checked, so when the two disagree the NAME wins.
function Parse-NameSize([string]$name) {
  if (-not $name) { return $null }
  # packs legitimately multiply the stated unit size - no clean single-unit claim to trust
  if ($name -match '(?i)\b\d+\s*(ct|count|pk|packs?)\b' -or $name -match '(?i)\b(twin|multi|variety|value)\s*pack\b') { return $null }
  # weight RANGES ("1.0 - 3.0 lb") state no single size
  if ($name -match '(?i)\d[\d.]*\s*-\s*\d[\d.]*\s*(fl\s*oz|floz|oz|lbs?)\b') { return $null }
  # nutrition text ("16g Protein Per Serving", "4oz 112g") is not a pack size
  $clean = $name -replace '(?i)\d+\s*g\b[^,]*?protein[^,]*', '' -replace '(?i)\bper\s+serving\b', ''
  $ms = [regex]::Matches($clean, '(?i)(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lbs?)\b')
  if ($ms.Count -eq 0) { return $null }
  $m = $ms[$ms.Count - 1]          # the size conventionally trails the name
  $qty = [double]$m.Groups[1].Value
  if ($qty -le 0) { return $null }
  $raw = ($m.Groups[2].Value.ToLower() -replace '\s+', '')
  $u = 'oz'; if ($raw -match '^fl') { $u = 'fl oz' } elseif ($raw -match '^lb') { $u = 'lb' }
  return ("$qty $u")
}

function Resolve-WMSize([string]$name, [string]$unitStr, [double]$total, [System.Collections.ArrayList]$log) {
  $backed = Parse-WMSize $unitStr $total
  $named  = Parse-NameSize $name
  if (-not $backed) { return $null }
  if (-not $named)  { return $backed }
  $pb = [regex]::Match($backed, '^([\d.]+)\s+(.+)$'); $pn = [regex]::Match($named, '^([\d.]+)\s+(.+)$')
  if (-not ($pb.Success -and $pn.Success)) { return $backed }
  # only compare like with like: volume (fl oz) and weight (oz/lb) are not interchangeable
  $famB = $(if ($pb.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
  $famN = $(if ($pn.Groups[2].Value -eq 'fl oz') { 'vol' } else { 'wt' })
  if ($famB -ne $famN) { return $backed }
  $ozB = [double]$pb.Groups[1].Value; if ($pb.Groups[2].Value -eq 'lb') { $ozB *= 16 }
  $ozN = [double]$pn.Groups[1].Value; if ($pn.Groups[2].Value -eq 'lb') { $ozN *= 16 }
  if ($ozB -le 0 -or $ozN -le 0) { return $backed }
  if ([math]::Abs($ozN / $ozB - 1) -le 0.10) { return $backed }
  [void]$log.Add(("{0}  Walmart unit price backs out to [{1}] but the name states [{2}] - using the name ({3:N4} -> {4:N4} per unit)" -f `
      $name, $backed, $named, ($total / $ozB), ($total / $ozN)))
  return $named
}

if ($SelfTest) {
  # Pure computation, no I/O. Locks the 2026-07-27 fish-sauce incident and the false positives that a
  # naive "name always wins" rule would create.
  $cases = @(
    # name,                                                        unitStr,      total, expected size
    @{ n='Kikkoman Gluten-Free Fish Sauce, 6.8 fl oz Glass Bottle'; u='28.4 c/fl oz'; t=2.84;  e='6.8 fl oz'  }, # THE bug: unit price backs out to 10 fl oz
    @{ n='Thai Kitchen Gluten Free Premium Fish Sauce, 6.76 fl oz'; u='70.0 c/fl oz'; t=4.76;  e='6.8 fl oz'  }, # agree (within 10%) -> keep backed-out
    @{ n='Great Value Lasagna Pasta, 16 oz';                        u='11.5 c/oz';   t=1.84;  e='16 oz'      }, # agree
    @{ n='Armour Corned Beef Hash, 16g Protein Per Serving, 14 oz'; u='19.4 c/oz';   t=2.72;  e='14 oz'      }, # nutrition grams must not be read as a size
    @{ n='Sanderson Farms Whole Chicken, 11.0 - 12.2 lb';           u='$1.32/lb';    t=15.27; e='11.6 lb'    }, # a weight RANGE states no single size
    @{ n='Great Value Sweet Cream Salted Butter Twin Pack, 16 oz';  u='$2.98/lb';    t=5.96;  e='2 lb'       }, # pack marker -> name size is per-unit, not pack
    @{ n='(4 pack) Skinner Thin Spaghetti Pasta, 12-Ounce Bag';     u='9.9 c/oz';    t=4.75;  e='48 oz'      }, # pack marker
    @{ n='Mina Harissa Spicy Moroccan Red Pepper Sauce, 10 Fl oz';  u='49.8 c/fl oz';t=4.98;  e='10 fl oz'   }  # agree
  )
  $bad = 0; $log = New-Object System.Collections.ArrayList
  foreach ($c in $cases) {
    $got = Resolve-WMSize $c.n $c.u ([double]$c.t) $log
    if ("$got" -ne $c.e) { $bad++; Write-Output ("  FAIL  [{0}] expected [{1}] got [{2}]" -f $c.n, $c.e, $got) }
  }
  # a volume unit price must never be overridden by a weight name size (and vice versa)
  $g = Resolve-WMSize 'Some Sauce, 32 oz Jar' '10.0 c/fl oz' 6.40 $log
  if ("$g" -ne '64 fl oz') { $bad++; Write-Output ("  FAIL  cross-family override: expected [64 fl oz] got [$g]") }
  if ($bad -gt 0) { Write-Output ("import-walmart-batch self-test: $bad case(s) FAILED"); exit 1 }
  Write-Output ("import-walmart-batch self-test: all " + ($cases.Count + 1) + " cases pass")
  exit 0
}

# Raw row format (~~-delimited): name~~linePrice~~unitPrice~~usItemId[~~sellerName~~fulfillmentType]
# The last two fields are OPTIONAL and were added 2026-07-26 after the R300 run had to hand-verify ~30
# sellers: a 3P MARKETPLACE listing is NOT a Bellevue shelf price and violates the in-store rule (a
# pool-cue shop was the "Walmart price" for Goya pigeon peas). When seller/fulfillment ARE present we
# DROP any row that is not first-party Walmart. When they are ABSENT (older captures) we keep the row
# but warn, so the gap is visible rather than silent. Update the browser reducer to emit them:
#   ...+'~~'+(p.sellerName||'')+'~~'+(((p.fulfillmentType)||'').toUpperCase())
# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS ("Member(junk)s Mark Wildflower Pure Premium Honey" was the first thing
# a shopper read on the honey row). capture-lib.ps1 fixed the four live builders; these four batch importers
# were missed, so the next staples expansion would have re-introduced it.
# Measured on the staged batch files: walmart 50 of 50 lines corrupted by the default read, bakers 40 of 50,
# aldi 2 of 49, fareway 2 of 50. Walmart hits EVERY line because its unit price carries a cent glyph - so the
# corruption lands in the PRICE field, not just the name.
# Repair-Mojibake is applied per LINE rather than per parsed name: it is a no-op on clean text (it fires only
# on a mojibake signature that round-trips through a THROWING UTF-8 decoder), so this is uniform across all
# four importers and cannot damage good data.
. (Join-Path $PSScriptRoot 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }
$rows = New-Object System.Collections.ArrayList
$ids = @{}
$dropped3P = New-Object System.Collections.ArrayList
$sizeOverrides = New-Object System.Collections.ArrayList
$noSellerData = 0
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 3) { continue }
    $nm = ($f[0]).Trim()
    $price = 0.0; [void][double]::TryParse((($f[1]) -replace '[^0-9.]', ''), [ref]$price)
    $unitStr = [string]$f[2]
    $itemId = ''; if ($f.Count -ge 4) { $itemId = ($f[3]).Trim() }
    if ($price -le 0 -or -not $nm) { continue }
    # marketplace filter (only when the capture supplied seller/fulfillment)
    if ($f.Count -ge 6) {
      $seller = ($f[4]).Trim(); $fulfill = ($f[5]).Trim().ToUpper()
      $firstParty = ($fulfill -eq 'STORE' -or $fulfill -eq 'FC' -or $fulfill -eq 'SHIP') -and
                    ($seller -eq '' -or $seller -match '(?i)^walmart(\.com)?$')
      if ($fulfill -eq 'MARKETPLACE' -or -not $firstParty) {
        [void]$dropped3P.Add(("{0}  [seller={1}, fulfill={2}]" -f $nm, $seller, $fulfill)); continue
      }
    } else { $noSellerData++ }
    $size = Resolve-WMSize $nm $unitStr $price $sizeOverrides
    if (-not $size) { continue }
    [void]$rows.Add([ordered]@{ store = 'Walmart'; item = $nm; ad_price = ('$' + $price); size = $size; regular = $price; current_price = $price; source_ad = 'Walmart Bellevue 68123 shelf price (batch capture)'; as_of = $today })
    if ($itemId) { $ids[$nm] = $itemId }
  }
}
if ($dropped3P.Count -gt 0) { Write-Output ("Walmart: DROPPED {0} third-party/marketplace row(s) (in-store rule):" -f $dropped3P.Count); $dropped3P | ForEach-Object { Write-Output ('  - ' + $_) } }
if ($noSellerData -gt 0) { Write-Warning ("Walmart: {0} row(s) had no seller/fulfillment field - marketplace filter could NOT run on them. Re-capture with the 6-field reducer to close this." -f $noSellerData) }
if ($sizeOverrides.Count -gt 0) { Write-Output ("Walmart: {0} row(s) where the name size beat Walmart's own unit price:" -f $sizeOverrides.Count); $sizeOverrides | ForEach-Object { Write-Output ('  - ' + $_) } }

# ADD-only merge into today's walmart-regular
$prefix = 'walmart-regular'
$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$merged = New-Object System.Collections.ArrayList; $seen = @{}; $doc = $null
if ($prev) { $doc = Get-Content $prev.FullName -Raw | ConvertFrom-Json; foreach ($r in @($doc.deals)) { [void]$merged.Add($r); $seen[(([string]$r.item) + '|' + ([string]$r.size)).ToLower()] = $true } }
$added = 0
foreach ($r in $rows) { $k = (([string]$r.item) + '|' + ([string]$r.size)).ToLower(); if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true; [void]$merged.Add([pscustomobject]$r); $added++ }
$outFile = Join-Path $regDir ($prefix + "-$today.json")
if ($doc) { $doc.deals = $merged.ToArray(); if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }; ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
else { ([ordered]@{ store = 'Walmart'; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
($ids | ConvertTo-Json) | Set-Content (Join-Path $root 'out\staples500\walmart-itemids.json') -Encoding UTF8
Write-Output ("Walmart: parsed $($rows.Count) sized rows, added $added new, total $($merged.Count); name->itemId map: $($ids.Count) -> $(Split-Path $outFile -Leaf)")
