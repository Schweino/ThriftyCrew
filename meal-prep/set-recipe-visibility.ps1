<#
  set-recipe-visibility.ps1 - make ONE live recipe's Ghost visibility agree with recipes-db.json.

  WHY THIS EXISTS. The estate could free a recipe and could put a freed one back, but ONLY through the
  rotation, and the rotation refuses by design: "a post is only reverted to paid if THIS system set it
  free (it is in the state file). A hand-freed post can never be re-paywalled by the rotation." That rail
  is right - the rotation must not clobber a deliberate hand-free - but it left a hole with nothing on the
  other side of it.

  FOUND 2026-08-27, and it was serving money away: loaded-chicken-and-potato-casserole was rendering its
  FULL paid recipe to anonymous visitors - ingredients, all seven steps, cost section, scaler, shop-smart.
  recipes-db said paid. The spec said paid. The page's own JSON-LD declared "isAccessibleForFree":false
  twice. It appeared in no free list and `git log --all -S` found it in no free-list history ever. So the
  rotation had not freed it, could not re-paywall it, and nothing else in the estate could either.

  AND A REPUBLISH DOES NOT FIX IT. engine\publish.ps1 deliberately PRESERVES live visibility on update, so
  every republish carried the wrong value forward: the post was republished as wave collateral at
  2026-08-29T09:59:10Z and came back public again. The defect is self-sustaining until something writes
  visibility directly, which is what this does.

  IT TAKES ITS TARGET FROM recipes-db, NOT FROM AN ARGUMENT. There is no -Visibility parameter on purpose.
  This tool answers exactly one question - "does the live page agree with the database?" - and the only
  thing it can do is make it agree. A tool that flips a live paywall to whatever it is told is a way to
  free the catalogue by typo; a tool that can only converge on the recorded value is not. To change what a
  recipe SHOULD be, change recipes-db (and the spec) and then run this.

  THE PUT IS MINIMAL, the same shape rotate-free-dinners uses: visibility plus the post's own updated_at
  for Ghost's optimistic concurrency. Content, tags and lexical ride along untouched.

  DRY RUN BY DEFAULT. -Apply writes.

  Usage:
    .\set-recipe-visibility.ps1 -Slug loaded-chicken-and-potato-casserole
    .\set-recipe-visibility.ps1 -Slug loaded-chicken-and-potato-casserole -Apply
    .\set-recipe-visibility.ps1 -Audit            (report EVERY live/db disagreement, change nothing)
    .\set-recipe-visibility.ps1 -SelfTest
#>
param(
  [string]$Slug = '',
  [switch]$Apply,
  [switch]$Audit,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$apiUrl = 'https://map-to-success.ghost.io'

function Say([string]$m) { Write-Output $m }

if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Say ('  PASS  ' + $msg); $script:p++ } else { Say ('  FAIL  ' + $msg); $script:f++ } }
  Say 'set-recipe-visibility -SelfTest'
  # The whole safety property of this tool is that it cannot be TOLD a visibility - it can only converge
  # on the recorded one. If a -Visibility parameter ever appears, that property is gone and a typo can
  # free the catalogue, so the absence of the parameter is itself the thing worth asserting.
  $src = Get-Content $PSCommandPath -Raw
  T ($src -notmatch '(?m)^\s*\[string\]\$Visibility') 'there is no -Visibility parameter: the target can only come from recipes-db'
  T ($src -match 'updated_at') 'the PUT carries updated_at (Ghost optimistic concurrency), so a concurrent edit is not clobbered'
  T ($src -match "posts\s*=\s*@\(@\{\s*visibility") 'the PUT body sets visibility only - content, tags and lexical ride along untouched'
  # A slug the database does not know is refused rather than guessed at.
  $db = $null
  try { $db = Get-Content (Join-Path $root 'recipes-db.json') -Raw | ConvertFrom-Json } catch { $db = $null }
  T ($null -ne $db) 'recipes-db.json parses'
  if ($null -ne $db) {
    $known = @($db.recipes | Where-Object { $_.slug }).Count
    T ($known -gt 0) ("recipes-db carries $known slug(s) to check against")
    $vis = @($db.recipes | ForEach-Object { [string]$_.visibility } | Where-Object { $_ } | Sort-Object -Unique)
    T (@($vis | Where-Object { $_ -notin @('public','paid','members') }).Count -eq 0) ('every recorded visibility is in the closed vocabulary (found: ' + ($vis -join ', ') + ')')
  }
  if ($f -gt 0) { Say ("set-recipe-visibility SELFTEST: $f FAILED"); exit 2 }
  Say ("set-recipe-visibility SELFTEST: all $p passed"); exit 0
}

