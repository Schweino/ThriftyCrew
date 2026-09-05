<#
  audit-paid-not-public.ps1 - is any recipe the estate believes is PAID actually being served FREE?

  WHY THIS EXISTS (2026-08-29). 22 live recipes were serving their full paid content - ingredients,
  every step, the cost section, the scaler - to anonymous visitors. They were found by a post-publish
  review of an unrelated wave, which is to say: by accident, after an unknown number of days.

  THE DIRECTION NOBODY WATCHED. The estate already verifies visibility, in build-hub-grid.ps1 (~line
  125): for each slug LISTED in free-rotation.json it asks Ghost whether the post is public, and warns
  when a listed-free post is not free, because that would badge a gold "Free this week" ribbon over a
  paywall. That is the cosmetic direction. Nobody ever asked the revenue one - "is a post we are NOT
  giving away being given away anyway?" - so a leak could only ever be found by somebody reading a page.

  WHAT IT COMPARES. recipes-db.json's `visibility` (what the estate believes it sells) against Ghost's
  own `visibility` (what a reader actually gets), for every published recipe. Two verdicts:
    LEAK        db says paid, Ghost serves public. Revenue is walking out; this is the founding class.
    BADGE-SKEW  db says public, Ghost serves paid. Cosmetic, and build-hub-grid already covers the
                free-rotation subset - reported here for completeness because the two files disagree
                either way, but it does not fail the gate on its own.

  IT IS A DETECTOR, NOT A REPAIR, and deliberately so. Flipping visibility is rotate-free-dinners'
  job and it owns the ledger that decides which posts it may touch; a second writer would be the
  two-copies-of-a-rule shape. This says which slugs and in which direction, and stops.

  KNOWN CAUSES it will catch, none of which the rotation's own guards cover:
    - a revert whose PUT did not land (fixed 2026-08-29, but this is the watcher that proves it);
    - free-rotation.json empty or whitespace, which yields $state = $null with NO error even under
      EAP=Stop, silently skipping the entire revert block and stranding the whole ledger;
    - a post freed by hand in Ghost admin, which the rotation refuses to re-paywall by design.

  Usage:
    .\audit-paid-not-public.ps1            check every published recipe against Ghost
    .\audit-paid-not-public.ps1 -Alert     ...and mail on findings (daily-chain mode)
    .\audit-paid-not-public.ps1 -Slugs a,b check only these
    .\audit-paid-not-public.ps1 -SelfTest
  Exit 0 clean, 1 LEAK found, 2 self-test failure, 3 could-not-evaluate (no key / Ghost unreachable).
