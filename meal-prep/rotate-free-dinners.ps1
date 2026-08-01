<#
  rotate-free-dinners.ps1 - Brad's free-dinner rotation (2026-07-25): the TOP 5 CHEAPEST dinners in each
  protein class (chicken / turkey / beef / pork - the catalog has no seafood dinners) are temporarily FREE;
  when a new board week re-ranks them, yesterday's free set reverts to members-only and the new set opens.

  CADENCE: weekly, keyed to recipe-costs.json week_of (which follows the Wednesday ad flip). This script is
  called DAILY from check-ad-cycles right after top5-weekly recomputes costs; it no-ops until week_of moves,
  so the rotation rides the same clock as every other weekly surface. -Force rotates now regardless.

  SAFETY RAILS:
    - Only slugs present in recipes-db are ever touched, and a post is only reverted to paid if THIS system
      set it free (it is in the state file). A hand-freed post can never be re-paywalled by the rotation.
    - Flips use the post's own updated_at (Ghost's optimistic concurrency), visibility only - content, tags
      and everything else ride along untouched.
    - State survives in free-rotation.json; recipes-db.visibility is kept in sync; the public list ships to
      public\free-dinners.json (worker-served, for site surfaces).
    - The Meal Prep hub gets a marker-managed section (SMP-FREEWEEK, same lexical single-html-card method
      as SMP-TOP5 - NEVER ?source=html, it strips scripts elsewhere on the page).

  Usage: -DryRun (compute + print, change nothing) | -Force (rotate even if week unchanged)
#>
param([switch]$DryRun, [switch]$Force)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$gout = Join-Path (Split-Path $root -Parent) 'grocery\out'
$pubDir = Join-Path (Split-Path $root -Parent) 'public'
$stateFile = Join-Path $root 'free-rotation.json'

$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() } else { throw 'Ghost admin key missing' }
$apiUrl = 'https://map-to-success.ghost.io'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path $PSScriptRoot 'lib\json-db-io.ps1')     # Set-RecipeVisibility: key-scoped patch (no whole-file round-trip)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

# ---------------------------------------------------------------- compute this week's target set
$costs = Get-Content (Join-Path $gout 'recipe-costs.json') -Raw | ConvertFrom-Json
# WEEK KEY: recipe-costs.week_of is the MONTHLY floor-baseline label, not the pricing week. The rotation
# rides the BOARD week - the newest comparison date, which flips with the Wednesday ad cycle.
$wkFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$boardWeek = [regex]::Match($wkFile.BaseName, '\d{4}-\d{2}-\d{2}').Value
$dbDoc = Get-Content (Join-Path $root 'recipes-db.json') -Raw | ConvertFrom-Json
$byProt = @{}
foreach ($r in $dbDoc.recipes) {
  if ($r.protein -in @('chicken','turkey','beef','pork')) {
    if (-not $byProt.ContainsKey($r.protein)) { $byProt[$r.protein] = @{} }
    $byProt[$r.protein][[string]$r.slug] = $r
  }
}
$costBySlug = @{}
foreach ($c in $costs.recipes) { $costBySlug[[string]$c.slug] = $c }

$target = New-Object System.Collections.Generic.List[object]
foreach ($prot in @('chicken','turkey','beef','pork')) {
  # DINNER filter (>500 cal) matches top5-weekly exactly - the hub box claims everything it shows is
  # free, which is only true if this selection and the box's tabs are computed identically.
  $ranked = @($byProt[$prot].Keys | Where-Object { $costBySlug.ContainsKey($_) -and [double]$costBySlug[$_].calories -gt 500 } |
    Sort-Object @{e={[double]$costBySlug[$_].per_serving}}, @{e={[double]$costBySlug[$_].week_cost}}, @{e={$_}} | Select-Object -First 5)
    # tie-break MUST match top5-weekly's "Sort-Object per_serving, week_cost, slug" exactly, or the free set
    # and the box's top-5 diverge on the 5th slot and the "every dinner in this box is free" line silently
    # drops. per_serving ties are common at 513+ recipes; some tie on week_cost TOO (gyudon vs the Peruvian
    # tallarines - true double-tie), so the final slug key is what makes both sides deterministic + identical.
  $rank = 0
  foreach ($slug in $ranked) {
    $rank++
    $target.Add([pscustomobject]@{ slug=$slug; protein=$prot; rank=$rank
      name=[string]$byProt[$prot][$slug].name; per_serving=[double]$costBySlug[$slug].per_serving })
  }
}
Write-Output ("rotation: board-week=" + $boardWeek + "  target free set = " + $target.Count + " recipe(s)")
foreach ($t in $target) { Write-Output ('  ' + $t.protein.PadRight(8) + '#' + $t.rank + '  $' + $t.per_serving.ToString('0.00') + '/srv  ' + $t.slug) }

$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }
$targetKey = (($target | ForEach-Object { $_.slug }) | Sort-Object) -join ','
$stateKey = if ($state) { ((@($state.free) | ForEach-Object { $_.slug }) | Sort-Object) -join ',' } else { '' }
if (-not $Force -and $state -and [string]$state.week_of -eq $boardWeek -and $targetKey -eq $stateKey) {
  Write-Output 'rotation: same week, same set - nothing to do'; exit 0
}
if ($DryRun) { Write-Output 'DRY RUN - no flips, no state change.'; exit 0 }

