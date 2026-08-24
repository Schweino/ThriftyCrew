<#
  test-commodity-rules.ps1 - FROZEN REGRESSION FIXTURES for individual commodity include/exclude rules.

  WHY THIS FILE EXISTS, AND WHY IT IS NOT test-match-lib.ps1. That suite proves the two MATCHER
  implementations agree with each other on the real corpus - which product a rule claims, decided the
  same way twice. It says nothing about whether the RULE IS RIGHT. A row can be matched identically by
  both implementations and still be wrong about the food, and nothing in this estate noticed when one
  was: `chicken-thighs` carried `exclude: \bdrumsticks?\b` while its own label read
  "Chicken Thighs / Drumsticks", so every real chicken drumstick was removed from the id that claimed
  to carry them, and the board answered `chicken drumsticks` with seven stores of THIGHS.

  It was found on 2026-08-24 by the Recipe Hunter's 6b run - a recipe wanting drumsticks - and not by
  any guard here, because no guard here asks "does this row's rule do what its label says".

  THE SHAPE. Each case is (commodity id, a REAL product name seen in a capture, expected verdict, why).
  Real names only: an invented product name proves the regex compiles, not that it matches the shelf.
  A case whose product no longer appears in any capture is still worth keeping - the rule outlives the
  week's assortment - but the name must have been real when the case was written.

  ADD A CASE whenever a commodity rule is fixed, on the same day, with the product that exposed it.
  That is the estate's standing rule: a fix whose founding case is not frozen next to it drifts back
  into the dead-guard pile.

  Exit 0 = every case holds. Exit 1 = at least one rule no longer does what its case says.
#>
param([string]$File = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $File = Join-Path $root 'commodities.json' }

if (-not (Test-Path $File)) {
  Write-Output ("test-commodity-rules: CANNOT RUN - no commodities file at {0}" -f $File)
  exit 2
}
$rows = Get-Content $File -Raw -Encoding utf8 | ConvertFrom-Json
$byId = @{}
foreach ($r in $rows) { if ($r.id) { $byId[[string]$r.id] = $r } }

function Get-RuleVerdict {
  <#
    The rule as the board applies it: an include must match, and then no exclude may. Returns
    'included', 'excluded:<pattern>', or 'no-include-match'. The three are DIFFERENT answers and a
    fixture that collapses them would pass while a row silently stopped matching anything at all.
  #>
  param($Row, [string]$Name)
  $inc = @($Row.include)
  $exc = @($Row.exclude)
  $hit = $false
  foreach ($p in $inc) { if ($p -and $Name -match $p) { $hit = $true; break } }
  if (-not $hit) { return 'no-include-match' }
  foreach ($p in $exc) { if ($p -and $Name -match $p) { return ('excluded:' + $p) } }
  return 'included'
}

# =====================================================================================================
# THE CASES. Product names are verbatim from grocery\out\captures\*.csv on the date noted.
# =====================================================================================================
$cases = @(
  # ---- chicken-thighs, label "Chicken Thighs / Drumsticks" (fixed 2026-08-24) --------------------
  # The founding case. All three drumstick names below were in the captures and priced BELOW the
  # cheapest thigh ($0.98/lb against $1.28), so the exclusion cost accuracy and money at once.
  @{ id='chicken-thighs'; name="Member's Mark Chicken Drumsticks, priced per pound"; expect='included'
     why='FOUNDING CASE: the id whose label says "Chicken Thighs / Drumsticks" must carry a drumstick' }
  @{ id='chicken-thighs'; name='fresh fresh chicken drumsticks family pack per lb'; expect='included'
     why='and an Aldi drumstick pack, which is the cheapest bone-in chicken on the board' }
  @{ id='chicken-thighs'; name='kirkwood fresh chicken drumsticks per lb'; expect='included'
     why='three real drumstick names, because a collection fixture takes at least three' }
  @{ id='chicken-thighs'; name="Member's Mark Chicken Thighs, Case, priced per pound"; expect='included'
     why='CLEAN TWIN the thighs the id has always carried are untouched by the fix' }
  @{ id='chicken-thighs'; name='Nestle Drumstick Cone Variety Pack, Frozen 16 ct.'; expect='no-include-match'
     why='the ice cream the old exclusion was aimed at. It never matched an include in the first place - it has no "chicken" in it - which is why removing that exclusion was free' }
  @{ id='chicken-thighs'; name='Tyson Chicken Nuggets'; expect='no-include-match'
     why='CLEAN TWIN a chicken product that is not a thigh or a drumstick still does not match' }

  # ---- rice (fixed 2026-08-24) ------------------------------------------------------------------
  # `rice` includes a bare \brice\b, so "cauliflower rice" mapped to it and priced as white rice at
  # 7 of 7 stores. Found while checking whether the Recipe Hunter could safely price the cheapest of
  # a set of ALTERNATIVES: it could not, while the matcher would substitute a different food.
  @{ id='rice'; name='Birds Eye Cauliflower Rice 12 oz'; expect='excluded'
     why='FOUNDING CASE: cauliflower rice is not rice and must not price as it' }
  @{ id='rice'; name='Green Giant Riced Cauliflower 10 oz'; expect='no-include-match'
     why='the other phrasing of the same food' }
  @{ id='rice'; name="Member's Mark Long Grain White Rice, 50 lbs."; expect='included'
     why='CLEAN TWIN actual rice is untouched by the exclusion' }
  @{ id='rice'; name='Great Value Long Grain Enriched Rice, 20 lb'; expect='included'
     why='CLEAN TWIN and so is the Walmart row' }
)

$bad = 0
$n = 0
foreach ($c in $cases) {
  $n++
  $row = $byId[$c.id]
  if (-not $row) {
    Write-Output ("  X     {0}: no such commodity id in {1}" -f $c.id, (Split-Path $File -Leaf))
    $bad++; continue
  }
  $got = Get-RuleVerdict $row $c.name
  # 'excluded' in a case means "excluded by SOME pattern"; which pattern is not the contract.
  $ok = if ($c.expect -eq 'excluded') { $got -like 'excluded:*' } else { $got -eq $c.expect }
  if ($ok) {
    if (-not $Quiet) { Write-Output ("  ok    {0,-16} {1,-52} {2}" -f $c.id, $c.name.Substring(0, [Math]::Min(52, $c.name.Length)), $c.expect) }
  } else {
    Write-Output ("  X     {0,-16} {1}" -f $c.id, $c.name)
    Write-Output ("          expected {0}, got {1}" -f $c.expect, $got)
    Write-Output ("          why this case exists: {0}" -f $c.why)
    $bad++
  }
}

Write-Output ''
if ($bad -gt 0) {
  Write-Output ("test-commodity-rules: FAIL - {0} of {1} case(s) no longer hold" -f $bad, $n)
  exit 1
}
Write-Output ("test-commodity-rules: PASS - {0} case(s) over {1} commodity row(s)" -f $n, (@($cases | ForEach-Object { $_.id } | Select-Object -Unique)).Count)
exit 0
