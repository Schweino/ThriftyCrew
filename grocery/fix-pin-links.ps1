<#
  fix-pin-links.ps1 - correct the links behind the last override pins, each verified on the store's
  own page on 2026-07-14. A pin only exists because the link disagreed with the engine; fix the link
  (or the engine's data) and the pin disappears on its own.

    sweet-corn / Baker's : the link had captured $0.40, but Baker's shows "$0.40 Discounted From $0.60"
                           - 40c is a SALE. The everyday cell must carry the $0.60 regular, which is
                           exactly what the engine computed. Link price corrected to 0.60.
    yeast / Hy-Vee       : link pointed at the Fleischmann's 3-packet strip; the store's cheapest is
                           Red Star Active Dry Yeast 4 oz at $5.48 (1.37/oz). Re-pointed.
    yeast / Fareway      : same - Red Star 4 oz, regular $7.19 (currently on sale $5.99). Re-pointed.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$f = Join-Path $root 'product-urls.json'
Copy-Item $f (Join-Path $root 'out\product-urls.backup-pins.json') -Force
$doc = Get-Content $f -Raw | ConvertFrom-Json

# 1. Baker's sweet corn - the snapshot caught the sale, not the shelf price
$e = $doc.items.'sweet-corn'."Baker's"
if ($e) { $e.price = 0.60; Write-Output ("  sweet-corn / Baker's  price 0.40 (sale) -> 0.60 (regular)") }

# 2/3. yeast - re-point both links at the 4 oz jar the engine (correctly) picks as cheapest
$hv = $doc.items.yeast.'Hy-Vee'
if ($hv) {
  $hv.name  = 'Red Star Active Dry Yeast 4 oz'
  $hv.price = 5.48
  $hv.size  = '4 oz'
  $hv.url   = 'https://www.hy-vee.com/aisles-online/p/40339/red-star-active-dry-yeast-4-oz'
  if ($hv.PSObject.Properties['board_pu']) { $hv.board_pu = $null }
  Write-Output ('  yeast / Hy-Vee        -> Red Star Active Dry Yeast 4 oz  $5.48')
}
$fw = $doc.items.yeast.'Fareway'
if ($fw) {
  $fw.name  = 'Red Star Active Dry Yeast 4 oz'
  $fw.price = 7.19
  $fw.size  = '4 oz'
  $fw.url   = 'https://shop.fareway.com/store/fareway-meat-grocery/products/53782-red-star-active-dry-yeast-4-0-oz'
  if ($fw.PSObject.Properties['board_pu']) { $fw.board_pu = $null }
  Write-Output ('  yeast / Fareway       -> Red Star Active Dry Yeast 4 oz  $7.19 regular')
}

($doc | ConvertTo-Json -Depth 8) | Set-Content $f -Encoding UTF8
Write-Output ''
Write-Output 'product-urls.json updated (backup: out\product-urls.backup-pins.json)'
