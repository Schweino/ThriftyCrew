<#
  who-claims-r300.ps1 - replicates compare-deals.ps1's Match-Category EXACTLY (array order first-match-wins,
  GLOBAL_EXCLUDE parsed live out of compare-deals.ps1, relax_global, name-variant normalization) and reports
  which commodity would claim each test product name. Used to prove the r300 registration steals nothing and
  is stolen from by nobody.
    .\who-claims-r300.ps1 -NamesFile out\r300\testnames.txt
#>
param([string]$NamesFile = 'out\r300\testnames.txt', [string]$CommoditiesFile = 'commodities.json')
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'

# parse GLOBAL_EXCLUDE straight out of compare-deals.ps1 (never copy-paste: rules must not drift)
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '(?s)\$GLOBAL_EXCLUDE\s*=\s*@\((.*?)\r?\n\)')
if (-not $m.Success) { throw 'could not parse GLOBAL_EXCLUDE out of compare-deals.ps1' }
$GLOBAL_EXCLUDE = @()
foreach ($line in ($m.Groups[1].Value -split "`n")) {
  $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
  foreach ($q in [regex]::Matches($l, "'((?:[^']|'')*)'")) { $GLOBAL_EXCLUDE += ($q.Groups[1].Value -replace "''", "'") }
}
$commodities = Get-Content (Join-Path $root $CommoditiesFile) -Raw | ConvertFrom-Json

function Get-MatchTexts([string]$name) {
  $n = $name.ToLower()
  $v = $n -replace ',?\s*priced per\s+\w+', ''
  $v = (($v -replace '\band\b', ' ') -replace '\s{2,}', ' ').Trim()
  return ,@($n, $v)
}
function Match-Category($name) {
  $texts = Get-MatchTexts $name
  $n = $texts[0]
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit = $true; break } }; if ($hit) { break } }
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
    return [pscustomobject]@{ id = [string]$c.id; ghits = ($ghits -join ',') }
  }
  return [pscustomobject]@{ id = '(nobody)'; ghits = ($ghits -join ',') }
}

$np = Join-Path $root $NamesFile
foreach ($line in (Get-Content $np)) {
  $t = $line.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
  # optional "expected-id<TAB>product name"
  $exp = $null; $name = $t
  if ($t -match "^([a-z0-9-]+)\t(.+)$") { $exp = $Matches[1]; $name = $Matches[2] }
  $r = Match-Category $name
  $flag = ''
  if ($exp) { $flag = if ($r.id -eq $exp) { 'OK  ' } else { 'MISS' } }
  Write-Output ("{0} {1,-24} <- {2}{3}" -f $flag, $r.id, $name, $(if ($r.ghits) { "   [global:$($r.ghits)]" } else { '' }))
}
