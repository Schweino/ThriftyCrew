<#
  held-state.ps1 - which recipes are HELD on purpose, read ONE way (2026-09-22, queue 2026-09-19-2c96d8).

  WHY ONE FUNCTION. A recipe deliberately taken down (db\held-recipes.json, written by hold-recipe.ps1 and refused
  by engine\publish.ps1) is a THIRD state beside "agrees" and "drifted". cost-recipes learned it on 2026-09-21
  (queue 2026-09-20-6c14f6) with its own inline read; the next reader of the same files, audit-db-agreement, did
  not, and paged "recipe db drift" ten times about six recipes Brad is ruling on (Q1-2026-09-20-partial-cost), each
  time telling a person to "fix the lagging side" of something that was not broken. Two copies of one read is how
  the second scorer rediscovers the bug (F4 and F1 in design/RCA-holistic-2026-09-22.md), so every meal-prep scorer
  that must tell held from drifted reads it here.

  AN UNREADABLE FILE IS NOT AN EMPTY ONE. ok=$false and NO slug is held, so every finding still scores (the loud
  direction) and the caller says so. An absent file is a legitimate empty hold list: ok=$true, nothing held.
  Functions only; dot-source it.
#>
$heldStateRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # meal-prep\lib -> meal-prep -> repo root
. (Join-Path $heldStateRepoRoot 'lib\json-io.ps1')   # Read-JsonFile: a BOM-less read is cp1252 otherwise

function Get-HeldRecipeSet {
  <# .SYNOPSIS Held slugs from <DbDir>\held-recipes.json: ok, slugs (slug -> reason), why. Never throws. #>
  param([string]$DbDir)
  $r = [pscustomobject]@{ ok = $true; slugs = @{}; why = '' }
  $p = Join-Path $DbDir 'held-recipes.json'
  if (-not (Test-Path -LiteralPath $p)) { $r.why = 'no held-recipes.json: nothing is held'; return $r }
  try {
    $j = Read-JsonFile $p
    if ($null -eq $j -or -not $j.PSObject.Properties['held']) { throw 'no held array' }
    foreach ($h in @($j.held)) {
      if (-not $h) { continue }
      $s = [string]$h.slug
      if (-not $s) { continue }
      $why = ''
      if ($h.PSObject.Properties['reason']) { $why = [string]$h.reason }
      $r.slugs[$s] = $why
    }
  } catch {
    $r.ok = $false; $r.slugs = @{}
    $r.why = ('held-recipes.json could not be read (' + $_.Exception.Message + '), so NO recipe is treated as held and every finding scores')
  }
  return $r
}