# ---------------------------------------------------------------- flip visibility in Ghost
function Set-PostVisibility([string]$slug, [string]$vis) {
  $jwt = New-GhostJWT
  $g = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/" -Headers @{Authorization="Ghost $jwt"}
  $p = $g.posts[0]
  if ([string]$p.visibility -eq $vis) { return 'already-' + $vis }
  $body = @{ posts = @(@{ visibility = $vis; updated_at = [string]$p.updated_at }) } | ConvertTo-Json -Depth 4
  $jwt = New-GhostJWT
  [void](Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/" -Method Put -Headers @{Authorization="Ghost $jwt";'Content-Type'='application/json'} -Body $body)
  return 'flipped-to-' + $vis
}

$targetSlugs = @($target | ForEach-Object { $_.slug })
$flips = 0; $errors = 0
$visChanges = @{}   # slug -> 'public'|'paid' for the rows the rotation flipped; patched key-scoped below

# revert: only slugs THIS system freed that are not in the new set
# THE STATE FILE RECORDS WHAT GHOST ACTUALLY DID, NOT WHAT WE INTENDED (fixed 2026-08-01).
# It used to be written as `free = $target` unconditionally, whether or not the flips succeeded. So a
# single failed PUT - a 409 on updated_at, a transient 5xx, a rate limit - left the post PAID while the
# state file swore it was free. Worse, it could never heal: the next run compares target-set to state-set,
# finds them identical, prints "same week, same set - nothing to do", and never retries. That is exactly
# how chicken-40-cloves-garlic sat listed-free and served-paid, with the hub badging a gold "Free this
# week" ribbon over a paywall until it was caught by hand.
# Now: only CONFIRMED-public slugs go into the state, so a failure makes the two sets differ and the very
# next run retries it. A failed REVERT likewise stays in the ledger, because a post we could not re-paywall
# is still one this rotation owns; dropping it would silently promote it to hand-freed and free forever.
$confirmedFree = New-Object System.Collections.Generic.List[object]
$stillOwned    = New-Object System.Collections.Generic.List[object]
if ($state) {
  foreach ($old in @($state.free)) {
    if ($targetSlugs -notcontains [string]$old.slug) {
      try {
        $res = Set-PostVisibility ([string]$old.slug) 'paid'
        Write-Output ('  REVERT ' + $old.slug + ' -> ' + $res); $flips++
        $visChanges[[string]$old.slug] = 'paid'
      } catch {
        Write-Output ('  REVERT FAILED ' + $old.slug + ': ' + $_.Exception.Message); $errors++
        [void]$stillOwned.Add($old)   # could not re-paywall it: keep owning it so a later run can
      }
      Start-Sleep -Milliseconds 300
    }
  }
}
# free the new set
foreach ($t in $target) {
  try {
    $res = Set-PostVisibility ($t.slug) 'public'
    Write-Output ('  FREE   ' + $t.slug + ' -> ' + $res); $flips++
    $visChanges[[string]$t.slug] = 'public'
    [void]$confirmedFree.Add($t)
  } catch { Write-Output ('  FREE FAILED ' + $t.slug + ': ' + $_.Exception.Message); $errors++ }
  Start-Sleep -Milliseconds 300
}

# ---------------------------------------------------------------- persist state + db + public list
$stateFree = New-Object System.Collections.Generic.List[object]
foreach ($x in $confirmedFree) { [void]$stateFree.Add($x) }
foreach ($x in $stillOwned)    { [void]$stateFree.Add($x) }
$stateFree = $stateFree.ToArray()
[pscustomobject]@{
  readme = 'State of the free-dinner rotation (rotate-free-dinners.ps1). Only slugs listed here are ever reverted to paid by the rotation.'
  week_of = $boardWeek; rotated_at = (Get-Date).ToString('s')
  # PS 5.1 TRAP: @($aGenericList) inside a [pscustomobject] cast throws "Argument types do not match".
  # Build one list and hand the cast a real array. Same family as the @(pipeline|ConvertFrom-Json) trap.
  free = $stateFree
} | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8
if ($visChanges.Count) { $nvis = Set-RecipeVisibility -DbPath (Join-Path $root 'recipes-db.json') -Map $visChanges; Write-Output ("  recipes-db: patched $nvis visibility field(s) key-scoped (no whole-file round-trip)") }
[pscustomobject]@{
  week_of = $boardWeek; updated = (Get-Date).ToString('s')
  note = 'This week free because they are the cheapest dinners per protein on the live Omaha board. They revert to members-only when prices re-rank.'
  free = $target
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $pubDir 'free-dinners.json') -Encoding UTF8
Write-Output ("rotation: $flips flip(s), $errors error(s); state + recipes-db + public/free-dinners.json written")
if ($errors -gt 0) {
  # say it plainly and exit non-zero: a partially-applied rotation means the site is promising something
  # Ghost is not serving, and the state now differs from the target so the next run WILL retry.
  Write-Output ("rotation INCOMPLETE: $errors flip(s) failed. The state file records only what Ghost confirmed, so the next run retries them. Until then the hub badge check (build-hub-grid verifies visibility per slug) will simply not badge them.")
  exit 1
}

# HUB SECTION REMOVED (Brad, 2026-07-25 - he preferred the original SMP-TOP5 box, which top5-weekly
# renders; the green SMP-FREEWEEK grid was deleted from the live page the same day). The rotation is
# DISPLAY-SILENT: flips, state, recipes-db sync and public\free-dinners.json all still happen above.
# If a free-week surface is ever wanted again, build it from free-dinners.json - do not re-add a second
# hub box next to SMP-TOP5.
if ($errors -gt 0) { exit 1 }
