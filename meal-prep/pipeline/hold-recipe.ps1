<#
  hold-recipe.ps1 - take ONE live recipe down to a draft, and leave the estate agreeing about it.

  WHY THIS EXISTS (2026-08-31). Nothing could hold a single recipe. wave-publish's E7 rollback drafts
  posts, but it is WAVE-scoped and it calls `hunt-run -Advance -To held`, which needs a per-slug state
  file - the R300-era recipes have none, so the one command that could draft a page refused the very
  recipes most likely to need it. The alternative was a hand-made Ghost API call, which is how
  2026-08-15 happened: two recipes were set back to draft BY HAND and their state files still read
  `published`, so the run record claimed live pages that were not live.

  THE THREE THINGS E7 DOES NOT DO, and each one has cost something:

  1. IT NEVER VERIFIES. It PUTs status=draft and believes the 200. A PUT that half-lands leaves a page
     the estate thinks is down and readers can still open - the paywall-leak class, where an unverified
     PUT reported success and 22 paid recipes served free. This re-READS the post and asserts the
     status actually says draft.

  2. IT NEVER TOUCHES db\published-hashes.json. That file is the record that a page EXISTS, and
     feed-covers-published reads exactly it to decide what to check - so a held recipe keeps claiming
     to be published and reports as SLUG_MISSING. retire-recipe.ps1 learned this the expensive way and
     its step 6 note says so; the same hole was still open on the hold path.

  3. AND REMOVING THAT HASH INVITES A REPUBLISH, which is the trap that makes this more than
     bookkeeping. engine\publish.ps1 sets status='published' UNCONDITIONALLY on update, and it decides
     what to skip by comparing the local content hash to the stored one. Remove the entry and the next
     ordinary publish run sees a slug it has no hash for, republishes it, and the hold silently ends.
     Keep the entry and feed-covers-published is wrong instead. Neither half is safe alone.

     So the hold is recorded in db\held-recipes.json FIRST, publish.ps1 REFUSES any slug listed there,
     and only then is the hash removed. The order is the safety argument: if this dies midway the slug
     is already protected from republish, and the worst outcome is a held recipe still listed as
     published - which feed-covers-published reports loudly within one run.

  RELEASING is deliberately not automatic. -Release removes the hold and tells you to publish; it does
  not publish for you, because the reason a recipe was held is a thing a human has to decide is over.

  Usage:
    .\hold-recipe.ps1 -Slug <s> -Reason "<why>"            dry run; proves every step, writes nothing
    .\hold-recipe.ps1 -Slug <s> -Reason "<why>" -Apply
    .\hold-recipe.ps1 -Slug <s> -Release -Reason "<why>" -Apply
    .\hold-recipe.ps1 -SelfTest
#>
param(
  [string]$Slug = '',
  [string]$Reason = '',
  [switch]$Apply,
  [switch]$Release,
  [switch]$SkipGhost,      # the drill, and a re-run after Ghost is already drafted
  [string]$Root = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path -Parent $mp
$UTF8 = New-Object System.Text.UTF8Encoding($false)

function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('hold-recipe: ' + $s); exit 1 }

function Read-JsonMap {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return [pscustomobject]@{} }
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
  if (-not $raw.Trim()) { return [pscustomobject]@{} }
  return ($raw | ConvertFrom-Json)
}

function Get-HeldPath { param([string]$M) return (Join-Path $M 'db\held-recipes.json') }
function Get-HashPath { param([string]$M) return (Join-Path $M 'db\published-hashes.json') }

function Test-IsHeld {
  param([string]$M, [string]$S)
  $d = Read-JsonMap (Get-HeldPath $M)
  if (-not $d.PSObject.Properties['held']) { return $false }
  foreach ($h in @($d.held)) { if ([string]$h.slug -eq $S) { return $true } }
  return $false
}