#>
[CmdletBinding()]
param(
  [string[]]$Slugs = @(),
  [switch]$Alert,
  [switch]$SelfTest,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')

# ---------------------------------------------------------------------------------------------------
# THE PREDICATE, pure so the fixtures drive the same code the sweep runs. Ghost stays outside it.
#   $Believed : slug -> the visibility recipes-db records
#   $Actual   : slug -> the visibility Ghost reports ($null when it could not be read)
# ---------------------------------------------------------------------------------------------------
function Get-VisibilityFindings {
  param([hashtable]$Believed, [hashtable]$Actual)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($slug in ($Believed.Keys | Sort-Object)) {
    $want = [string]$Believed[$slug]
    if (-not $Actual.ContainsKey($slug)) { continue }        # unreadable is reported by the caller, not here
    $got = [string]$Actual[$slug]
    if (-not $got) { continue }
    if ($want -eq $got) { continue }
    # PAID covers Ghost's 'members' and 'paid' alike: both gate the content, and only 'public' gives it
    # away. Treating anything-not-public as equivalent is what keeps a members-only post off the leak
    # list, where it would be noise that trains the reader to skip the real ones.
    $wantOpen = ($want -eq 'public')
    $gotOpen  = ($got  -eq 'public')
    if ($wantOpen -eq $gotOpen) { continue }
    $out.Add([pscustomobject]@{
      slug    = $slug
      verdict = $(if ($gotOpen) { 'LEAK' } else { 'BADGE-SKEW' })
      believed = $want
      actual   = $got
    })
  }
  return $out
}

# ---- self-test -------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$m, [bool]$c, [string]$got) {
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:bad++ }
  }
  # THE FOUNDING CASE, frozen: paid in the db, public on Ghost. This is the 22.
  $f = @(Get-VisibilityFindings @{ 'loaded-chicken-and-potato-casserole' = 'paid' } @{ 'loaded-chicken-and-potato-casserole' = 'public' })
  T 'MUST FIRE  a recipe the db calls paid that Ghost serves public is a LEAK' `
    ($f.Count -eq 1 -and $f[0].verdict -eq 'LEAK') (($f | ForEach-Object { $_.verdict }) -join ',')

  # THE OTHER DIRECTION is real but cosmetic, and must not be called a leak.
  $f = @(Get-VisibilityFindings @{ 'x' = 'public' } @{ 'x' = 'paid' })
  T 'MUST FIRE  db public but Ghost paid is reported as BADGE-SKEW, not a leak' `
    ($f.Count -eq 1 -and $f[0].verdict -eq 'BADGE-SKEW') (($f | ForEach-Object { $_.verdict }) -join ',')

  # CLEAN TWINS. Agreement in either direction is silence.
  T 'CLEAN TWIN paid and paid is silent'     ((@(Get-VisibilityFindings @{ 'a' = 'paid' }   @{ 'a' = 'paid' })).Count -eq 0)   'spurious'
  T 'CLEAN TWIN public and public is silent' ((@(Get-VisibilityFindings @{ 'b' = 'public' } @{ 'b' = 'public' })).Count -eq 0) 'spurious'

  # MEMBERS IS NOT A LEAK. Ghost has three visibilities and only one of them gives the content away;
  # calling 'members' a leak would fill the report with posts that are correctly gated.
  T 'MUST NOT FIRE  a paid recipe Ghost serves to members is gated, not leaking' `
    ((@(Get-VisibilityFindings @{ 'c' = 'paid' } @{ 'c' = 'members' })).Count -eq 0) 'members reported as a leak'
  T 'MUST FIRE  ...but a MEMBERS recipe served public still leaks' `
    ((@(Get-VisibilityFindings @{ 'd' = 'members' } @{ 'd' = 'public' })).Count -eq 1) 'missed'

  # A SLUG GHOST COULD NOT ANSWER FOR is not silently clean - the caller reports it separately, and
  # this predicate must not invent a verdict for it either way.
  T 'a slug absent from Ghost yields no verdict here (the caller names it)' `
    ((@(Get-VisibilityFindings @{ 'e' = 'paid' } @{})).Count -eq 0) 'invented a verdict'
  T 'a slug whose Ghost visibility came back empty yields no verdict' `
    ((@(Get-VisibilityFindings @{ 'f' = 'paid' } @{ 'f' = '' })).Count -eq 0) 'invented a verdict'

  # SCALE: one leak among many healthy rows is still found, and only it is reported.
  $believed = @{}; $actual = @{}
  1..40 | ForEach-Object { $believed["ok-$_"] = 'paid'; $actual["ok-$_"] = 'paid' }
  $believed['leaky'] = 'paid'; $actual['leaky'] = 'public'
  $f = @(Get-VisibilityFindings $believed $actual)
  T 'MUST FIRE  one leak among 40 healthy rows is found, and nothing else is' `
    ($f.Count -eq 1 -and $f[0].slug -eq 'leaky') (($f | ForEach-Object { $_.slug }) -join ',')

  # A MISSING CREDENTIAL MUST NOT READ AS "NO LEAKS" (found by neuter: changing the no-key path from
  # exit 3 to exit 0 left every case above green). Exit 3 is could-not-evaluate and 0 is clean, and a
  # guard that conflates them is the shape lib\guard-contract.ps1 exists to prevent - on a box with no
  # Ghost key this would report a healthy paywall forever. Source-asserted because the live path needs
  # a credential to reach, which is the very thing being tested for absence.
  $self = Get-Content $PSCommandPath -Raw -Encoding utf8
  $noKey = [regex]::Match($self, '(?ms)^if \(-not \$adminKey\) \{.*?^\}')
  T 'MUST FIRE  the no-key path exists and is guarded' ($noKey.Success) 'no-key branch not found'
  if ($noKey.Success) {
    T 'MUST FIRE  a missing Ghost key exits 3 (could-not-evaluate), never 0 (clean)' `
      ($noKey.Value -match 'exit 3' -and $noKey.Value -notmatch 'exit 0') $noKey.Value
    T '  ...and it says so out loud rather than exiting quietly' `
      ($noKey.Value -match 'CANNOT EVALUATE') 'no spoken reason'
  }

  # THE DIRECTION THIS GUARD EXISTS FOR. build-hub-grid only ever asks about slugs LISTED free, so a
  # leak in a slug nobody lists is invisible to it. Pin that this predicate does not inherit the limit.
  $hub = Get-Content (Join-Path $mp 'build-hub-grid.ps1') -Raw -Encoding utf8
  T 'MUST FIRE  build-hub-grid still only checks slugs listed free (this guard covers the other way)' `
    ($hub -match 'free-rotation\.json lists these as free but Ghost does not serve them free') 'the hub check changed shape - re-read whether this guard is still the only one watching leaks'

  # AND IT MUST ACTUALLY RUN. A detector nobody calls detects nothing, which is how the 22 accumulated:
  # every ingredient of the check existed somewhere, wired to no chain that asks this question daily.
  $chain = Join-Path $repo 'grocery\check-ad-cycles.ps1'
  $chainSrc = if (Test-Path $chain) { Get-Content $chain -Raw -Encoding utf8 } else { '' }
  T 'MUST FIRE  the daily chain invokes this guard' ($chainSrc -match 'audit-paid-not-public\.ps1') 'not wired into check-ad-cycles'
  T '  ...with -Alert, or a leak is only ever found by someone reading the log' `
    ($chainSrc -match "audit-paid-not-public\.ps1'\),'-Alert'") 'wired without -Alert'
  # ORDER IS THE POINT: it must run AFTER the rotation, which is the only thing that changes visibility.
  T '  ...and AFTER rotate-free-dinners, the only thing that moves visibility' `
    ($chainSrc.IndexOf('audit-paid-not-public.ps1') -gt $chainSrc.IndexOf('rotate-free-dinners.ps1')) 'wired before the rotation'

  if ($bad -gt 0) { Write-Output "audit-paid-not-public SELF-TEST FAIL ($bad)"; exit 2 }
  Write-Output 'audit-paid-not-public SELF-TEST PASS'
  Write-GuardComplete -Name 'audit-paid-not-public' -Summary 'selftest pass'
  exit 0
}

