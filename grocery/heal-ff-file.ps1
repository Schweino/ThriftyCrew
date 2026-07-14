<#
  heal-ff-file.ps1

  Today's Family Fare pull returned 380 rows (a partial catalogue - Freshop was rate-limiting), which
  OVERWROTE a 590-row file. The 210 lost rows include every commodity added on 2026-07-14 (the cleaners
  and pantry items), because they had no entry in commodity-search.json and so were never fetched.
  The terms are registered now, so the next un-throttled pull will fetch them natively - but until then
  the board would be missing them.

  Heal by UNION, preferring today's fresher price: keep all 380 fresh rows, and re-add only the rows
  from the last good file whose product is absent from today's pull. No price is invented; every row
  came from a real Family Fare pull.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$regDir = Join-Path $root 'out\regular'

$curF = Join-Path $regDir 'family-fare-regular-2026-07-14.json'
$oldF = Join-Path $regDir 'family-fare-regular-2026-07-13.json'
Copy-Item $curF (Join-Path $root 'out\family-fare-2026-07-14.pre-heal.json') -Force

$cur = Get-Content $curF -Raw | ConvertFrom-Json
$old = Get-Content $oldF -Raw | ConvertFrom-Json

$have = @{}
foreach ($d in $cur.deals) { $have[[string]$d.item] = $true }

$all = New-Object System.Collections.ArrayList
foreach ($d in $cur.deals) { [void]$all.Add($d) }
$readded = 0
foreach ($d in $old.deals) {
  $k = [string]$d.item
  if ($have.ContainsKey($k)) { continue }
  [void]$all.Add($d)
  $have[$k] = $true
  $readded++
}
$cur.deals = $all.ToArray()
$cur | Add-Member -NotePropertyName deal_count -NotePropertyValue @($all).Count -Force
$cur | Add-Member -NotePropertyName healed -NotePropertyValue 'union with last good file; today''s pull was rate-limited to a partial catalogue' -Force
($cur | ConvertTo-Json -Depth 6) | Set-Content $curF -Encoding UTF8

Write-Output ("today's fresh rows : " + @($cur.deals).Count - $readded)
Write-Output ("re-added from last good: $readded")
Write-Output ("Family Fare file now: " + @($all).Count + ' rows')
