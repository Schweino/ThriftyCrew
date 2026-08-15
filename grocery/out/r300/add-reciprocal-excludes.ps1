<#
  add-reciprocal-excludes.ps1 (r300) - the OTHER half of registering a commodity. New commodities are APPENDED
  to commodities.json, and Match-Category is first-match-wins by array order, so a new id can never steal an
  existing cell - but an EXISTING, looser commodity happily swallows the new id's products and the new row is
  born permanently empty (or worse, the wrong product prices the wrong row).

  Every entry below was PROVEN by out\r300\who-claims-r300.ps1 against the pre-registration commodities.json:
  the listed commodity really did claim the listed product name. ADD-only + idempotent.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'

$RECIP = @(
  @{ id='deli-ham';      pats=@('\bdiced\b','\bcubed\b');                     why="bare '\bham\b' claimed 'Great Value Diced Ham' -> diced-ham" }
  @{ id='achiote-paste'; pats=@('\bsaz.n\b');                                  why="'\bachiote\b|\bannatto\b' claimed 'Sazon Goya con Culantro y Achiote' -> sazon-seasoning" }
  @{ id='soy-sauce';     pats=@('sweet\s+soy','ke[ct]jap','kecap');            why="'soy\s+sauce' (with a \bsauce\b relax) claimed 'ABC Sweet Soy Sauce Kecap Manis' -> sweet-soy-sauce" }
  @{ id='sugar';         pats=@('snap\s+peas');                                why="bare '\bsugar\b' claimed 'Sugar Snap Peas' -> snow-peas (pre-existing latent hijack)" }
  @{ id='frozen-corn';   pats=@('corned\s+beef');                              why="'cut\s+(?:golden\s+)?corn' (no trailing boundary) matched 'Flat CUT CORNed Beef Brisket' -> corned-beef-brisket" }
  @{ id='bread';         pats=@('\brye\b','pumpernickel');                     why="bare '\bbread\b' claimed 'Jewish Rye Bread' / 'Marble Rye Bread Loaf' -> rye-bread (variety-pricing precedent)" }
  @{ id='chili-beans';   pats=@('chili\s+bean\s+sauce','toban');               why="'chili\s+(?:style\s+)?beans?' matches 'Chili Bean Sauce'; today the global \bsauce\b token blocks it, but the fence must be a RULE, not a side effect -> doubanjiang" }
  @{ id='ground-coriander'; pats=@('\bsaz.n\b');                               why="'coriander' claimed 'Sazon GOYA with Coriander and Annatto' (the 'and'-stripping name variant makes it worse) -> sazon-seasoning" }
  @{ id='tomatoes-green-chilies'; pats=@('rotella','\bbread\b');               why="include 'ro[\s*-]?tel' has no word boundary and matched ROTELla's - a real Omaha BAKERY brand - so 'Rotella's Marble Rye Bread Loaf' resolved to canned Ro-Tel. Pre-existing latent hijack surfaced by rye-bread" }
  @{ id='tomatoes';      pats=@('\bsaz.n\b');                                  why="validate-fills: 'Sazon Goya with Cilantro & Tomato' resolved to fresh TOMATOES - a spice packet able to price the tomato cell -> sazon-seasoning" }
  @{ id='cilantro';      pats=@('\bsaz.n\b');                                  why="same product, next claimant after tomatoes was fenced: 'Sazon Goya with Cilantro & Tomato' -> fresh CILANTRO. All three live sazon SKUs now resolve to sazon-seasoning" }
)

$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
$added = 0
foreach ($r in $RECIP) {
  $c = $byId[$r.id]
  if (-not $c) { Write-Warning ("reciprocal target missing: " + $r.id); continue }
  $have = @($c.exclude)
  $new = @()
  foreach ($p in $r.pats) { if ($have -notcontains $p) { $new += $p } }
  if ($new.Count) {
    Write-Output ("  {0,-16} += {1}" -f $r.id, ($new -join ' , '))
    Write-Output ("      why: " + $r.why)
    $c.exclude = @($have + $new); $added += $new.Count
  } else { Write-Output ("  {0,-16} already fenced" -f $r.id) }
}
if ($WhatIf) { Write-Output ''; Write-Output "WhatIf: $added pattern(s) would be added, nothing written"; return }
if ($added) {
  ($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
  $null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
}
Write-Output ''
Write-Output ("reciprocal excludes added: $added (commodities.json re-validated as JSON)")
