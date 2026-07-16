<#
  test-unitprice.ps1 - run the ENGINE'S OWN Get-ItemPrice / Get-UnitPrice against specific rows and show which
  branch fired. Extracts the functions straight out of compare-deals.ps1 (the same technique the audits use for
  GLOBAL_EXCLUDE) so this can never drift from the engine - a test that re-implements the logic proves nothing.

  Why: two rows with the SAME shape priced differently - Hy-Vee facial tissues ($2.29, "30 ct", each) divided to
  $0.0763, but Fareway disinfecting wipes ($3.64, "35 ct", each) came out $3.64 undivided. Reasoning about the
  regexes could not explain it, so ask the engine.

  Usage: test-unitprice.ps1            (runs the built-in contrast cases)
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw

# pull the pricing functions out of the engine verbatim
$want = @('ConvertTo-DigitNumerals', 'Get-PackCount', 'Get-SizeAmount', 'Convert-ToUnit', 'Get-ItemPrice', 'Get-UnitPrice', 'Test-Bulk', 'Test-IsMultibuy')
$got = @()
foreach ($fn in $want) {
  $m = [regex]::Match($src, '(?ms)^function\s+' + [regex]::Escape($fn) + '\s*\(.*?^\}')
  if (-not $m.Success) { Write-Warning ("could not extract " + $fn); continue }
  Invoke-Expression $m.Value
  $got += $fn
}
if (-not $Quiet) { Write-Output ('extracted from compare-deals.ps1: ' + ($got -join ', ')) }

$cases = @(
  @{ n = 'Hy-Vee facial tissues (DIVIDES today)'; price = '$2.29'; size = '30 ct'; name = 'Kleenex Everyday Facial Tissues Slim Pack 3-Ply'; unit = 'each' }
  @{ n = 'Fareway wipes (does NOT divide)'; price = '$3.64'; size = '35 ct'; name = 'Clorox Disinfecting Wipes, Bleach Free Cleaning Wipes, Fresh Scent'; unit = 'each' }
  @{ n = 'Hy-Vee wipes (does NOT divide)'; price = '$3.99'; size = '35 ct'; name = 'Clorox Disinfecting Bleach Free Crisp Lemon Cleaning Wipes'; unit = 'each' }
  @{ n = 'laundry pods "42 ea"'; price = '$12.49'; size = '42 ea'; name = 'Arm & Hammer Laundry Detergent, Concentrated, 5 In 1, Fresh Burst, Power Paks 42 Ea'; unit = 'each' }
  @{ n = 'dishwasher pacs "12 ea"'; price = '$6.99'; size = '12 ea'; name = 'Cascade Action Pacs Lemon Scent Dishwasher Detergent 12 Ea'; unit = 'each' }
  # pack-first multipack + slash-pack sizes: is the TOTAL read, or one unit / a fraction?
  @{ n = 'PACK-FIRST "6-pack 12 fl oz" (want 72 floz -> 0.0971)'; price = '$6.99'; size = '6-pack 12 fl oz'; name = 'Liquid Death Sparkling Water'; unit = 'floz' }
  @{ n = 'SLASH-PACK "6/4 oz" (want 24 oz -> 0.1454)'; price = '$3.49'; size = '6/4 oz'; name = "Mott's Apple Sauce 6 Ea"; unit = 'oz' }
  @{ n = 'control "6 pk 4 oz" (want 24 oz)'; price = '$3.49'; size = '6 pk 4 oz'; name = 'x'; unit = 'oz' }
  @{ n = 'control "12 fl oz" single (want 12)'; price = '$1.00'; size = '12 fl oz'; name = 'x'; unit = 'floz' }
  # REAL FRACTIONS must still divide - this is what the numerator<denominator guard protects
  @{ n = 'FRACTION "1/2 gal" milk (want 0.5 gal -> 7.98)'; price = '$3.99'; size = '1/2 gal'; name = 'Milk'; unit = 'gallon' }
  @{ n = 'FRACTION "3/4 lb" (want 0.75 lb -> 5.32)'; price = '$3.99'; size = '3/4 lb'; name = 'x'; unit = 'lb' }
  @{ n = 'FRACTION "1/2 gal" as floz (want 64 floz)'; price = '$3.20'; size = '1/2 gal'; name = 'x'; unit = 'floz' }
)
Write-Output ''
foreach ($c in $cases) {
  $deal = [pscustomobject]@{ store = 'X'; name = $c.name; price_text = $c.price; size_text = $c.size; regular = $null; source_ad = ''; price_type = 'everyday'; src_date = '' }
  $cat = [pscustomobject]@{ id = 'x'; unit = $c.unit; include = @(); exclude = @() }
  $pr = Get-ItemPrice $deal.price_text $deal.name $deal.regular
  $up = Get-UnitPrice $deal $cat
  $pk1 = Get-PackCount $deal.price_text; $pk2 = Get-PackCount $deal.size_text; $pk3 = Get-PackCount $deal.name
  Write-Output ('=== ' + $c.n)
  Write-Output ('    price=[' + $c.price + '] size=[' + $c.size + '] unit=' + $c.unit)
  Write-Output ('    Get-ItemPrice -> per_item=' + $pr.per_item + '  note=[' + $pr.note + ']  perlb=' + $pr.kind.perlb + '  pereach=' + $pr.kind.pereach)
  Write-Output ('    Get-PackCount  price=[' + $pk1 + ']  size=[' + $pk2 + ']  name=[' + $pk3 + ']')
  if ($up) { Write-Output ('    Get-UnitPrice -> ' + $up.unit_price + '   basis=' + $up.basis) } else { Write-Output '    Get-UnitPrice -> NULL (unpriceable)' }
  Write-Output ''
}
