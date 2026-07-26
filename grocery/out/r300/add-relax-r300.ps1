<#
  add-relax-r300.ps1 - register-batch.ps1 does NOT write relax_global, so every new commodity whose OWN product
  name contains a GLOBAL_EXCLUDE token is born permanently unmatchable (the staples-500 "11 of 50 priced
  nowhere" bug). This adds the exact verbatim GLOBAL_EXCLUDE strings each r300 item needs.

  relax_global is SAFE: a commodity only ever sees products no EARLIER commodity claimed, and these 21 are the
  last entries in the array - so a relax here cannot take anything from anyone.

  Every token below was proven necessary by the probe (out\r300\who-claims-r300.ps1): the product name really
  did trip that global token.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'

$MIX   = '\bmix\b(?!\s*(?:&|and)\s*match)'   # VERBATIM from compare-deals $GLOBAL_EXCLUDE - must match char-for-char
$RELAX = @(
  @{ id='turkey-breast';    pats=@('\bfrozen\b'); why="'Butterball FROZEN Boneless Turkey Breast' - most whole breasts ship frozen" }
  @{ id='diced-ham';        pats=@('\bwater\b');  why="'John Morrell Diced Ham WATER Added' - 'water added' is on nearly every ham label" }
  @{ id='brown-gravy-mix';  pats=@($MIX);         why="'McCormick Brown Gravy MIX' - the known relax_global case for this batch" }
  @{ id='sweet-soy-sauce';  pats=@('\bsauce\b');  why="'ABC Sweet Soy SAUCE' - the commodity IS a sauce" }
  @{ id='doubanjiang';      pats=@('\bsauce\b');  why="'Lee Kum Kee Chili Bean SAUCE (Toban Djan)' - the jar is named sauce" }
  @{ id='horseradish-sauce';pats=@('\bsauce\b');  why="'Great Value Horseradish SAUCE' - the commodity IS a sauce" }
  @{ id='pigeon-peas';      pats=@('\bcanned\b'); why="'CANNED Green Pigeon Peas' - the mapper's note wrongly said canned was not a global token; it is" }
)

# fail loudly if a 'verbatim' token has drifted from compare-deals.ps1
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$m = [regex]::Match($src, '(?s)\$GLOBAL_EXCLUDE\s*=\s*@\((.*?)\r?\n\)')
$GEX = @()
foreach ($line in ($m.Groups[1].Value -split "`n")) {
  $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
  foreach ($q in [regex]::Matches($l, "'((?:[^']|'')*)'")) { $GEX += ($q.Groups[1].Value -replace "''", "'") }
}
foreach ($r in $RELAX) { foreach ($p in $r.pats) { if ($GEX -notcontains $p) { throw "relax token not found VERBATIM in GLOBAL_EXCLUDE: '$p' (id $($r.id))" } } }

$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
$n = 0
foreach ($r in $RELAX) {
  $c = $byId[$r.id]; if (-not $c) { throw "relax target not registered: $($r.id)" }
  $have = @($c.relax_global | Where-Object { $_ })
  $new = @(); foreach ($p in $r.pats) { if ($have -notcontains $p) { $new += $p } }
  if ($new.Count) {
    Write-Output ("  {0,-20} relax += {1}" -f $r.id, ($new -join ' , ')); Write-Output ("      why: " + $r.why)
    $c | Add-Member -NotePropertyName relax_global -NotePropertyValue @($have + $new) -Force
    $n += $new.Count
  } else { Write-Output ("  {0,-20} already relaxed" -f $r.id) }
}
if ($WhatIf) { Write-Output ''; Write-Output "WhatIf: $n token(s) would be added"; return }
if ($n) { ($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8; $null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json }
Write-Output ''
Write-Output ("relax_global tokens added: $n (all verified verbatim against compare-deals GLOBAL_EXCLUDE)")