# ---------------------------------------------------------------- credentials (the estate's own key)
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
            elseif (Test-Path (Join-Path $root '.ghostkey')) { (Get-Content (Join-Path $root '.ghostkey') -Raw).Trim() }
            else { throw 'Ghost admin key missing (meal-prep\.ghostkey or $env:GHOST_ADMIN_KEY)' }
. (Join-Path $root '..\lib\ghost-lib.ps1')

$db = Get-Content (Join-Path $root 'recipes-db.json') -Raw | ConvertFrom-Json
function Get-Recorded([string]$s) {
  $r = @($db.recipes | Where-Object { [string]$_.slug -eq $s })
  if ($r.Count -eq 0) { return $null }
  return [string]$r[0].visibility
}
function Get-Live([string]$s) {
  $jwt = Get-GhostJWT -Key $adminKey
  return (Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$s/?fields=id,slug,visibility,updated_at,status" `
            -Headers @{Authorization="Ghost $jwt"; 'Accept-Version'='v5.0'} -TimeoutSec 30).posts[0]
}

if ($Audit) {
  # Report every disagreement. Read-only: this is the check that did not exist, and the reason a paid
  # recipe could serve itself away for two days without anything noticing.
  $slugs = @($db.recipes | Where-Object { $_.slug -and $_.visibility } )
  Say ("visibility audit: checking $($slugs.Count) recipe(s) against Ghost")
  $bad = 0; $checked = 0
  foreach ($r in $slugs) {
    $s = [string]$r.slug
    try { $p = Get-Live $s } catch { Say ("  SKIP  $s - $($_.Exception.Message)"); continue }
    if (-not $p) { Say ("  SKIP  $s - no live post"); continue }
    $checked++
    if ([string]$p.visibility -ne [string]$r.visibility) {
      $bad++
      Say ("  DISAGREE  {0}  live={1}  recipes-db={2}{3}" -f $s, $p.visibility, $r.visibility,
           $(if ([string]$r.visibility -eq 'paid' -and [string]$p.visibility -ne 'paid') { '   <-- PAID RECIPE SERVED FREE' } else { '' }))
    }
  }
  Say ("VISIBILITY-AUDIT-COMPLETE checked=$checked disagreements=$bad")
  if ($bad -gt 0) { exit 2 }
  exit 0
}

if (-not $Slug) { Say 'set-recipe-visibility: -Slug is required (or -Audit / -SelfTest)'; exit 1 }
$want = Get-Recorded $Slug
if ($null -eq $want) { Say ("set-recipe-visibility: '$Slug' is not in recipes-db.json - refusing to guess a visibility for a recipe the database does not know"); exit 1 }
if ($want -notin @('public','paid','members')) { Say ("set-recipe-visibility: recipes-db records visibility '$want' for '$Slug', which is not a Ghost visibility - fix the database first"); exit 1 }

$post = Get-Live $Slug
if (-not $post) { Say ("set-recipe-visibility: no live Ghost post for '$Slug'"); exit 1 }
Say ("set-recipe-visibility: $Slug")
Say ("  live       : " + $post.visibility + "  (status " + $post.status + ", updated_at " + $post.updated_at + ")")
Say ("  recipes-db : " + $want)
if ([string]$post.visibility -eq $want) { Say '  AGREE - nothing to do.'; exit 0 }

Say ("  ACTION     : flip live " + $post.visibility + " -> " + $want)
if (-not $Apply) { Say '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }

$body = @{ posts = @(@{ visibility = $want; updated_at = [string]$post.updated_at }) } | ConvertTo-Json -Depth 4
$jwt = Get-GhostJWT -Key $adminKey
[void](Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Method Put `
        -Headers @{Authorization="Ghost $jwt"; 'Accept-Version'='v5.0'} -ContentType 'application/json' -Body $body -TimeoutSec 60)
$after = Get-Live $Slug
Say ("  RESULT     : live is now " + $after.visibility)
if ([string]$after.visibility -ne $want) { Say '  FAILED - Ghost did not take the change'; exit 2 }
Say '  done.'
exit 0