# ---- live sweep ------------------------------------------------------------------------------------
$adminKey = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY }
            elseif (Test-Path (Join-Path $mp '.ghostkey')) { (Get-Content (Join-Path $mp '.ghostkey') -Raw).Trim() }
            else { $null }
if (-not $adminKey) {
  # COULD-NOT-EVALUATE IS ITS OWN EXIT CODE. A missing credential must never read as "no leaks".
  Write-Output 'audit-paid-not-public: no Ghost admin key (GHOST_ADMIN_KEY or meal-prep\.ghostkey) - CANNOT EVALUATE'
  Write-GuardComplete -Name 'audit-paid-not-public' -Summary 'could-not-evaluate no-key'
  exit 3
}
. (Join-Path $repo 'lib\ghost-lib.ps1')
$apiUrl = 'https://map-to-success.ghost.io'

$published = @{}
$phPath = Join-Path $mp 'db\published-hashes.json'
if (Test-Path $phPath) {
  foreach ($p in ((Get-Content $phPath -Raw -Encoding utf8 | ConvertFrom-Json).PSObject.Properties)) { $published[$p.Name] = $true }
}
$believed = @{}
foreach ($r in ((Read-JsonFile (Join-Path $mp 'recipes-db.json')).recipes)) {
  $slug = [string]$r.slug
  if (-not $published.ContainsKey($slug)) { continue }   # not live: Ghost has nothing to disagree with
  $v = [string]$r.visibility
  if (-not $v) { continue }
  $believed[$slug] = $v
}
if ($Slugs) {
  $want = @($Slugs | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $filtered = @{}; foreach ($s in $want) { if ($believed.ContainsKey($s)) { $filtered[$s] = $believed[$s] } }
  $believed = $filtered
}

$actual = @{}; $unreadable = New-Object System.Collections.Generic.List[string]
$n = 0
foreach ($slug in ($believed.Keys | Sort-Object)) {
  $n++
  try {
    $jwt = Get-GhostJWT -Key $adminKey
    $g = Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$slug/?fields=id,visibility" -Headers @{ Authorization = "Ghost $jwt" }
    $actual[$slug] = [string]$g.posts[0].visibility
  } catch { $unreadable.Add($slug) }
}

$findings = @(Get-VisibilityFindings $believed $actual)
$leaks = @($findings | Where-Object { $_.verdict -eq 'LEAK' })
$skew  = @($findings | Where-Object { $_.verdict -eq 'BADGE-SKEW' })

Write-Output ("audit-paid-not-public: checked {0} published recipe(s) against Ghost" -f $n)
if ($unreadable.Count) {
  Write-Output ("  {0} slug(s) Ghost could not answer for, so they were NOT judged: {1}" -f $unreadable.Count, (($unreadable | Select-Object -First 8) -join ', '))
}
foreach ($f in $leaks) { Write-Output ("  LEAK        {0,-52} db says {1}, Ghost serves {2}" -f $f.slug, $f.believed, $f.actual) }
foreach ($f in $skew)  { Write-Output ("  BADGE-SKEW  {0,-52} db says {1}, Ghost serves {2}" -f $f.slug, $f.believed, $f.actual) }

if ($leaks.Count) {
  Write-Output ("  {0} paid recipe(s) are serving their full content to anonymous visitors. Fix the post visibility in Ghost;" -f $leaks.Count)
  Write-Output '  a republish will NOT repair it, because engine\publish.ps1 preserves live visibility on update.'
  if ($Alert) {
    $alertLib = Join-Path $repo 'grocery\alert-lib.ps1'
    if (Test-Path $alertLib) {
      . $alertLib
      $body = "These recipes are marked paid in recipes-db.json and Ghost is serving them to anonymous visitors:`n`n" +
              (($leaks | ForEach-Object { '  ' + $_.slug + '  (db ' + $_.believed + ' / ghost ' + $_.actual + ')' }) -join "`n") +
              "`n`nA republish will not repair this: engine\publish.ps1 preserves live visibility on update." +
              "`nrotate-free-dinners.ps1 will not repair it either - it only re-paywalls slugs its own ledger owns."
      Send-Alert -Subject ("PAYWALL LEAK: {0} paid recipe(s) served free" -f $leaks.Count) -Body $body -What 'paywall leak' | Out-Null
    }
  }
} elseif (-not $skew.Count) {
  Write-Output '  ok - every published recipe is served exactly as the database says it should be'
}

Write-GuardComplete -Name 'audit-paid-not-public' -Summary ("checked=$n leaks=$($leaks.Count) skew=$($skew.Count) unreadable=$($unreadable.Count)")
if ($leaks.Count) { exit 1 }
exit 0
