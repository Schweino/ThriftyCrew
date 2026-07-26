# patch-display-itemize.ps1 (r100) - PROSE-SAFE fix for the pantry-omitted-from-Ingredients bug.
# r100's build-specs writes empty-prose skeletons (writers filled prose later, only in git), so re-running
# it is destructive. Instead we surgically rebuild ONLY the ingredients_display array of each spec so it
# itemizes EVERY ingredient (matching the scaler's full set), then text-splice that one field back into the
# raw JSON - every other field, including prose, is left byte-identical.
#
# Reconstruction reproduces fixed-build-specs exactly: display line = '<strong>{item}{brand}:</strong> {buy} ({grams} g)'
# where buy/grams come from scaler.ing (already the full item set) and brand from food-macros-db (same rule).
# SAFETY: if any line currently in ingredients_display is NOT reproduced, the spec is SKIPPED (never silently
# altered). Dry-run by default; pass -Apply to write.
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbm = @{}
(Get-Content (Join-Path $here '..\food-macros-db.json') -Raw -Encoding utf8 | ConvertFrom-Json).items | ForEach-Object { $dbm[$_.item] = $_ }

function New-DisplayArray($scalerIng) {
  $out = @()
  foreach ($s in $scalerIng) {
    $d = $dbm[$s.item]; $brand = ''
    if ($d -and $d.brand -and $d.brand -notmatch '^fresh$|store') { $brand = ' (' + (($d.brand -split '/')[0].Trim()) + ')' }
    $out += ('<strong>' + $s.item + $brand + ':</strong> ' + $s.buy + ' (' + [int]$s.grams + ' g)')
  }
  ,$out
}

$specs = Get-ChildItem (Join-Path $here 'specs\*.json')
$patched = 0; $skipped = 0; $unchanged = 0; $addedTotal = 0
foreach ($f in $specs) {
  $raw = Get-Content $f.FullName -Raw -Encoding utf8
  $spec = $raw | ConvertFrom-Json
  if (-not $spec.scaler -or -not $spec.scaler.ing) { Write-Warning ("{0}: no scaler, SKIP" -f $f.Name); $skipped++; continue }
  $new = New-DisplayArray $spec.scaler.ing
  $cur = @($spec.ingredients_display)
  $newSet = @{}; $new | ForEach-Object { $newSet[$_] = 1 }
  $missing = @($cur | Where-Object { -not $newSet.ContainsKey($_) })
  if ($missing.Count -gt 0) {
    Write-Warning ("{0}: {1} existing line(s) NOT reproduced -> SKIP:`n    {2}" -f $f.Name, $missing.Count, ($missing -join "`n    "))
    $skipped++; continue
  }
  $added = @($new | Where-Object { $cur -notcontains $_ })
  if ($added.Count -eq 0) { $unchanged++; continue }
  $addedTotal += $added.Count
  if (-not $Apply) {
    Write-Output ("{0}: +{1} line(s):  {2}" -f $f.BaseName, $added.Count, (($added | ForEach-Object { ($_ -replace '<[^>]+>','' -replace ':.*','') }) -join ', '))
  } else {
    $arrJson = '[' + (($new | ForEach-Object { ($_ | ConvertTo-Json -Compress) }) -join ',') + ']'
    $rx = [regex]'"ingredients_display"\s*:\s*\[[^\]]*\]'
    if ($rx.Matches($raw).Count -ne 1) { throw ("{0}: expected exactly 1 ingredients_display array, found {1}" -f $f.Name, $rx.Matches($raw).Count) }
    $out = $rx.Replace($raw, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '"ingredients_display": ' + $arrJson }, 1)
    [IO.File]::WriteAllText($f.FullName, $out, (New-Object System.Text.UTF8Encoding($false)))
    $patched++
  }
}
Write-Output ("`n{0}: patched {1}, would-add-to {2}, unchanged {3}, skipped {4}, total lines added {5}" -f ($(if($Apply){'APPLIED'}else{'DRY-RUN'})), $patched, ($specs.Count - $unchanged - $skipped), $unchanged, $skipped, $addedTotal)
