<#
  add-search-terms.ps1

  pull-regular-familyfare.ps1 regenerates Family Fare's everyday prices EVERY DAY from the term map in
  commodity-search.json. A commodity with no term is never fetched - so it silently disappears from
  Family Fare on the next pull, and any row added to the regular file by hand is wiped with it.

  The 22 commodities added on 2026-07-14 (the cleaners + pantry items) had no terms, which is why the
  daily pull dropped Family Fare from ~177 board rows to 55. Registering a commodity is not finished
  until it has a search term.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$f = Join-Path $root 'commodity-search.json'
Copy-Item $f (Join-Path $root 'out\commodity-search.backup-2026-07-14.json') -Force
$doc = Get-Content $f -Raw | ConvertFrom-Json

$new = [ordered]@{
  'floor-cleaner'     = 'floor cleaner'
  'drain-cleaner'     = 'drain cleaner'
  'oven-cleaner'      = 'oven cleaner'
  'shower-cleaner'    = 'bathroom cleaner'
  'furniture-polish'  = 'furniture polish'
  'insect-spray'      = 'ant roach killer spray'
  'cornstarch'        = 'corn starch'
  'bread-crumbs'      = 'bread crumbs'
  'paprika'           = 'paprika'
  'dried-oregano'     = 'oregano leaves'
  'dried-parsley'     = 'parsley flakes'
  'ground-cinnamon'   = 'ground cinnamon'
  'ground-turmeric'   = 'ground turmeric'
  'red-pepper-flakes' = 'crushed red pepper'
  'chickpeas'         = 'garbanzo beans'
  'kidney-beans'      = 'kidney beans'
  'crushed-tomatoes'  = 'crushed tomatoes'
  'tomato-paste'      = 'tomato paste'
  'tomato-sauce'      = 'tomato sauce'
  'soy-sauce'         = 'soy sauce'
  'white-vinegar'     = 'distilled white vinegar'
  'lemon-juice'       = 'lemon juice'
}
$added = 0
foreach ($k in $new.Keys) {
  if ($doc.terms.PSObject.Properties[$k]) { Write-Output ("  (already) " + $k); continue }
  $doc.terms | Add-Member -NotePropertyName $k -NotePropertyValue $new[$k]
  Write-Output ("  + {0,-20} '{1}'" -f $k, $new[$k])
  $added++
}
($doc | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Write-Output ''
Write-Output ("added $added search terms -> commodity-search.json")
