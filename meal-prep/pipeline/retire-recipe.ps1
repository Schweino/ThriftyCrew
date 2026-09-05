<#
  retire-recipe.ps1 - take ONE recipe off the site and out of every derived copy, in order, with a
  proof at each step.

  WHY THIS EXISTS (2026-08-29). Nothing in this estate could remove a recipe. publish.ps1 creates and
  updates; propagate carries changes forward; every editor here adds or rewrites. When Brad ruled that
  chicken-biryani-rice-bowls should go, the only options were a hand-edit across six files plus a live
  API call, or this. The `held` state has sat in hunt-run's transition table since 2026-08-15 - added
  because two recipes were once set back to draft in Ghost BY HAND while their state files still read
  `published` - and it had never once been used. A takedown with no state is indistinguishable from a
  publish that worked, and a takedown done by hand across six files is how you get five of them.

  THE ORDER IS THE SAFETY ARGUMENT, and it is deliberately the uncomfortable way round. Ghost goes
  FIRST, before any local write:

    * Ghost first, local second: if a local write then fails, the page is DOWN and the data still
      lists it. feed-covers-published and audit-db-agreement both fail loudly on exactly that, so the
      inconsistency is caught within one run and is recoverable from git.
    * Local first, Ghost second: if the Ghost call then fails, a live paid page exists that no local
      record mentions. Nothing checks for a page the data has forgotten. That is the failure this
      estate already paid for once.

  A half-done retirement is therefore always the loud half, never the silent one.

  WHAT IT TOUCHES, in order:
    1. Ghost                     DELETE the post (the outward, irreversible act)
    2. meal-prep\recipes-db.json          remove the row
    3. meal-prep\db\recipes\<slug>.json   remove the spec
    4. meal-prep\db\built\<slug>.*        remove the built cards
    5. pipeline\propagate-stamps.json     remove the stamp, so nothing tries to republish it

  EVERY LOCAL EDIT IS TEXT SURGERY WITH THE SAME PROOF the rest of the estate uses: re-parse, the
  count drops by exactly one, and every surviving row is byte-identical. recipes-db carries
  \uXXXX-escaped prose that a ConvertTo-Json round trip would rewrite, so a reserialize is not an
  option here any more than it is in add-recipe-board-rows.

  AFTERWARDS, and it says so rather than assuming: gen-planner-data, export-feed and db-build all
  still describe a catalogue with this recipe in it. Run them.

  Usage:
    .\retire-recipe.ps1 -Slug <s> -Reason "<why>"            dry run; proves every step, writes nothing
    .\retire-recipe.ps1 -Slug <s> -Reason "<why>" -Apply
    .\retire-recipe.ps1 -SelfTest
#>
param(
  [string]$Slug = '',
  [string]$Reason = '',
  [switch]$Apply,
  # -NeverPublished: the EXACT COMPLEMENT of the ordinary path. This script refuses any slug with 0
  # recipes-db rows, which is right for a takedown but leaves the built-but-unpublished with no gated
  # disposal at all - and that is a real state, not a hypothetical: a recipe can be sourced, mapped,
  # priced, written, QA'd and CARDED, then ruled a duplicate before it ever publishes. Its spec, its
  # two cards and its propagate stamp all sit on disk claiming a recipe the catalogue will never sell,
  # and the only way to remove them was by hand across four places - which is exactly the "five of six
  # files" failure this script's own header was written to end.
  [switch]$NeverPublished,
  [switch]$SkipGhost,          # the drill, and a re-run after Ghost is already gone
  [string]$Root = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path -Parent $mp
$UTF8 = New-Object System.Text.UTF8Encoding($false)

function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('retire-recipe: ' + $s); exit 1 }

