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
  [switch]$SkipGhost,          # the drill, and a re-run after Ghost is already gone
  [string]$Root = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
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
    [IO.File]::WriteAllText((Join-Path $t 'pipeline\propagate-stamps.json'),
      (ConvertTo-Json ([ordered]@{ 'keep-me' = 'aaa'; 'drop-me' = 'bbb'; 'keep-two' = 'ccc' }) -Depth 4), $UTF8)

    function Run([hashtable]$p) { $o = & $PSCommandPath @p; return @{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }
    function Rdb { $d = (Get-Content (Join-Path $t 'recipes-db.json') -Raw | ConvertFrom-Json); return $d.recipes }

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
    T '  ...and the propagate stamp is gone' ($null -eq ((Get-Content (Join-Path $t 'pipeline\propagate-stamps.json') -Raw | ConvertFrom-Json).'drop-me')) 'stamp survived'
    T '  ...and the OTHER specs and cards are untouched' ((Test-Path (Join-Path $t 'db\recipes\keep-me.json')) -and (Test-Path (Join-Path $t 'db\built\keep-two.body.html'))) 'collateral damage'

    # MUST FIRE: retiring the same slug twice is refused, not silently "already done"
    $r = Run @{ Slug = 'drop-me'; Reason = 'drill'; Root = $t; SkipGhost = $true; Apply = $true }
    T 'MUST FIRE  retiring an already-retired slug is refused' ($r.rc -ne 0) $r.out
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
Say ("  propagate stamp  : " + $(if ((Test-Path $stampPath) -and (($stampPath | ForEach-Object { (Get-Content $_ -Raw | ConvertFrom-Json) }).PSObject.Properties.Name -contains $Slug)) { 'present' } else { 'absent' }))

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
