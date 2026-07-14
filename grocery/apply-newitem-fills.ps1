<#
  apply-newitem-fills.ps1 - write the VALIDATED fills into each store's regular file.

  Input is out\newitem-accepted.json, which validate-fills.ps1 produced by running every candidate
  product name through the real compare-deals matcher. Anything that would have landed in another
  commodity's cell was already rejected there, so nothing here can hijack an existing board row.

  compare-deals reads only the NEWEST regular file per store, so we rewrite a new dated file
  containing ALL prior rows plus the new ones - never just the new ones.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = '2026-07-14'

$STOREFILE = @{
  'Aldi'        = 'aldi'
  'Walmart'     = 'walmart'
  'Hy-Vee'      = 'hyvee'
  "Baker's"     = 'bakers'
  'Family Fare' = 'family-fare'
  'Fareway'     = 'fareway'
  "Sam's Club"  = 'sams'
}

$acc = (Get-Content (Join-Path $root 'out\newitem-accepted.json') -Raw | ConvertFrom-Json).accepted
$regDir = Join-Path $root 'out\regular'

foreach ($store in $STOREFILE.Keys) {
  $rows = @($acc | Where-Object { $_.store -eq $store })
  if ($rows.Count -eq 0) { Write-Output ("  {0,-12} nothing to add" -f $store); continue }
  $prefix = $STOREFILE[$store]

  $existing = Get-ChildItem (Join-Path $regDir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
  if (-not $existing) { Write-Output ("  {0,-12} NO regular file - skipped" -f $store); continue }

  $doc = Get-Content $existing.FullName -Raw | ConvertFrom-Json
  $all = New-Object System.Collections.ArrayList
  foreach ($d in $doc.deals) { [void]$all.Add($d) }
  $have = @($doc.deals | ForEach-Object { [string]$_.item })

  $added = 0
  foreach ($r in $rows) {
    if ($have -contains [string]$r.item) { continue }
    [void]$all.Add([ordered]@{
      store     = $store
      item      = [string]$r.item
      ad_price  = ('$' + ([double]$r.price).ToString('0.00'))
      size      = [string]$r.size
      regular   = $null
      source_ad = "new-item fill 2026-07-14 (store search, in-store/everyday price, collision-validated)"
    })
    $added++
  }
  $doc.deals = $all.ToArray()
  $doc | Add-Member -NotePropertyName price_mode    -NotePropertyValue 'in-store' -Force
  $doc | Add-Member -NotePropertyName mode_verified -NotePropertyValue $today     -Force

  $out = Join-Path $regDir ($prefix + '-regular-' + $today + '.json')
  ($doc | ConvertTo-Json -Depth 6) | Set-Content $out -Encoding UTF8
  $total = @($doc.deals).Count
  Write-Output ("  {0,-12} {1} -> {2} rows (+{3})  [{4}]" -f $store, ($total - $added), $total, $added, (Split-Path $out -Leaf))
}
