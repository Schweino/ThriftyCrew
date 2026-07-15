<#
  build-vet-sheet.ps1 - THE match-review workflow for vetting board matches in batches (the prework tool for
  large item runs). One row per commodity x store cell, with automatic FLAGS so a human scans a table instead of
  trusting a black box:

    price-outlier   per-unit is >2.5x or <0.4x the MEDIAN of the other stores for the same commodity - the
                    signature of a wrong product/size winning the cheapest slot (jalapeno-at-$28/lb class).
    class:<name>    the matched product name hits a wrong-class pattern from category-excludes.json (beverage /
                    babyfood / pet / household / bakery_carrier / dairy_carrier / candy). Same library the
                    blocking guard uses, so the sheet flags exactly what the gate would block.
    no-label-word   the matched name shares NO word with the commodity's label (blueberries -> "Bai ..." class;
                    the plural-include bug surfaces here even when no class pattern hits).
    no-link         the cell renders a price with no "See item" link (informational).

  Usage:
    .\build-vet-sheet.ps1                          # whole board
    .\build-vet-sheet.ps1 -Ids chuck-roast,milk    # just a batch (vet new items before publishing them)
  Output: out\vet-sheet.csv (+ console summary of flagged rows). Review flags, fix rules, re-run until clean.
#>
param([string[]]$Ids = @(), [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$lib = Get-Content (Join-Path $root 'category-excludes.json') -Raw | ConvertFrom-Json
$catOf = @{}
foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) {
  foreach ($id in @($c.commodities)) { $catOf[[string]$id] = [string]$c.label }
}
$labelOf = @{}
foreach ($cm in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $labelOf[[string]$cm.id] = [string]$cm.label }
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

function ClassesFor([string]$label) {
  if (-not $label) { return @($lib.universal_for_unknown) }
  foreach ($a in $lib.apply) { if ($label -match [string]$a.categories) { return @($a.classes) } }
  return @()
}
$STOP = @('fresh','whole','large','small','organic','the','and','with','pack','bag','each')

$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$rows = New-Object System.Collections.Generic.List[object]
$flagCount = @{}
foreach ($it in (Get-Content $cmpF -Raw | ConvertFrom-Json).comparison) {
  $id = [string]$it.id
  if ($Ids.Count -and ($Ids -notcontains $id)) { continue }
  $pus = @($it.stores | Where-Object { [double]$_.per_unit -gt 0 } | ForEach-Object { [double]$_.per_unit } | Sort-Object)
  $median = 0.0
  if ($pus.Count) { $median = $pus[[int][math]::Floor(($pus.Count - 1) / 2)] }
  $classes = ClassesFor $catOf[$id]
  $labelWords = @(((([string]$labelOf[$id]).ToLower() -replace '[^a-z0-9 ]',' ') -split '\s+') | Where-Object { $_.Length -ge 4 -and ($STOP -notcontains $_) })

  foreach ($s in $it.stores) {
    if ([double]$s.per_unit -le 0) { continue }
    $nm = [string]$s.item
    $flags = @()
    if (($pus.Count -ge 3) -and ($median -gt 0)) {
      $r = [double]$s.per_unit / $median
      if (($r -ge 2.5) -or ($r -le 0.4)) { $flags += 'price-outlier' }
    }
    foreach ($cl in $classes) {
      $ex = [string]$lib.exempt.$cl
      if ($ex -and ($id -match $ex)) { continue }
      foreach ($pat in @($lib.classes.$cl)) { if ($nm -imatch $pat) { $flags += ('class:' + $cl); break } }
    }
    if ($labelWords.Count) {
      $nmLow = $nm.ToLower()
      $hit = $false
      foreach ($w in $labelWords) {
        # stem the trailing 's' so "avocados"/"Hass Avocado" and "apples"/"Gala Apple" don't read as mismatches
        $stem = $w.TrimEnd('s')
        if (($nmLow -match [regex]::Escape($w)) -or ($stem.Length -ge 4 -and $nmLow -match [regex]::Escape($stem))) { $hit = $true; break }
      }
      if (-not $hit) { $flags += 'no-label-word' }
    }
    $e = $pd.$id.([string]$s.store)
    if (-not ($e -and $e.url)) { $flags += 'no-link' }

    foreach ($f in $flags) { if (-not $flagCount.ContainsKey($f)) { $flagCount[$f] = 0 }; $flagCount[$f]++ }
    $rows.Add([pscustomobject]@{
      id = $id; category = [string]$catOf[$id]; unit = [string]$it.unit; store = [string]$s.store
      item = $nm; size = [string]$s.size; per_unit = [double]$s.per_unit; type = [string]$s.type
      flags = ($flags -join ';')
    })
  }
}

$csv = Join-Path $OutDir 'vet-sheet.csv'
$rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
$flagged = @($rows | Where-Object { $_.flags -and ($_.flags -ne 'no-link') })   # no-link alone is informational
Write-Output ("vet sheet: {0} cells -> {1}" -f $rows.Count, $csv)
Write-Output ("flag counts: " + ((($flagCount.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $flagCount[$_] }) -join '  '))
Write-Output ("rows needing REVIEW (any flag besides bare no-link): " + $flagged.Count)
foreach ($x in ($flagged | Select-Object -First 25)) {
  Write-Output ("  {0,-22} [{1,-12}] {2,-16} `${3,-8} <{4}>" -f $x.id, $x.store, $x.flags, $x.per_unit, $x.item.Substring(0, [Math]::Min(48, $x.item.Length)))
}
if ($flagged.Count -gt 25) { Write-Output ("  ... and " + ($flagged.Count - 25) + " more - see vet-sheet.csv") }
