# test-factor-grade.ps1 - hermetic self-test for factor-grade-lib.ps1: which cells guard 4 grades.
# Queue 2026-09-28-a5268a, Brad's ruling 2026-09-29: a Sam's rollback (typed sale, ad_basis ttl, source_ad
# "everyday club price (...)") is graded against its link; a real weekly-ad sale stays exempt.
# Fixture rows are FROZEN copies of real cells on comparison-2026-09-28.json and their product-urls links. Never
# regenerate them from a live board. Each graded case also runs the per-unit arithmetic guard 4 uses
# (pu-lib Get-LinkPerUnit) and its own bar (ratio >= 1.5 or <= 0.67), so a MUST FIRE proves the cell would be
# reported, not merely that the predicate said yes.
# SCOPE OF A CLEAN REPORT: SOUND for the predicate over these frozen shapes; UNSOUND for guard 4's loop itself,
# which grocery\test-guards.ps1 case "factor mismatch (Sam's rollback)" drives against the real guard.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'factor-grade-lib.ps1')

$script:n = 0; $script:bad = 0
function Assert-Case([string]$What, [scriptblock]$Body) {
  $script:n++
  try {
    $res = & $Body
    if ($res -eq $true) { Write-Output ('  ok    ' + $What) }
    else { $script:bad++; Write-Output ('  FAIL  ' + $What + ' -> ' + [string]$res) }
  } catch { $script:bad++; Write-Output ('  FAIL  ' + $What + ' -> threw: ' + $_.Exception.Message) }
}
function Get-FixtureRatio($Cell, $Link, [string]$Unit) {
  $sp = 0.0; [void][double]::TryParse((([string]$Link.price) -replace '[^0-9.]',''), [ref]$sp)
  $lpu = Get-LinkPerUnit -size ([string]$Link.size) -unit $Unit -price $sp -name ([string]$Link.name)
  if ($null -eq $lpu -or [double]$Cell.per_unit -le 0) { return $null }
  return ($lpu / [double]$Cell.per_unit)
}
function Test-FactorBar($r) { return ($null -ne $r -and ($r -ge 1.5 -or $r -le 0.67)) }

# batteries / Sam's Club, a rollback on the 2026-09-28 board (frozen)
$rollback = '{"store":"Sam''s Club","per_unit":0.3746,"unit":"each","type":"sale","ad":"$17.98","size":"48 ct","basis":"per-48-pack","source_ad":"everyday club price (Omaha Sam''s Club)","ad_from":"2026-09-21","ad_to":"2026-10-21","ad_basis":"ttl","as_of":"2026-09-21"}' | ConvertFrom-Json
$rollbackLink = '{"name":"Member''s Mark AA Alkaline Batteries, 48 pk.","price":"$17.98","size":"48 ct"}' | ConvertFrom-Json
# the founding shape: the link records half the pack the board priced (24 ct), a 2x pack-factor error
$rollbackLinkBad = '{"name":"Member''s Mark AA Alkaline Batteries","price":"$17.98","size":"24 ct"}' | ConvertFrom-Json
# cooking-spray / Hy-Vee, a printed weekly-ad sale (8 oz in the ad) whose everyday link is the 5 oz can (frozen)
$weeklyAd = '{"store":"Hy-Vee","per_unit":0.4362,"unit":"oz","type":"sale","ad":"Hy-Vee cooking spray, 8 oz., $3.49","size":"","basis":"size 8 oz","source_ad":"Weekly Ad","ad_from":"2026-09-28","ad_to":"2026-10-04","ad_basis":""}' | ConvertFrom-Json
$weeklyAdLink = '{"name":"Hy-Vee Butter Flavored No Stick Cooking Spray 5 oz","price":3.48,"size":"5 oz"}' | ConvertFrom-Json

Assert-Case 'MUST FIRE  a Sam''s rollback whose link records half its pack is GRADED and trips the 1.5x bar' {
  $g = Test-TcFactorGuardGrades $rollback; $r = Get-FixtureRatio $rollback $rollbackLinkBad 'each'
  if ($g -and (Test-FactorBar $r)) { $true } else { "graded=$g ratio=$r" }
}
Assert-Case 'MUST NOT FIRE  the same Sam''s rollback against its true 48 ct link is graded and agrees' {
  $g = Test-TcFactorGuardGrades $rollback; $r = Get-FixtureRatio $rollback $rollbackLink 'each'
  if ($g -and -not (Test-FactorBar $r) -and [math]::Abs($r - 1) -le 0.02) { $true } else { "graded=$g ratio=$r" }
}
Assert-Case 'CLEAN TWIN  a Hy-Vee weekly-ad sale whose link is a different pack (a real 1.6x) stays EXEMPT' {
  $g = Test-TcFactorGuardGrades $weeklyAd; $r = Get-FixtureRatio $weeklyAd $weeklyAdLink 'oz'
  if (-not $g -and (Test-FactorBar $r)) { $true } else { "graded=$g ratio=$r (the twin must be exempt AND a real mismatch, or it proves nothing)" }
}
Assert-Case 'CLEAN TWIN  an EVERYDAY cell is still graded' {
  $c = '{"store":"Hy-Vee","type":"everyday","per_unit":0.69}' | ConvertFrom-Json
  if (Test-TcFactorGuardGrades $c) { $true } else { 'everyday cell not graded' }
}
Assert-Case 'MUST NOT FIRE  a Sam''s sale with a printed-ad basis (ad_basis ad) stays exempt' {
  $c = $rollback.PSObject.Copy(); $c.ad_basis = 'ad'
  if (-not (Test-TcFactorGuardGrades $c)) { $true } else { 'graded' }
}
Assert-Case 'MUST NOT FIRE  a Sam''s sale whose source_ad is not the everyday club price stays exempt' {
  $c = $rollback.PSObject.Copy(); $c.source_ad = 'Sam''s Club Instant Savings book'
  if (-not (Test-TcFactorGuardGrades $c)) { $true } else { 'graded' }
}
Assert-Case 'MUST NOT FIRE  a Sam''s sale with NO ad_basis field is exempt (absent is a non-match)' {
  $c = $rollback.PSObject.Copy(); $c.PSObject.Properties.Remove('ad_basis')
  if (-not (Test-TcFactorGuardGrades $c)) { $true } else { 'graded' }
}
Assert-Case 'MUST NOT FIRE  a Fareway ttl site sale is out of the ruling''s scope and stays exempt' {
  $c = '{"store":"Fareway","type":"sale","ad_basis":"ttl","source_ad":"shop.fareway.com","per_unit":1}' | ConvertFrom-Json
  if (-not (Test-TcFactorGuardGrades $c)) { $true } else { 'graded' }
}
Assert-Case 'MUST NOT FIRE  a null cell is not graded' {
  if (-not (Test-TcFactorGuardGrades $null)) { $true } else { 'graded' }
}

$expected = 9
if ($script:n -ne $expected) { $script:bad++; Write-Output ("  FAIL  ran $($script:n) cases, expected $expected") }
if ($script:bad -eq 0) { Write-Output ("test-factor-grade: $($script:n) of $expected cases ok - self-test pass"); exit 0 }
Write-Output ("test-factor-grade: $($script:bad) of $($script:n) cases failed - self-test FAIL"); exit 1
