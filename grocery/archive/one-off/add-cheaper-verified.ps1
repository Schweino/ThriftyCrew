<#
  add-cheaper-verified.ps1

  Two override pins existed because the "See item" LINK pointed at a product that is genuinely
  CHEAPER per-unit than anything in the engine's regular file. The pin was papering over a real gap:
  the engine simply did not know the store sells the cheaper pack.

  The honest fix is not to pin - it is to give the engine the product. Then engine == link == shelf
  and the pin disappears on its own.

  Both products come from product-urls.json, i.e. they were resolved from the store's own product
  page, so no price is invented here.
    Family Fare : Folgers Classic Roast Ground Coffee 30.5 oz  $17.99  (0.5898/oz vs the 9.6 oz jar at 1.0406)
    Hy-Vee      : Wish Farms California Strawberries 16 oz     $2.99   (0.1869/oz vs Driscoll's at 0.3119)
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = '2026-07-14'
$rows = @(
  @{ p='family-fare'; item='Folgers Coffee, Ground, Medium, Classic Roast 30.5 Oz'; price='$17.99'; size='30.5 oz' },
  @{ p='hyvee';       item='Wish Farms California Strawberries';                    price='$2.99';  size='16 oz'   }
)
foreach ($r in $rows) {
  $f = Get-ChildItem (Join-Path $root ('out\regular\' + $r.p + '-regular-*.json')) | Sort-Object Name -Desc | Select-Object -First 1
  $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $have = @($d.deals | ForEach-Object { [string]$_.item })
  if ($have -contains $r.item) { Write-Output ('  (already present) ' + $r.item); continue }
  $all = New-Object System.Collections.ArrayList
  foreach ($x in $d.deals) { [void]$all.Add($x) }
  [void]$all.Add([ordered]@{
    store = $d.store; item = $r.item; ad_price = $r.price; size = $r.size; regular = $null
    source_ad = 'from the verified product-urls link (engine was missing this cheaper pack) 2026-07-14'
  })
  $d.deals = $all.ToArray()
  ($d | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root ('out\regular\' + $r.p + '-regular-' + $today + '.json')) -Encoding UTF8
  Write-Output ('  ADDED [' + $d.store + '] ' + $r.item + '  ' + $r.price + ' / ' + $r.size)
}