function Add-Held {
  param([string]$M, [string]$S, [string]$Why)
  $p = Get-HeldPath $M
  $d = Read-JsonMap $p
  if (-not $d.PSObject.Properties['_doc']) {
    $d | Add-Member -NotePropertyName '_doc' -NotePropertyValue 'Recipes deliberately taken down to a Ghost draft. engine\publish.ps1 REFUSES to publish a slug listed here, which is the only thing stopping an ordinary publish run from silently ending a hold - it sets status=published unconditionally on update. Remove an entry with hold-recipe.ps1 -Release, then publish it on purpose.' -Force
  }
  if (-not $d.PSObject.Properties['held']) { $d | Add-Member -NotePropertyName 'held' -NotePropertyValue @() -Force }
  $rows = @($d.held | Where-Object { [string]$_.slug -ne $S })
  $rows += [pscustomobject]@{ slug = $S; reason = $Why; held = (Get-Date -Format 'yyyy-MM-dd'); by = 'hold-recipe.ps1' }
  $d.held = @($rows | Sort-Object slug)
  [IO.File]::WriteAllText($p, ($d | ConvertTo-Json -Depth 6), $UTF8)
}

function Remove-Held {
  param([string]$M, [string]$S)
  $p = Get-HeldPath $M
  $d = Read-JsonMap $p
  if (-not $d.PSObject.Properties['held']) { return $false }
  $before = @($d.held).Count
  $d.held = @($d.held | Where-Object { [string]$_.slug -ne $S })
  if (@($d.held).Count -eq $before) { return $false }
  [IO.File]::WriteAllText($p, ($d | ConvertTo-Json -Depth 6), $UTF8)
  return $true
}

