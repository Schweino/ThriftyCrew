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
param([switch]$DryRun, [switch]$Force, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
$gout = Join-Path (Split-Path $root -Parent) 'grocery\out'
$pubDir = Join-Path (Split-Path $root -Parent) 'public'
$stateFile = Join-Path $root 'free-rotation.json'

# THE KEY IS RESOLVED ONLY FOR A REAL RUN. -SelfTest exercises the pure decision functions below and
# must work on a machine with no Ghost credentials at all, or the gate that guards this script can
# only run where the script could also publish - which is the wrong place to need a secret.
$adminKey = if ($SelfTest) { '' } elseif ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() } else { throw 'Ghost admin key missing' }
$apiUrl = 'https://map-to-success.ghost.io'
. (Join-Path $PSScriptRoot '..\lib\ghost-lib.ps1')   # 2026-07-26: single Ghost helper (was one of 50+ inline copies)
. (Join-Path $PSScriptRoot 'lib\json-db-io.ps1')     # Set-RecipeVisibility: key-scoped patch (no whole-file round-trip)
function New-GhostJWT { Get-GhostJWT -Key $adminKey }

# ---------------------------------------------------------------- SELF-TEST (must exit BEFORE any Ghost work)
# THE SWITCH EXISTED AND DID NOTHING (found 2026-08-29). The comment above promised that -SelfTest
# "exercises the pure decision functions below", but no body was ever written, so the flag fell straight
# through into the PRODUCTION path: run it and it computes the live target set and walks on toward
# Set-PostVisibility with $adminKey deliberately blanked. A switch that runs the real rotation while
# claiming to test it is worse than no switch, because the name is what stops someone being careful.
# It is not in run-gates' roster either, so nothing has ever executed it.
# These are source assertions rather than behavioural ones on purpose: the functions that matter here
# talk to Ghost, and a self-test that needs a credential can only run where it could also publish.
if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Write-Output ('  PASS  ' + $msg); $script:p++ } else { Write-Output ('  FAIL  ' + $msg); $script:f++ } }
  Write-Output 'rotate-free-dinners -SelfTest'
  $src = Get-Content $PSCommandPath -Raw
  $spv = [regex]::Match($src, '(?ms)^function\s+Set-PostVisibility\s*\(.*?^\}')
  T ($spv.Success) 'Set-PostVisibility is present'
  if ($spv.Success) {
    # THE FOUNDING BUG OF 2026-08-29: the PUT response was discarded and success returned on the next
    # line, so an unconfirmed revert counted as confirmed and stranded the post public forever.
    T ($spv.Value -match "Method Put") 'it issues the visibility PUT'
    T ($spv.Value -match '(?s)Method Put.*fields=id,visibility') 'it RE-READS the post after the PUT - "did not throw" is not "Ghost took it"'
    T ($spv.Value -match '(?s)Method Put.*if \(\$now -ne \$vis\) \{ throw') 'and it THROWS when Ghost still reports the old visibility'
    $putIdx = $spv.Value.IndexOf('Method Put')
    $retIdx = $spv.Value.IndexOf("return 'flipped-to-'")
    $verIdx = $spv.Value.IndexOf('if ($now -ne $vis)')
    T ($verIdx -gt $putIdx -and $retIdx -gt $verIdx) 'the verification sits BETWEEN the PUT and the success return, not after it'
  }
  # The throw is only useful because the revert caller already routes a failure to $stillOwned, which
  # keeps ownership so a later run retries. Assert that handling is still there - if it is ever removed,
  # the throw silently becomes a crash instead of a retry.
  T ($src -match '(?s)REVERT FAILED.*stillOwned\.Add') 'a failed REVERT still keeps ownership so a later run retries it'
  T ($src -match 'Only slugs listed here are ever reverted to paid') "the state file still declares the ownership rule the throw protects"
  # A FLIP CHANGES TWO BAKED THINGS, NOT ONE. The hub's FREE badges (wired 2026-08-01) and the posts'
  # paywall structured data (wired 2026-08-31) are both stamped at build time and both go stale the
  # moment visibility moves. Each is one line away from being dropped in a refactor and neither failure
  # is visible on the page, so assert both call sites rather than trusting them.
  #
  # THE NEEDLES ARE BUILT BY CONCATENATION ON PURPOSE. Written whole, each pattern appears in this very
  # line and in the comments above, so `$src -match` finds ITSELF and the test passes no matter what the
  # script does. That was the first draft, and deleting the entire resync call left it green - a test
  # that cannot fail is worse than no test, because it is counted. Split needles cannot self-match.
  $nSync = "-File (Join-Path `$root 'pipeline\sync-paywall" + "-schema.ps1')"
  $nHub  = "-File (Join-Path `$root 'build-hub" + "-grid.ps1') -Publish"
  $nExit = 'throw "sync-paywall' + '-schema exited'
  T ($src.Contains($nSync)) 'a flip resyncs the posts paywall structured data'
  T ($src.Contains($nHub))  'a flip republishes the hub so its baked FREE badges match'
  T ($src.Contains($nExit)) 'and it checks that resync exit code rather than assuming it worked'
  if ($f -gt 0) { Write-Output ("rotate-free-dinners SELFTEST: $f FAILED"); exit 2 }
  Write-Output ("rotate-free-dinners SELFTEST: all $p passed"); exit 0
}

