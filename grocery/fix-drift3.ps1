<#
  fix-drift3.ps1 - the last three cells where the board and its own linked product disagreed.
  All three verified on the store's page 2026-07-14.

    Baker's cottage cheese : board carried $2.89; Baker's now shows "Everyday Low Price $3.19"
                             ($0.13/oz on their own card). The board price was simply stale.
    Hy-Vee orange juice    : the board matched the 0.5 gal at its $4.99 regular (0.078/floz). Hy-Vee
                             also sells the 1 gal at $8.99 = 0.0702/floz, which is cheaper and is what
                             the link points at. The engine was missing the bigger jug.
    Hy-Vee peanut butter   : same shape - board matched the 16 oz at $2.68 regular (0.1675/oz); the
                             40 oz jar is $5.98 = 0.1495/oz.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = '2026-07-14'

# 1. Baker's: stale price
$f = Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$d = Get-Content $f.FullName -Raw | ConvertFrom-Json
foreach ($r in $d.deals) {
  if ($r.item -match '(?i)Kroger.*4% Milkfat Small Curd Cottage Cheese') {
    $old = $r.ad_price
    $r.ad_price = '$3.19'
    Write-Output ("  [Baker's]  cottage cheese price $old -> `$3.19 (store shows Everyday Low Price `$3.19)")
  }
}
($d | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root ('out\regular\bakers-regular-' + $today + '.json')) -Encoding UTF8

# 2/3. Hy-Vee: add the cheaper large sizes the engine did not have
$f = Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$d = Get-Content $f.FullName -Raw | ConvertFrom-Json
$have = @($d.deals | ForEach-Object { [string]$_.item })
$all = New-Object System.Collections.ArrayList
foreach ($x in $d.deals) { [void]$all.Add($x) }
foreach ($n in @(
    @{ item='Hy-Vee 100% Orange Juice 1 gal';   price='$8.99'; size='1 gal' },
    @{ item='Hy-Vee Creamy Peanut Butter 40 oz'; price='$5.98'; size='40 oz' })) {
  if ($have -contains $n.item) { Write-Output ('  (already) ' + $n.item); continue }
  [void]$all.Add([ordered]@{
    store='Hy-Vee'; item=$n.item; ad_price=$n.price; size=$n.size; regular=$null
    source_ad='verified on hy-vee.com 2026-07-14 (cheaper large size the engine was missing)'
  })
  Write-Output ('  [Hy-Vee]   ADDED ' + $n.item + '  ' + $n.price)
}
$d.deals = $all.ToArray()
($d | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root ('out\regular\hyvee-regular-' + $today + '.json')) -Encoding UTF8