function Remove-PublishedHash {
  param([string]$M, [string]$S)
  $p = Get-HashPath $M
  if (-not (Test-Path $p)) { return $false }
  $d = Read-JsonMap $p
  if (-not ($d.PSObject.Properties.Name -contains $S)) { return $false }
  $d.PSObject.Properties.Remove($S)
  [IO.File]::WriteAllText($p, ($d | ConvertTo-Json -Depth 6), $UTF8)
  return $true
}

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('hold-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory -Force (Join-Path $t 'db'))
    [IO.File]::WriteAllText((Join-Path $t 'db\published-hashes.json'),
      (ConvertTo-Json ([ordered]@{ 'keep-me' = 'h1'; 'hold-me' = 'h2'; 'keep-two' = 'h3' }) -Depth 4), $UTF8)

    function Run([hashtable]$p) { $o = & $PSCommandPath @p; return @{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }
    function Hashes { return (Get-Content (Join-Path $t 'db\published-hashes.json') -Raw | ConvertFrom-Json) }

    $r = Run @{ Slug = 'hold-me'; Reason = 'drill'; Root = $t; SkipGhost = $true }
    T 'MUST FIRE  a dry run writes nothing' `
      ($r.rc -eq 0 -and -not (Test-Path (Join-Path $t 'db\held-recipes.json')) -and $null -ne (Hashes).'hold-me') $r.out

    $r = Run @{ Slug = 'hold-me'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'MUST FIRE  a hold with no -Reason is refused' ($r.rc -ne 0) $r.out

    $r = Run @{ Slug = 'hold-me'; Reason = 'drill'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'the slug is recorded held' (Test-IsHeld $t 'hold-me') $r.out
    T '  ...and its published-hash is removed, so feed-covers stops calling it live' ($null -eq (Hashes).'hold-me') $r.out
    T '  ...and the OTHER hashes survive' (((Hashes).'keep-me' -eq 'h1') -and ((Hashes).'keep-two' -eq 'h3')) 'collateral'

    # THE ORDER IS THE SAFETY ARGUMENT: held is written BEFORE the hash is removed, so a crash in
    # between leaves the slug protected from republish rather than exposed to one.
    $held = Get-Content (Join-Path $t 'db\held-recipes.json') -Raw | ConvertFrom-Json
    T '  ...and the hold carries a reason and a date' `
      ((@($held.held)[0].reason -eq 'drill') -and (@($held.held)[0].held -match '^\d{4}-\d{2}-\d{2}$')) (ConvertTo-Json @($held.held)[0] -Compress)

    $r = Run @{ Slug = 'hold-me'; Reason = 'drill'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'MUST FIRE  holding an already-held slug is refused, not silently repeated' ($r.rc -ne 0) $r.out

    $r = Run @{ Slug = 'hold-me'; Reason = 'done'; Root = $t; Release = $true; Apply = $true }
    T '-Release removes the hold' (-not (Test-IsHeld $t 'hold-me')) $r.out
    T '  ...and does NOT put the hash back (publishing is a separate, deliberate act)' ($null -eq (Hashes).'hold-me') $r.out
    T '  ...and says so rather than leaving the operator to guess' ($r.out -match 'publish\.ps1') $r.out

    $r = Run @{ Slug = 'never-held'; Reason = 'x'; Root = $t; Release = $true; Apply = $true }
    T 'MUST FIRE  releasing a slug that was never held is refused' ($r.rc -ne 0) $r.out

    # AND THE REFUSAL publish.ps1 IS SUPPOSED TO CARRY. A held recipe that publish.ps1 would still
    # publish is a hold in name only, so the wiring is asserted here rather than assumed.
    $pub = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'engine\publish.ps1'
    if (Test-Path $pub) {
      $src = [IO.File]::ReadAllText($pub)
      # ASSERTED ON THE ASSIGNMENT, NOT THE WORD. The first cut checked that publish.ps1 merely CONTAINED
      # the string 'held-recipes.json' - and it passed with the path repointed at a file that does not
      # exist, because the word also appears in that file's own explanatory comment. A neuter is the only
      # reason that was ever found; the case now pins the $heldFile assignment and the refusal branch.
      # Built by concatenation so this file cannot satisfy the check with its own text.
      $lit = '$heldFile = Join-Path $root ' + [char]0x27 + 'db' + [char]0x5C + 'held-recipes.json' + [char]0x27
      $assign = $src.Contains($lit)
      T 'publish.ps1 loads db\held-recipes.json by name' $assign 'the $heldFile assignment does not point at held-recipes.json - a hold would not survive the next publish run'
      T '  ...and REFUSES a slug that is on it' ($src -match 'REFUSED HELD') 'publish.ps1 reads the list but does not act on it'
    } else { Write-Output '  X     engine\publish.ps1 not found - cannot prove the hold is enforced'; $bad++ }
  }
  finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
  if ($bad -eq 0) { Write-Output 'hold-recipe SELF-TEST PASS'; exit 0 }
  Write-Output ("hold-recipe SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
}

# ---------------------------------------------------------------------------------------------------
if (-not $Slug)   { Die 'pass -Slug <slug> (or -SelfTest)' }
if (-not $Reason) { Die 'pass -Reason "<why>" - a page taken down with no stated cause is a mistake nobody can tell from a decision' }

$apiUrl = 'https://map-to-success.ghost.io'

# ---- RELEASE ---------------------------------------------------------------------------------------
if ($Release) {
  if (-not (Test-IsHeld $mp $Slug)) { Die ("'{0}' is not in db\held-recipes.json - nothing to release" -f $Slug) }
  Say ("hold-recipe: RELEASE " + $Slug)
  Say ("  reason: " + $Reason)
  if (-not $Apply) { Say '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
  [void](Remove-Held $mp $Slug)
  Say '  held-recipes: entry removed'
  Say ''
  Say '  The post is STILL A DRAFT and its published-hash is still absent. Releasing the hold only'
  Say '  removes the refusal; it does not publish, because whether the reason for the hold is over is'
  Say '  a decision, not a side effect. To put it back:'
  Say ("    meal-prep\engine\publish.ps1 -Slugs {0}" -f $Slug)
  exit 0
}

# ---- HOLD ------------------------------------------------------------------------------------------
if (Test-IsHeld $mp $Slug) { Die ("'{0}' is ALREADY recorded held in db\held-recipes.json - nothing to do" -f $Slug) }

$hashes = Read-JsonMap (Get-HashPath $mp)
$hasHash = ($hashes.PSObject.Properties.Name -contains $Slug)

Say ("hold-recipe: " + $Slug)
Say ("  reason: " + $Reason)
Say ("  published-hash  : " + $(if ($hasHash) { 'present (will be removed)' } else { 'ABSENT - this recipe does not claim to be published' }))

$post = $null
if ($SkipGhost) { Say '  ghost: SKIPPED (-SkipGhost)' }
else {
  . (Join-Path $repo 'lib\ghost-lib.ps1')
  $key = Get-GhostKey -Root $repo
  if (-not $key) { Die 'no Ghost admin key - refusing to record a hold locally while the page would stay live' }
  $jwt = Get-GhostJWT $key
  $hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0'; 'Content-Type' = 'application/json' }
  try { $post = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,status,updated_at" -Headers $hdr).posts[0] }
  catch { Die ('ghost lookup failed - refusing to act on a page whose state is unknown: ' + $_.Exception.Message) }
  if (-not $post) { Die ("ghost has no post with slug '{0}' - there is nothing live to hold" -f $Slug) }
  Say ("  ghost           : found " + $post.id + ", status " + [string]$post.status)
  if ([string]$post.status -eq 'draft') { Die ("ghost already has '{0}' as a DRAFT. If the estate still lists it as published, that is the half-done state to fix - re-run with -SkipGhost to reconcile the local records only." -f $Slug) }
}

if (-not $Apply) { Say '  DRY RUN - nothing written and Ghost untouched. Re-run with -Apply.'; exit 0 }

# 1. GHOST FIRST, then VERIFY BY RE-READING. A 200 is not proof; the paywall leak was an unverified PUT.
if (-not $SkipGhost) {
  $body = (@{ posts = @(@{ id = $post.id; updated_at = $post.updated_at; status = 'draft' }) } | ConvertTo-Json -Depth 6 -Compress)
  try { Invoke-GhostApi -Method 'PUT' -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers $hdr -Body $body | Out-Null }
  catch { Die ('the draft PUT failed - the page is STILL LIVE and nothing local was changed: ' + $_.Exception.Message) }

  $jwt2 = Get-GhostJWT $key
  $hdr2 = @{ Authorization = "Ghost $jwt2"; 'Accept-Version' = 'v5.0' }
  $check = $null
  try { $check = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,status" -Headers $hdr2).posts[0] } catch {}
  if (-not $check -or [string]$check.status -ne 'draft') {
    Die ("VERIFY FAILED: after the PUT, Ghost reports status '{0}' for '{1}'. The page may still be LIVE. Nothing local was changed - look before re-running." -f [string]$check.status, $Slug)
  }
  Say ('  ghost           : DRAFTED and verified by re-read (status ' + [string]$check.status + ')')
}

# 2. HELD BEFORE HASH. The held list is what stops publish.ps1 republishing it; writing it first means a
#    crash between these two leaves the slug PROTECTED and merely mis-listed, never exposed.
Add-Held -M $mp -S $Slug -Why $Reason
Say '  held-recipes    : recorded (publish.ps1 will refuse this slug)'

if (Remove-PublishedHash -M $mp -S $Slug) { Say '  published-hashes: entry removed' }
else { Say '  published-hashes: no entry to remove' }

# 3. The per-slug run state, when there is one. R300-era recipes have none, and that is not an error -
#    it is the exact gap that made this script necessary, so it is REPORTED rather than swallowed.
$stateHit = $null
foreach ($sf in @(Get-ChildItem (Join-Path $mp 'runs\*\state\*.json') -ErrorAction SilentlyContinue)) {
  if ($sf.BaseName -eq $Slug) { $stateHit = $sf; break }
}
if ($stateHit) {
  $runDir = Split-Path (Split-Path $stateHit.FullName -Parent) -Parent
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'hunt-run.ps1') `
      -Advance -RunDir $runDir -Slug $Slug -To held -By 'hold-recipe' -Detail $Reason | Out-Null
  if ($LASTEXITCODE -eq 0) { Say ('  run state       : advanced to held in ' + (Split-Path $runDir -Leaf)) }
  else { Say ('  run state       : hunt-run REFUSED the advance to held in ' + (Split-Path $runDir -Leaf) + ' - the hold stands, but that run record still says otherwise') }
} else {
  Say '  run state       : none (this recipe predates the per-slug state machine - the hold is recorded in db\held-recipes.json only)'
}

Say ''
Say ('hold-recipe: ' + $Slug + ' HELD - ' + $Reason)
Say '  The card, spec and feed rows are all untouched: this is a takedown, not a retirement.'
Say '  Release it with:  hold-recipe.ps1 -Slug ' + $Slug + ' -Release -Reason "<why>" -Apply'
exit 0
