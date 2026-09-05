<#
  audit-match-contested.ps1 - find every row whose owner is decided by ARRAY ORDER.

  Match-Category returns the FIRST commodity whose include matches and exclude doesn't. If two or
  more commodities match the same product name, the winner is whichever happens to sit earlier in
  commodities.json. That is not a rule - it is an accident, and it silently flips the day someone
  reorders or inserts a commodity.

  This lists every contested row and every commodity PAIR that collides, so the pairs can be
  disambiguated with an explicit exclude instead of relying on position.

  Scope: every row of the NEWEST regular file per store (what compare-deals actually reads).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '\$GLOBAL_EXCLUDE\s*=\s*@\((?<body>[\s\S]*?)\r?\n\)')
if (-not $m.Success) { Write-Output 'FATAL: cannot parse $GLOBAL_EXCLUDE'; exit 2 }
$GLOBAL_EXCLUDE = Invoke-Expression ('@(' + $m.Groups['body'].Value + ')')
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
$cats = (Read-JsonFile (Join-Path $root 'categories.json')).categories
$catOf = @{}
foreach ($c in $cats) { foreach ($id in $c.commodities) { $catOf[$id] = $c.label } }

# every commodity that WOULD claim this name, in array order (not just the winner)
function All-Owners($name) {
  $n = $name.ToLower()
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  $owners = New-Object System.Collections.ArrayList
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
    [void]$owners.Add([string]$c.id)
  }
  return $owners
}

$pairs = @{}
$rows = New-Object System.Collections.ArrayList
$scanned = 0

foreach ($f in Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) {
  $prefix = ($f.BaseName -replace '-regular-.*$', '')
  $newest = Get-ChildItem (Join-Path $root ('out\regular\' + $prefix + '-regular-*.json')) |
            Sort-Object Name -Descending | Select-Object -First 1
  if ($f.FullName -ne $newest.FullName) { continue }

  $doc = Read-JsonFile $f.FullName
  foreach ($d in $doc.deals) {
    $name = [string]$d.item
    if (-not $name) { continue }
    $scanned++
    $own = All-Owners $name
    if ($own.Count -lt 2) { continue }
    $winner = $own[0]
    $losers = @($own | Select-Object -Skip 1)
    [void]$rows.Add([pscustomobject]@{ store=[string]$doc.store; item=$name; winner=$winner; losers=($losers -join ','); })
    foreach ($l in $losers) {
      $key = $winner + ' >> ' + $l
      if (-not $pairs.ContainsKey($key)) { $pairs[$key] = 0 }
      $pairs[$key]++
    }
  }
}

Write-Output ("scanned $scanned rows")
Write-Output ("CONTESTED ROWS (owner decided by array position): " + $rows.Count)
Write-Output ''
Write-Output 'COLLIDING COMMODITY PAIRS  (winner >> also-matched)   count   [same category?]'
foreach ($k in ($pairs.Keys | Sort-Object { -$pairs[$_] })) {
  $w, $l = $k -split ' >> '
  $cw = $catOf[$w]; $cl = $catOf[$l]
  $flag = if ($cw -eq $cl) { 'same-cat' } else { "CROSS-CAT: $cw vs $cl" }
  Write-Output ("  {0,-46} {1,4}   {2}" -f $k, $pairs[$k], $flag)
}

$out = Join-Path $root 'out\match-contested.json'
@{ scanned=$scanned; contested=$rows.ToArray(); pairs=$pairs } | ConvertTo-Json -Depth 5 | Set-Content $out -Encoding UTF8
Write-Output ''
Write-Output ("detail -> " + $out)