# ---- the one primitive: drop an object from a JSON ARRAY file, by a key field --------------------
# Returns the new raw text. Throws rather than guessing when the object is not uniquely locatable.
function Remove-JsonArrayRow {
  param([string]$Raw, [string]$KeyField, [string]$KeyValue)
  $pat = '"' + [regex]::Escape($KeyField) + '":\s*"' + [regex]::Escape($KeyValue) + '"'
  $ms = [regex]::Matches($Raw, $pat)
  if ($ms.Count -ne 1) { throw ("{0}={1} appears {2} time(s) in the raw text; refusing to guess which" -f $KeyField, $KeyValue, $ms.Count) }
  $start = $Raw.LastIndexOf('{', $ms[0].Index)
  if ($start -lt 0) { throw 'could not find the opening brace of the row' }
  $depth = 0; $end = -1
  for ($i = $start; $i -lt $Raw.Length; $i++) {
    $ch = $Raw[$i]
    if ($ch -eq '"') { $i++; while ($i -lt $Raw.Length -and $Raw[$i] -ne '"') { if ($Raw[$i] -eq '\') { $i++ }; $i++ }; continue }
    if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { throw 'could not find the closing brace of the row' }
  # take the row plus the comma that joins it to a neighbour, on whichever side it has one
  $segStart = $start; $segEnd = $end + 1
  $tail = $Raw.Substring($segEnd)
  $mTail = [regex]::Match($tail, '^\s*,')
  if ($mTail.Success) { $segEnd += $mTail.Length }
  else {
    $mHead = [regex]::Match($Raw.Substring(0, $segStart), ',\s*$')
    if (-not $mHead.Success) { throw 'the row has no comma on either side - is it the only row in the file?' }
    $segStart = $mHead.Index
  }
  return $Raw.Substring(0, $segStart) + $Raw.Substring($segEnd)
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('retire-' + [guid]::NewGuid().ToString('N'))
  try {
    foreach ($d in @('db\recipes', 'db\built', 'pipeline')) { [void](New-Item -ItemType Directory -Force (Join-Path $t $d)) }
    $rdb = @(
      [ordered]@{ slug = 'keep-me';  name = 'Keep Me';  visibility = 'paid' },
      [ordered]@{ slug = 'drop-me';  name = 'Drop Me';  visibility = 'paid' },
      [ordered]@{ slug = 'keep-two'; name = 'Keep Two'; visibility = 'public' })
    # NESTED on purpose: the live recipes-db is {readme, recipes:[...]}, and a drill that only ever
    # built a bare array is what let the array assumption ship.
    [IO.File]::WriteAllText((Join-Path $t 'recipes-db.json'),
      (ConvertTo-Json ([ordered]@{ readme = 'drill'; recipes = $rdb }) -Depth 6), $UTF8)
    foreach ($s in @('keep-me', 'drop-me', 'keep-two')) {
      [IO.File]::WriteAllText((Join-Path $t ('db\recipes\' + $s + '.json')), ('{"slug":"' + $s + '"}'), $UTF8)
      [IO.File]::WriteAllText((Join-Path $t ('db\built\' + $s + '.body.html')), '<p>card</p>', $UTF8)
    }
    # keep-me's card links to drop-me, the way every card's related-recipes grid links to its neighbours.
    [IO.File]::WriteAllText((Join-Path $t 'db\built\keep-me.body.html'),
      "<p>card</p><a href='https://www.thriftycrew.com/drop-me/'>Drop Me</a>", $UTF8)
    [IO.File]::WriteAllText((Join-Path $t 'pipeline\propagate-stamps.json'),
      (ConvertTo-Json ([ordered]@{ 'keep-me' = 'aaa'; 'drop-me' = 'bbb'; 'keep-two' = 'ccc' }) -Depth 4), $UTF8)
    [IO.File]::WriteAllText((Join-Path $t 'db\published-hashes.json'),
      (ConvertTo-Json ([ordered]@{ 'keep-me' = 'h1'; 'drop-me' = 'h2'; 'keep-two' = 'h3' }) -Depth 4), $UTF8)

    function Run([hashtable]$p) { $o = & $PSCommandPath @p; return @{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }
    function Rdb { $d = (Read-JsonFile (Join-Path $t 'recipes-db.json')); return $d.recipes }

    # MUST FIRE: a dry run proves the whole thing and writes nothing.
    $b4 = Get-Content (Join-Path $t 'recipes-db.json') -Raw
    $r = Run @{ Slug = 'drop-me'; Reason = 'drill'; Root = $t; SkipGhost = $true }
    T 'MUST FIRE  a dry run writes nothing' ($r.rc -eq 0 -and (Get-Content (Join-Path $t 'recipes-db.json') -Raw) -eq $b4 -and (Test-Path (Join-Path $t 'db\recipes\drop-me.json'))) $r.out

    # MUST FIRE: -Reason is mandatory. A takedown with no stated cause is indistinguishable from a mistake.
    $r = Run @{ Slug = 'drop-me'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'MUST FIRE  a retirement with no -Reason is refused' ($r.rc -ne 0 -and (Test-Path (Join-Path $t 'db\recipes\drop-me.json'))) $r.out

    # MUST FIRE: an unknown slug is refused before anything is touched.
    $r = Run @{ Slug = 'no-such-recipe'; Reason = 'x'; Root = $t; SkipGhost = $true; Apply = $true }
    # ASSERT THE MESSAGE, NOT MERELY THE EXIT CODE. With the row-count refusal torn out this case
    # still went red - Remove-JsonArrayRow throws on 0 matches a moment later - so it was passing on
    # a different error entirely and proving nothing about the guard it names.
    T 'MUST FIRE  an unknown slug is refused BY NAME, before anything is touched' ($r.rc -ne 0 -and $r.out -match 'holds 0 row' -and @(Rdb).Count -eq 3) $r.out

    # the happy road
    $r = Run @{ Slug = 'drop-me'; Reason = 'drill'; Root = $t; SkipGhost = $true; Apply = $true }
    $after = @(Rdb)
    T 'retires the row from recipes-db' ($r.rc -eq 0 -and $after.Count -eq 2 -and -not (@($after | Where-Object { $_.slug -eq 'drop-me' }))) $r.out
    T '  ...and the neighbours are byte-identical' (([string]($after | Where-Object { $_.slug -eq 'keep-me' }).name -eq 'Keep Me') -and ([string]($after | Where-Object { $_.slug -eq 'keep-two' }).visibility -eq 'public')) 'a surviving row changed'
    T '  ...and the spec file is gone' (-not (Test-Path (Join-Path $t 'db\recipes\drop-me.json'))) 'spec survived'
    T '  ...and the built card is gone' (-not (Test-Path (Join-Path $t 'db\built\drop-me.body.html'))) 'card survived'
    T '  ...and the propagate stamp is gone' ($null -eq ((Read-JsonFile (Join-Path $t 'pipeline\propagate-stamps.json')).'drop-me')) 'stamp survived'
    # THE RECORD THAT THE PAGE IS LIVE MUST GO TOO. Missed by the first cut: steps 1-5 removed
    # everything that DESCRIBED the recipe and left published-hashes saying it was live, so
    # feed-covers-published kept reporting the retired slug as SLUG_MISSING against a page that no
    # longer exists. Reproduced on two separate retirements before it was identified.
    $phAfter = (Read-JsonFile (Join-Path $t 'db\published-hashes.json'))
    T '  ...and the published-hashes entry is gone' ($null -eq $phAfter.'drop-me') 'the retired page still claims to be published'
    T '  ...and the OTHER published hashes survive' (([string]$phAfter.'keep-me' -eq 'h1') -and ([string]$phAfter.'keep-two' -eq 'h3')) 'took a neighbour down with it'
    T '  ...and the OTHER specs and cards are untouched' ((Test-Path (Join-Path $t 'db\recipes\keep-me.json')) -and (Test-Path (Join-Path $t 'db\built\keep-two.body.html'))) 'collateral damage'
    # INBOUND LINKS ARE REPORTED, not repaired: rebuilding somebody else's live card is not this
    # script's call, but leaving a 404 unmentioned is what step 6 already did once.
    T 'MUST FIRE  a live card still linking to the retired page is NAMED' ($r.out -match 'INBOUND LINKS' -and $r.out -match 'keep-me') $r.out
    T '  ...and the linking card is NOT silently rewritten' `
      (([IO.File]::ReadAllText((Join-Path $t 'db\built\keep-me.body.html'))).Contains('thriftycrew.com/drop-me/')) 'the script edited a page it does not own'

    # MUST FIRE: retiring the same slug twice is refused, not silently "already done"
    $r = Run @{ Slug = 'drop-me'; Reason = 'drill'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'MUST FIRE  retiring an already-retired slug is refused' ($r.rc -ne 0) $r.out

    # ---- -NeverPublished: the built-but-unpublished, which the ordinary path refuses ----------------
    # `built-only` exists on disk exactly as a real abandoned recipe does: a spec and cards and a
    # propagate stamp, and NO recipes-db row, NO published-hashes entry, no page.
    [IO.File]::WriteAllText((Join-Path $t 'db\recipes\built-only.json'), '{"slug":"built-only"}', $UTF8)
    [IO.File]::WriteAllText((Join-Path $t 'db\built\built-only.body.html'), '<p>card</p>', $UTF8)
    [IO.File]::WriteAllText((Join-Path $t 'db\built\built-only.head.html'), '<meta>', $UTF8)
    $st = (Read-JsonFile (Join-Path $t 'pipeline\propagate-stamps.json'))
    $st | Add-Member -NotePropertyName 'built-only' -NotePropertyValue 'ddd' -Force
    [IO.File]::WriteAllText((Join-Path $t 'pipeline\propagate-stamps.json'), (ConvertTo-Json $st -Depth 4), $UTF8)

    $r = Run @{ Slug = 'built-only'; Reason = 'ruled a dupe'; Root = $t; SkipGhost = $true; NeverPublished = $true }
    T 'MUST FIRE  -NeverPublished dry run writes nothing' `
      ($r.rc -eq 0 -and (Test-Path (Join-Path $t 'db\recipes\built-only.json'))) $r.out

    $r = Run @{ Slug = 'built-only'; Reason = 'ruled a dupe'; Root = $t; SkipGhost = $true; NeverPublished = $true; Apply = $true }
    T '-NeverPublished removes the spec' ($r.rc -eq 0 -and -not (Test-Path (Join-Path $t 'db\recipes\built-only.json'))) $r.out
    T '  ...and BOTH built cards' (-not (Test-Path (Join-Path $t 'db\built\built-only.body.html')) -and -not (Test-Path (Join-Path $t 'db\built\built-only.head.html'))) $r.out
    T '  ...and the propagate stamp' `
      (-not ((Read-JsonFile (Join-Path $t 'pipeline\propagate-stamps.json')).PSObject.Properties.Name -contains 'built-only')) $r.out
    T '  ...and it does NOT touch recipes-db, which never mentioned it' ((Rdb).Count -eq 2) ([string](Rdb).Count)
    T '  ...and the OTHER specs and cards are untouched' `
      ((Test-Path (Join-Path $t 'db\recipes\keep-me.json')) -and (Test-Path (Join-Path $t 'db\built\keep-two.body.html'))) $r.out

    # THE TWO REFUSALS THAT MAKE IT SAFE.
    $r = Run @{ Slug = 'keep-me'; Reason = 'wrong tool'; Root = $t; SkipGhost = $true; NeverPublished = $true; Apply = $true }
    T 'MUST FIRE  -NeverPublished on a slug that IS in recipes-db is refused (that is a takedown)' `
      ($r.rc -ne 0 -and $r.out -match 'recipes-db holds') $r.out
    T '  ...and it left that recipe entirely alone' ((Rdb).Count -eq 2 -and (Test-Path (Join-Path $t 'db\recipes\keep-me.json'))) ([string](Rdb).Count)

    [IO.File]::WriteAllText((Join-Path $t 'db\recipes\once-live.json'), '{"slug":"once-live"}', $UTF8)
    $ph = (Read-JsonFile (Join-Path $t 'db\published-hashes.json'))
    $ph | Add-Member -NotePropertyName 'once-live' -NotePropertyValue 'h9' -Force
    [IO.File]::WriteAllText((Join-Path $t 'db\published-hashes.json'), (ConvertTo-Json $ph -Depth 4), $UTF8)
    $r = Run @{ Slug = 'once-live'; Reason = 'wrong tool'; Root = $t; SkipGhost = $true; NeverPublished = $true; Apply = $true }
    T 'MUST FIRE  a slug with a published-hashes entry is refused - it HAS been published' `
      ($r.rc -ne 0 -and $r.out -match 'published-hashes') $r.out
    T '  ...and its spec survives the refusal' (Test-Path (Join-Path $t 'db\recipes\once-live.json')) $r.out

    $r = Run @{ Slug = 'never-existed'; Reason = 'nothing here'; Root = $t; SkipGhost = $true; NeverPublished = $true; Apply = $true }
    T 'MUST FIRE  a slug with no spec, card or stamp is refused rather than reported done' `
      ($r.rc -ne 0 -and $r.out -match 'nothing to abandon') $r.out
    $r = Run @{ Slug = 'built-only'; Root = $t; SkipGhost = $true; NeverPublished = $true; Apply = $true }
    T 'MUST FIRE  -NeverPublished still demands a -Reason' ($r.rc -ne 0) $r.out
  } finally { Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue }
  if ($bad) { Write-Output ("retire-recipe SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'retire-recipe SELF-TEST PASS'; exit 0
}

if (-not $Slug)   { Die 'pass -Slug <slug> (or -SelfTest)' }
# A REASON IS MANDATORY. This is the only command that removes reader-facing work; the record has to
# say who decided it should go and why, or a deletion is indistinguishable from an accident later.
if (-not $Reason) { Die 'pass -Reason "<why this recipe is coming down>" - a takedown with no stated cause is a mistake nobody can tell from a decision' }

$rdbPath   = Join-Path $mp 'recipes-db.json'
$specPath  = Join-Path $mp ('db\recipes\' + $Slug + '.json')
$stampPath = Join-Path $here 'propagate-stamps.json'
if ($Root) { $stampPath = Join-Path $Root 'pipeline\propagate-stamps.json' }
$builtDir  = Join-Path $mp 'db\built'

# ---- THE BUILT-BUT-NEVER-PUBLISHED PATH ----------------------------------------------------------
# The ordinary path's order (Ghost first, local second) exists so a half-done takedown is always the
# LOUD half. Here the argument inverts, because there is supposed to be nothing outward at all: Ghost
# is READ first and must answer "no such post". A page found here is not something to delete quietly -
# it is a live page the data has forgotten, the precise failure the header calls the one this estate
# already paid for, and it must be surfaced rather than cleaned up.
if ($NeverPublished) {
  $phPath0 = Join-Path $mp 'db\published-hashes.json'
  if (-not (Test-Path $rdbPath)) { Die ('no recipes-db at ' + $rdbPath) }
  $rdbRaw0 = [IO.File]::ReadAllText($rdbPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
  $p0 = $rdbRaw0 | ConvertFrom-Json
  $rows0 = @($(if ($null -ne $p0 -and $p0.PSObject.Properties.Name -contains 'recipes') { $p0.recipes } else { $p0 }))
  $mine = @($rows0 | Where-Object { [string]$_.slug -eq $Slug })
  if ($mine.Count -ne 0) {
    Die ("recipes-db holds {0} row(s) for '{1}' - this recipe IS in the catalogue, so it is a takedown, not an abandonment. Run without -NeverPublished." -f $mine.Count, $Slug)
  }
  # published-hashes is the record that a page EXISTS. A slug listed there has been published at least
  # once, whatever recipes-db currently says, so -NeverPublished is the wrong instrument for it.
  if (Test-Path $phPath0) {
    $ph0 = ([IO.File]::ReadAllText($phPath0, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', '') | ConvertFrom-Json
    if ($ph0.PSObject.Properties.Name -contains $Slug) {
      Die ("db\published-hashes.json records a published page for '{0}' - it has been published before. Run without -NeverPublished." -f $Slug)
    }
  }
  $spec0  = Test-Path $specPath
  $cards0 = @(Get-ChildItem $builtDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($Slug + '.*') })
  $stamp0 = $false
  if (Test-Path $stampPath) {
    $st0 = ([IO.File]::ReadAllText($stampPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', '') | ConvertFrom-Json
    $stamp0 = ($st0.PSObject.Properties.Name -contains $Slug)
  }
  if (-not $spec0 -and -not $cards0.Count -and -not $stamp0) {
    Die ("nothing to abandon for '{0}' - no spec, no built card, no propagate stamp. Already done, or the slug is wrong." -f $Slug)
  }

  Say ("retire-recipe: " + $Slug + "  [NEVER PUBLISHED]")
  Say ("  reason: " + $Reason)
  Say ("  recipes-db row   : absent (correct for this path)")
  Say ("  published-hashes : absent (correct for this path)")
  Say ("  spec file        : " + $(if ($spec0) { 'present' } else { 'ABSENT' }))
  Say ("  built card(s)    : " + $cards0.Count)
  Say ("  propagate stamp  : " + $(if ($stamp0) { 'present' } else { 'absent' }))

  if ($SkipGhost) { Say '  ghost: SKIPPED (-SkipGhost)' }
  else {
    . (Join-Path $repo 'lib\ghost-lib.ps1')
    $apiUrl0 = 'https://map-to-success.ghost.io'
    $key0 = Get-GhostKey -Root $repo
    if (-not $key0) { Die 'no Ghost admin key - refusing to abandon a recipe without first proving it has no live page' }
    $hdr0 = @{ Authorization = ('Ghost ' + (Get-GhostJWT $key0)); 'Accept-Version' = 'v5.0' }
    $post0 = $null
    try { $post0 = (Invoke-GhostApi -Uri "$apiUrl0/ghost/api/admin/posts/slug/$Slug/?fields=id,status" -Headers $hdr0).posts[0] }
    catch {
      $code0 = 0; $resp0 = $_.Exception.Response
      if ($resp0 -and $resp0.PSObject.Properties['StatusCode']) { try { $code0 = [int]$resp0.StatusCode } catch { $code0 = 0 } }
      if ($code0 -ne 404) { Die ('ghost lookup failed (' + $code0 + ') - unknown is not "never published", so nothing is removed') }
    }
    if ($post0) {
      Die ("ghost HAS a post for '{0}' (id {1}, status {2}) while recipes-db has no row for it. That is a live page the data has forgotten - the failure this script exists to prevent - and it is NOT something to clean up quietly. Investigate it, then use the ordinary takedown path." -f $Slug, $post0.id, [string]$post0.status)
    }
    Say '  ghost: no post with that slug - confirmed never published'
  }

  if (-not $Apply) { Say '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }

  if ($spec0) { Remove-Item $specPath -Force; Say '  spec: removed' }
  foreach ($c in $cards0) { Remove-Item $c.FullName -Force }
  if ($cards0.Count) { Say ('  built: removed ' + $cards0.Count + ' card file(s)') }
  if ($stamp0) {
    $stDoc0 = ([IO.File]::ReadAllText($stampPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', '') | ConvertFrom-Json
    $stDoc0.PSObject.Properties.Remove($Slug)
    [IO.File]::WriteAllText($stampPath, ($stDoc0 | ConvertTo-Json -Depth 6), $UTF8)
    Say '  propagate stamp: removed'
  }
  # Same inbound-link report as the ordinary path: a card that links here would 404, and rebuilding
  # somebody else's live page is not this script's call to make.
  $inb0 = @()
  if (Test-Path $builtDir) {
    $needle0 = 'thriftycrew.com/' + $Slug + '/'
    foreach ($f in (Get-ChildItem (Join-Path $builtDir '*.body.html') -ErrorAction SilentlyContinue)) {
      if (([IO.File]::ReadAllText($f.FullName)).Contains($needle0)) { $inb0 += $f.BaseName }
    }
  }
  if ($inb0.Count) {
    Say ("  INBOUND LINKS: {0} built card(s) still link to this slug - {1}" -f $inb0.Count, ($inb0 -join ', '))
    Say '    rebuild and republish those cards, or they render a 404 in their related-recipes grid.'
  }
  Say ''
  Say ('retire-recipe: ' + $Slug + ' ABANDONED (built, never published) - ' + $Reason)
  # THE CHAIN IS SHORTER THAN A TAKEDOWN'S, BUT IT IS NOT EMPTY - and the first cut of this path said
  # it was. "Nothing in recipes-db, the feed or Ghost ever knew about it" is true and beside the point:
  # cost-recipes builds costed.json from the SPECS, not from recipes-db, so an abandoned recipe keeps
  # its costed row and its v2-perserving row until those are rebuilt. MEASURED immediately after the
  # first real use: both files still carried the slug. Same mistake the ordinary path's own note
  # records making - the chain has to be walked from the SPEC outward.
  Say '  NEXT (recipes-db, the feed and Ghost never knew about this recipe - but the SPEC-driven files did):'
  Say '    meal-prep\engine\cost-recipes.ps1              (costed.json still has its row)'
  Say '    meal-prep\pipeline\compute-v2-perserving.ps1   (v2-perserving.json still has its row)'
  Say '    meal-prep\pipeline\db-build.ps1                 (the sqlite spec table still counts it)'
  Say '  Record the ruling in meal-prep\db\considered-dishes.json if it was a dedup verdict.'
  exit 0
}

if (-not (Test-Path $rdbPath)) { Die ('no recipes-db at ' + $rdbPath) }
$rdbRaw = [IO.File]::ReadAllText($rdbPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
# ASSIGN THEN WRAP. `@($raw | ConvertFrom-Json)` collapses a JSON array to ONE element in PS 5.1 -
# the marshalling trap add-recipe-board-rows.ps1 documents by name, and which this script walked
# straight into on its first self-test run: every row read as a single object and the slug was
# "not found" in a file that plainly contained it.
$rdbParsed = $rdbRaw | ConvertFrom-Json
# TWO FILE SHAPES, ONE TOOL - the same gap add-commodity-rule.ps1 closed in its own sibling. The live
# meal-prep/ecipes-db.json is an OBJECT, {readme, recipes:[...]}, while a bare array is the shape a
# drill naturally builds. The first cut of this assumed the array, and the live file answered "holds
# 0 row(s)" for a slug plainly in it. The guard refused rather than guessing, which is the only
# reason that was a five-minute fix instead of a deletion aimed at the wrong row.
$rdbBefore = @($(if ($null -ne $rdbParsed -and $rdbParsed.PSObject.Properties.Name -contains 'recipes') { $rdbParsed.recipes } else { $rdbParsed }))
$row = @($rdbBefore | Where-Object { [string]$_.slug -eq $Slug })
if ($row.Count -ne 1) { Die ("recipes-db holds {0} row(s) for '{1}' - nothing to retire, or too many to be sure" -f $row.Count, $Slug) }

$cards = @(Get-ChildItem $builtDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($Slug + '.*') })

Say ("retire-recipe: " + $Slug)
Say ("  reason: " + $Reason)
Say ("  recipes-db row   : present (" + $rdbBefore.Count + " rows) - published " + [string]$row[0].published + ", visibility " + [string]$row[0].visibility)
Say ("  spec file        : " + $(if (Test-Path $specPath) { 'present' } else { 'ABSENT' }))
Say ("  built card(s)    : " + $cards.Count)
Say ("  propagate stamp  : " + $(if ((Test-Path $stampPath) -and (($stampPath | ForEach-Object { (Read-JsonFile $_) }).PSObject.Properties.Name -contains $Slug)) { 'present' } else { 'absent' }))

# prove the recipes-db edit BEFORE anything irreversible happens
try { $rdbNew = Remove-JsonArrayRow -Raw $rdbRaw -KeyField 'slug' -KeyValue $Slug } catch { Die ('recipes-db edit could not be proved: ' + $_.Exception.Message) }
$rdbAfterParsed = $rdbNew | ConvertFrom-Json
$rdbAfter = @($(if ($null -ne $rdbAfterParsed -and $rdbAfterParsed.PSObject.Properties.Name -contains 'recipes') { $rdbAfterParsed.recipes } else { $rdbAfterParsed }))
if ($rdbAfter.Count -ne $rdbBefore.Count - 1) { Die ("recipes-db would go {0} -> {1} rows, expected -1" -f $rdbBefore.Count, $rdbAfter.Count) }
# NOTE, HONESTLY: this collateral proof and the row-count proof above are NOT exercised by the
# self-test, and tearing either out leaves every case green. They guard a removal that succeeds but
# produces the wrong text, which no fixture here can induce - Remove-JsonArrayRow either finds its
# row or throws. They are kept because they are the same arithmetic every other editor in this
# estate carries and they cost nothing; they are not claimed as proved.
$sBefore = @($rdbBefore | Where-Object { [string]$_.slug -ne $Slug } | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
$sAfter  = @($rdbAfter | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
if (($sBefore -join "`n") -ne ($sAfter -join "`n")) { Die 'COLLATERAL: a surviving recipes-db row would change. Nothing written.' }
Say ("  recipes-db proof : " + $rdbBefore.Count + ' -> ' + $rdbAfter.Count + ' rows, 0 collateral changes')

if (-not $Apply) { Say '  DRY RUN - nothing written and Ghost untouched. Re-run with -Apply.'; exit 0 }

# ---- 1. GHOST FIRST. The outward act leads, so a later failure leaves the LOUD half. --------------
if ($SkipGhost) { Say '  ghost: SKIPPED (-SkipGhost)' }
else {
  . (Join-Path $repo 'lib\ghost-lib.ps1')
  $apiUrl = 'https://map-to-success.ghost.io'
  $key = Get-GhostKey -Root $repo
  if (-not $key) { Die 'no Ghost admin key - refusing to retire locally while the page would stay live' }
  $jwt = Get-GhostJWT $key
  $hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }
  $post = $null
  try { $post = (Invoke-GhostApi -Uri "$apiUrl/ghost/api/admin/posts/slug/$Slug/?fields=id,status" -Headers $hdr).posts[0] }
  catch {
    $code = 0; $resp = $_.Exception.Response
    if ($resp -and $resp.PSObject.Properties['StatusCode']) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
    if ($code -eq 404) { Say '  ghost: no post with that slug (already gone)' }
    else { Die ('ghost lookup failed (' + $code + ') - refusing to retire locally while the page may still be live') }
  }
  if ($post) {
    Invoke-GhostApi -Method 'DELETE' -Uri "$apiUrl/ghost/api/admin/posts/$($post.id)/" -Headers $hdr | Out-Null
    Say ('  ghost: DELETED post ' + $post.id + ' (was ' + [string]$post.status + ')')
  }
}

# ---- 2..5 local copies ---------------------------------------------------------------------------
[IO.File]::WriteAllText($rdbPath, $rdbNew, $UTF8)
Say ('  recipes-db: wrote ' + $rdbAfter.Count + ' rows')

if (Test-Path $specPath) { Remove-Item $specPath -Force; Say '  spec: removed' }
foreach ($c in $cards) { Remove-Item $c.FullName -Force }
if ($cards.Count) { Say ('  built: removed ' + $cards.Count + ' card file(s)') }

if (Test-Path $stampPath) {
  $stRaw = [IO.File]::ReadAllText($stampPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
  $stDoc = $stRaw | ConvertFrom-Json
  if ($stDoc.PSObject.Properties.Name -contains $Slug) {
    $stDoc.PSObject.Properties.Remove($Slug)
    [IO.File]::WriteAllText($stampPath, ($stDoc | ConvertTo-Json -Depth 6), $UTF8)
    Say '  propagate stamp: removed'
  }
}

# 6. db\published-hashes.json - THE RECORD THAT THE PAGE EXISTS.
#
# MISSED BY THE FIRST CUT (2026-08-29). Steps 1-5 removed the recipe from everything that DESCRIBES it
# and left the record that it is LIVE. So a retired recipe kept claiming to be published: Ghost had no
# post, and this file still said there was one. feed-covers-published reads exactly this file to decide
# what to check, so it then reported the retired slug as SLUG_MISSING - "published, but the feed its
# card fetches has never heard of it" - which is a true sentence about a page that no longer exists.
#
# It cost a whole diagnosis to notice. chicken-biryani-rice-bowls showed up as SLUG_MISSING in this
# morning's first estate-wide feed-covers run and was written off as a pre-existing unrelated defect.
# It was not: it was the FIRST use of this script, three hours earlier, leaving its hash behind. The
# second retirement reproduced it exactly, which is what identified the cause. A takedown that leaves
# the "it is live" record behind is the same class of half-done this script's header argues against -
# it is just the quiet half rather than the loud one.
$phPath = Join-Path $mp 'db\published-hashes.json'
if (Test-Path $phPath) {
  $phRaw = [IO.File]::ReadAllText($phPath, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
  $phDoc = $phRaw | ConvertFrom-Json
  if ($phDoc.PSObject.Properties.Name -contains $Slug) {
    $phDoc.PSObject.Properties.Remove($Slug)
    [IO.File]::WriteAllText($phPath, ($phDoc | ConvertTo-Json -Depth 6), $UTF8)
    Say '  published-hashes: removed'
  }
}

# 7. INBOUND LINKS, reported and never silently repaired. Every card bakes a "related recipes" grid of
# absolute thriftycrew.com URLs, so retiring a recipe leaves a 404 on whatever LIVE pages linked to it.
# Rebuilding those cards regenerates the grid from the current catalogue and drops the dead link - but
# that is a republish of somebody else's live paid page, which is not this script's call to make. It is
# named here because a broken link nobody was told about is exactly what step 6 was.
$inbound = @()
$builtDir = Join-Path $mp 'db\built'
if (Test-Path $builtDir) {
  $needle = 'thriftycrew.com/' + $Slug + '/'
  foreach ($f in (Get-ChildItem (Join-Path $builtDir '*.body.html') -ErrorAction SilentlyContinue)) {
    if (([IO.File]::ReadAllText($f.FullName)).Contains($needle)) { $inbound += $f.BaseName }
  }
}
if ($inbound.Count) {
  Say ("  INBOUND LINKS: {0} live card(s) still link to this now-deleted page - {1}" -f $inbound.Count, ($inbound -join ', '))
  Say '    rebuild and republish those cards, or they render a 404 in their related-recipes grid.'
}

Say ''
Say ('retire-recipe: ' + $Slug + ' RETIRED - ' + $Reason)
# THE FULL CHAIN, AND IT TOOK A VERIFICATION TO GET IT RIGHT. The first cut named three scripts and
# the retired recipe was still on the live feed afterwards: the feed's recipe list comes from
# out/recipe-costs.json, which top5-weekly writes from costed.json, which cost-recipes builds from
# the SPECS. Removing the spec is not enough; the chain has to be walked from the spec outward.
Say '  NEXT (not optional - each of these still describes a catalogue containing it):'
Say '    meal-prep\engine\cost-recipes.ps1              (costed.json still has its row)'
Say '    meal-prep\pipeline\compute-v2-perserving.ps1'
Say '    meal-prep\top5-weekly.ps1 -NoPublish            (writes out\recipe-costs.json)'
Say '    grocery\export-feed.ps1                         (its recipe list comes from recipe-costs.json)'
Say '    meal-prep\gen-planner-data.ps1'
Say '    meal-prep\pipeline\db-build.ps1'
exit 0
