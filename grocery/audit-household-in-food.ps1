<#
  audit-household-in-food.ps1

  Bug class found 2026-07-14: "Lysol Mango & Hibiscus Bathroom Cleaner" was matching the MANGOES
  commodity, because household products are routinely named after the fruit/herb used as their SCENT
  ("Lemon Scent Furniture Polish", "Lavender Floor Cleaner", "Orange Degreaser"). A cleaner landing in
  a produce row is always wrong and is invisible to a per-unit sanity band.

  This sweeps EVERY row of EVERY store regular file: any product whose name is unmistakably a
  household/cleaning item but which resolves to a commodity OUTSIDE the Household category is a bug.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '\$GLOBAL_EXCLUDE\s*=\s*@\((?<body>[\s\S]*?)\r?\n\)')
$GLOBAL_EXCLUDE = Invoke-Expression ('@(' + $m.Groups['body'].Value + ')')
$commodities = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$cats = (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories
# A cleaning product legitimately belongs in ANY non-edible category, not just Household
# (a "Tongue Cleaner Toothbrush" correctly lands in Personal Care). Only an EDIBLE commodity
# claiming a cleaning product is a bug.
$NONFOOD = @('Household','Personal Care','Baby','Pet')
$nonFoodIds = @($cats | Where-Object { $NONFOOD -contains $_.label } | ForEach-Object { $_.commodities } )

function Match-Category($name) {
  $n = $name.ToLower()
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { if ($n -match $inc) { $hit = $true; break } }
    if (-not $hit) { continue }
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      $blocked = $false
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($exc in $c.exclude) { if ($n -match $exc) { $bad = $true; break } }
    if ($bad) { continue }
    return $c.id
  }
  return $null
}

# names that can only be a household/cleaning product
$HOUSEHOLD_SIGNAL = '(?i)(cleaner|detergent|\bbleach\b|disinfect|degreaser|furniture\s+polish|air\s+freshener|insecticide|roach|drain\s+opener|laundry|dish\s*soap|fabric\s+softener|dryer\s+sheet|toilet|scrubbing\s+bubbles|\blysol\b|\bdrano\b|\bpledge\b|\bwindex\b|\bclorox\b|\bfebreze\b|\bswiffer\b|\bcomet\b|\bajax\b)'

$bugs = 0; $scanned = 0
foreach ($f in Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) {
  # only the newest file per store is what compare-deals actually reads
  $prefix = ($f.BaseName -replace '-regular-.*$', '')
  $newest = Get-ChildItem (Join-Path $root ('out\regular\' + $prefix + '-regular-*.json')) |
            Sort-Object Name -Descending | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }

  $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
  foreach ($d in $doc.deals) {
    $name = [string]$d.item
    if (-not $name) { continue }
    $scanned++
    if ($name -notmatch $HOUSEHOLD_SIGNAL) { continue }
    $owner = Match-Category $name
    if (-not $owner) { continue }                       # unmatched = harmless, it just never lands
    if ($nonFoodIds -contains $owner) { continue }      # correctly in a non-edible category
    $bugs++
    Write-Output ("  BUG  [{0}] '{1}'" -f $doc.store, $name)
    Write-Output ("        -> lands in EDIBLE commodity '{0}'" -f $owner)
  }
}
Write-Output ''
Write-Output ("scanned $scanned rows")
if ($scanned -eq 0) {
  Write-Output 'HOUSEHOLD-IN-FOOD AUDIT BLIND: examined ZERO rows - out\regular matched no canonical store file, or every newest-per-store pick carried no .deals rows (a puller renaming the deals array is the guard-11 failure mode). The cleaner-in-a-food-commodity invariant was NOT tested this run. Unknown is not a pass.'
  exit 3
}
if ($bugs -eq 0) { Write-Output 'HOUSEHOLD-IN-FOOD AUDIT OK: no cleaning product is sitting in a food commodity.'; exit 0 }
Write-Output ("HOUSEHOLD-IN-FOOD AUDIT FAILED: $bugs row(s). Board NOT safe to publish."); exit 2

