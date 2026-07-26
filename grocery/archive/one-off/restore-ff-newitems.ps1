<#
  restore-ff-newitems.ps1

  On 2026-07-14 the Family Fare pull came back partial (380 of ~590 products) and, because a plain overwrite
  passed the 50%-wipeout guard, it silently dropped 210 products - including all 24 commodities registered
  that morning (the cleaners + pantry batch). Family Fare lost 24 board cells with nothing logged.
  pull-regular-familyfare.ps1 now carries forward products a partial pull didn't return, so this cannot
  recur - but the rows already destroyed have to be put back by hand, once.

  NOTHING HERE IS INVENTED. Every row is rebuilt from OUR OWN capture of the real Family Fare catalogue:
  the 2026-07-13 comparison, which was built from a full FF pull and carries the exact product name, shelf
  price and size for each cell. 21 of the 24 are independently corroborated by product-urls.json (the
  resolved "See item" product, captured separately from Freshop) and every one of those 21 agrees to the
  cent. The other 3 (kidney-beans, lemon-juice, shower-cleaner) are real captures that were simply never
  link-resolved; they are restored and left without a link rather than dropped.

  Safe to re-run: a row is only added if that product is not already in the file.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$regDir = Join-Path $root 'out\regular'

$ids = @('bread-crumbs','chicken-thighs','chickpeas','cornstarch','crushed-tomatoes','drain-cleaner',
         'dried-oregano','dried-parsley','floor-cleaner','gelatin','ground-cinnamon','ground-turmeric',
         'italian-seasoning','kidney-beans','lemon-juice','onion-powder','oven-cleaner','paprika',
         'red-pepper-flakes','shower-cleaner','soy-sauce','tomato-paste','tomato-sauce','white-vinegar')

$srcF = Join-Path $root 'out\comparison-2026-07-13.json'
$src = @((Get-Content $srcF -Raw | ConvertFrom-Json).comparison)
$pd  = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

$curF = (Get-ChildItem (Join-Path $regDir 'family-fare-regular-*.json') |
  Where-Object { $_.BaseName -match '^family-fare-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1)
$doc = Get-Content $curF.FullName -Raw | ConvertFrom-Json
$asOf = '2026-07-13'   # the date these prices were actually captured from Family Fare - not today

$have = @{}
foreach ($d in $doc.deals) { $have[([string]$d.item).ToLower()] = $true }

$rows = New-Object System.Collections.ArrayList
foreach ($d in $doc.deals) {
  $h = [ordered]@{ store='Family Fare'; item=[string]$d.item; ad_price=[string]$d.ad_price; size=[string]$d.size; regular=$d.regular; source_ad=[string]$d.source_ad }
  if ($d.as_of) { $h['as_of'] = [string]$d.as_of }
  if ($d.carried_forward) { $h['carried_forward'] = $true }
  [void]$rows.Add($h)
}

$added = 0; $skipped = 0; $conflict = 0
$expect = @{}   # id -> per_unit the 07-13 board published, so the rebuild can be proved correct
foreach ($id in $ids) {
  $it = $src | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $it) { Write-Warning ("no 07-13 row for " + $id); continue }
  $x = $it.stores | Where-Object { $_.store -eq 'Family Fare' } | Select-Object -First 1
  if (-not $x) { Write-Warning ("no 07-13 Family Fare cell for " + $id); continue }

  $name = [string]$x.item
  if ($have.ContainsKey($name.ToLower())) { $skipped++; continue }

  $bp = 0.0; [void][double]::TryParse((([string]$x.ad) -replace '[^0-9.]',''), [ref]$bp)
  if ($bp -le 0) { Write-Warning ("unparseable price for " + $id); continue }

  # corroborate against the independently-captured link product before trusting the row
  $e = $pd.$id.'Family Fare'
  $note = 'no link to corroborate'
  if ($e -and $e.price) {
    $lp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$lp)
    if ($lp -gt 0) {
      if ([math]::Abs($lp - $bp) / $bp -le 0.02) { $note = 'corroborated by product-urls' }
      else { $conflict++; Write-Warning ("PRICE CONFLICT {0}: board 07-13 = `${1}, link = `${2} - NOT restoring" -f $id, $bp, $lp); continue }
    }
  }

  [void]$rows.Add([ordered]@{
    store     = 'Family Fare'
    item      = $name
    ad_price  = ('$' + $bp)
    size      = [string]$x.size
    regular   = $bp
    source_ad = 'everyday shelf price'
    as_of     = $asOf
    restored  = ('rebuilt from the 2026-07-13 Family Fare capture after the partial pull dropped it; ' + $note)
  })
  $have[$name.ToLower()] = $true
  $expect[$id] = [double]$x.per_unit
  $added++
  Write-Output ("  + {0,-19} {1,-44} `${2,-7} {3}" -f $id, $name, $bp, ([string]$x.size))
}

Write-Output ''
Write-Output ("restored: $added   already present: $skipped   price conflicts (skipped): $conflict")

if ($WhatIf) { Write-Output 'WhatIf: no file written'; return }

$doc.deals = $rows.ToArray()
$doc | Add-Member -NotePropertyName deal_count -NotePropertyValue @($rows).Count -Force
($doc | ConvertTo-Json -Depth 6) | Set-Content $curF.FullName -Encoding UTF8
Write-Output ("Family Fare file now " + @($rows).Count + " rows -> " + $curF.Name)

# the proof obligation: after the rebuild, every restored cell must land back on the per-unit the 07-13
# board published. Persist the expected values so verify-ff-restore can check them.
($expect | ConvertTo-Json) | Set-Content (Join-Path $root 'out\ff-restore-expected.json') -Encoding UTF8