# ---------------------------------------------------------------- compute this week's target set
$costs = Read-JsonFile (Join-Path $gout 'recipe-costs.json')
# WEEK KEY: recipe-costs.week_of is the MONTHLY floor-baseline label, not the pricing week. The rotation
# rides the BOARD week - the newest comparison date, which flips with the Wednesday ad cycle.
$wkFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$boardWeek = [regex]::Match($wkFile.BaseName, '\d{4}-\d{2}-\d{2}').Value
$dbDoc = Read-JsonFile (Join-Path $root 'recipes-db.json')
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

$state = if (Test-Path $stateFile) { Read-JsonFile $stateFile } else { $null }
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
  # RE-READ, BECAUSE "DID NOT THROW" IS NOT "GHOST TOOK IT" (2026-08-29).
  # This used to discard the PUT response and return success on the very next line. That made an
  # UNCONFIRMED revert count as a confirmed one: the slug dropped out of the ledger, recipes-db was
  # patched to 'paid', and this file's own rule - "Only slugs listed here are ever reverted to paid by
  # the rotation" - then stranded it PUBLIC forever with the database claiming paid. Nothing could heal
  # it: rotate-free-dinners refuses by design to re-paywall a post it does not own, and publish.ps1
  # PRESERVES live visibility on update, so a republish carried the wrong value forward instead.
  # Measured 2026-08-29: 22 live recipes were serving their full PAID content - ingredients, all steps,
  # cost, scaler - to anonymous visitors. 11 had free-list history, and 3 of those were freed AFTER the
  # 2026-08-01 guards, two of them in a single run, which is the per-POST signature this produces.
  # THE COMMENT ABOVE THIS FUNCTION SAID THE STATE FILE RECORDS WHAT GHOST ACTUALLY DID. It did not - it
  # recorded what the API call did not throw on. That fix moved the check from intent to CALL; this moves
  # it to OUTCOME, which is where it had to be all along.
  # THROWING IS THE CORRECT INTEGRATION, not an inconvenience: the revert caller already catches and routes
  # the slug to $stillOwned, which keeps ownership so a later run retries it. That handling was written on
  # 2026-08-01 and has been correct ever since; it was simply never told when a flip failed.
  $after = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/$($p.id)/?fields=id,visibility" -Headers @{Authorization="Ghost " + (New-GhostJWT)}
  $now = [string]$after.posts[0].visibility
  if ($now -ne $vis) { throw ("Ghost did not take the visibility change for '" + $slug + "': asked for '" + $vis + "', it still reports '" + $now + "'") }
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
  # CONFIRMED truth, not intent (same rule as the state file, 2026-08-01). The hub's client-side badge
  # refresh is remove-only and trusts this feed, so publishing $target could keep a gold FREE badge on a
  # recipe whose flip FAILED and is still paid - the exact ribbon-over-a-paywall sin. Ghost-confirmed only.
  free = $stateFree
} | ConvertTo-Json -Depth 4 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $pubDir 'free-dinners.json'), $_, (New-Object Text.UTF8Encoding($false))) }   # BOM-less: PS 5.1 ConvertFrom-Json chokes on our own BOM (L7)
Write-Output ("rotation: $flips flip(s), $errors error(s); state + recipes-db + public/free-dinners.json written")

# REPUBLISH THE HUB WHEN THE SET CHANGED (2026-08-01). The hub bakes FREE badges into static HTML at
# build time, and until now NOTHING rebuilt it when the rotation flipped - so every flip left the page
# one rotation stale (found live: slow-cooker-kalua-pork-bowls still badged hours after rotating out;
# the client-side remove-only refresh hid it from JS visitors, but no-JS visitors and search caches saw
# a FREE badge on a paid post). The build verifies visibility per slug against Ghost, so this republish
# is also the badge truth check. Only on a real change, so quiet days stay quiet.
# AND RESYNC THE PAYWALL STRUCTURED DATA (2026-08-31). Same bug class as the hub badges above, one
# layer down: build-card2 bakes an isAccessibleForFree claim into each post's codeinjection_head, and
# this script flips visibility ONLY - so a card built as paid kept telling Google its content was
# gated after it was freed. Found live: all 20 recipes in the rotation were marked paywalled while
# serving their content to everyone, which is the whole top of the funnel asking not to be read.
# The sync trusts Ghost's visibility, is idempotent, and leaves the claim in place whenever it cannot
# be sure - understating access is the safe direction, overstating it is the shape of cloaking.
if ($flips -gt 0 -and $errors -eq 0) {
  Write-Output 'set changed - resyncing the paywall structured data to the new visibilities'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'pipeline\sync-paywall-schema.ps1') *>&1 |
      Select-Object -Last 3 | ForEach-Object { Write-Output ("  paywall-schema: " + $_) }
    if ($LASTEXITCODE -ne 0) { throw "sync-paywall-schema exited $LASTEXITCODE" }
  } catch {
    Write-Output ("rotation WARNING: the paywall schema resync failed (" + $_.Exception.Message + ") - the freed recipes still tell Google they are gated until it runs. Re-run pipeline\sync-paywall-schema.ps1.")
  }
}

if ($flips -gt 0 -and $errors -eq 0) {
  Write-Output 'set changed - republishing the hub so its baked badges match the new rotation'
  try {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-hub-grid.ps1') -Publish *>&1 |
      Select-Object -Last 2 | ForEach-Object { Write-Output ("  hub: " + $_) }
    if ($LASTEXITCODE -ne 0) { throw "build-hub-grid exited $LASTEXITCODE" }
  } catch {
    Write-Output ("rotation INCOMPLETE: flips applied but the hub republish failed (" + $_.Exception.Message + ") - the hub's baked FREE badges are one rotation stale until it publishes. Re-run build-hub-grid.ps1 -Publish.")
    exit 1
  }
}
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
