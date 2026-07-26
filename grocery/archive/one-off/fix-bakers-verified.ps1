<#
  fix-bakers-verified.ps1

  Baker's has the same disease Hy-Vee had: the board is carrying the REGULAR price where the store is actually
  running a discount. Verified live today at Baker's Saddlecreek (888 S Saddle Creek Rd, Omaha), warm session:

    Heritage Farm Boneless Skinless Chicken Breasts
        store: "about $10.31  Discounted From $13.01  $2.29/lb"      board was: $2.89/lb  (the regular)
    Kroger Salted Butter Sticks, 4 sticks / 16 oz
        store: "$2.99  Discounted From $3.49  $0.19/oz"              board was: $3.49/lb  (the regular)
        (the 32 oz "BIG DEAL" is $6.49 = $0.20/oz = $3.25/lb, so the 16 oz at $2.99/lb is genuinely cheaper)

  These two are corrected here from a direct reading of the store. They are NOT the whole problem - Baker's is
  Akamai-gated, so unlike Hy-Vee it has no headless API and its prices are still captured by a browser pass.
  A full Baker's current-price pull is the next job; this file exists so the two prices we have PROVEN wrong
  are not left wrong in the meantime.

  Nothing is estimated. Both numbers were read off the store's own product listing today.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date -Format 'yyyy-MM-dd')

$fixes = @(
  @{ match='Heritage Farm Boneless Skinless Chicken Breasts'; price=2.29; size='lb';    note='store: about $10.31, Discounted From $13.01, $2.29/lb' },
  @{ match='Kroger Salted Butter Sticks';                     price=2.99; size='16 oz'; note='store: $2.99, Discounted From $3.49, $0.19/oz (4 sticks / 16 oz)' }
)

$regF = (Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') |
  Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$doc = Get-Content $regF.FullName -Raw | ConvertFrom-Json

$rows = New-Object System.Collections.ArrayList
$fixed = 0
foreach ($d in $doc.deals) {
  $h = [ordered]@{ store=[string]$d.store; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  foreach ($k in @('as_of','carried_forward','restored','restored_for')) { if ($d.$k) { $h[$k] = $d.$k } }

  foreach ($f in $fixes) {
    # exact size match too - "Kroger Salted Butter Sticks" also names the 32 oz BIG DEAL, and overwriting THAT
    # row with the 16 oz price would swap one wrong number for another.
    if ((([string]$d.item).Trim() -eq $f.match) -and (([string]$d.size).Trim() -eq $f.size)) {
      $old = [string]$d.ad_price
      $h['ad_price']  = ('$' + $f.price)
      $h['regular']   = [double]$f.price
      $h['as_of']     = $today
      $h['source_ad'] = 'Baker''s Saddlecreek (Omaha) current shelf price, read from the store'
      $h['verified']  = $f.note
      Write-Output ('  fixed  {0,-46} {1,-9} -> ${2}   ({3})' -f $f.match, $old, $f.price, $f.note)
      $fixed++
    }
  }
  [void]$rows.Add($h)
}

Write-Output ''
Write-Output ("rows corrected: $fixed")
if ($WhatIf) { Write-Output 'WhatIf: nothing written'; return }
if ($fixed -eq 0) { Write-Output 'nothing matched - check the item names/sizes in the Baker''s file'; return }

$doc.deals = $rows.ToArray()
($doc | ConvertTo-Json -Depth 6) | Set-Content $regF.FullName -Encoding UTF8
Write-Output ("wrote -> " + $regF.Name)
