# probe-allergen-backfill.ps1 - what the allergen-line backfill republish (backlog I172) would change,
# measured OFFLINE, so the one command Brad runs has a stated blast radius before it runs.
# ===================================================================================================
# WHY THIS IS A COMMITTED HARNESS AND NOT A SCRATCH ONE (measurement.md: "naming a scratch harness is
# not naming a harness"). The backfill is Brad's to run, and he will run it on a later day than the one
# this was measured on: the specs are re-anchored daily and the related-recipes footer rotates weekly,
# so every number below moves. The question recurs, so the probe is committed and re-run, never quoted.
#
# WHAT IT DOES, AND WHAT IT NEVER DOES. It renders every spec in db\recipes through the real
# build-card2.ps1 into a per-run scratch directory under %TEMP% - NEVER into db\built - and reads:
#   1. does every rebuilt card carry exactly the line audit-allergen-line derives (the finish condition
#      I172 names, checked against the scratch cards instead of the live ones);
#   2. how each rebuilt card differs from the card in db\built today, split into the allergen line alone,
#      the allergen line plus the rotating related-recipes footer, and ANYTHING ELSE (named per card with
#      the first differing bytes, because "anything else" is the part a reader might see move);
#   3. what engine\publish.ps1 -All would do with those bytes, by recomputing its change-gate hash (the
#      one formula copied here, and a self-test case pins it against publish.ps1's own source) against
#      the publish journal: PUT, skipped unchanged, refused create (no journal entry), held, or refused
#      for carriage.
# It makes NO network call, reads no Ghost key and writes nothing tracked. The scratch directory is
# removed in a finally unless -KeepScratch is passed (then it is printed so a card can be looked at).
#
# SCOPE OF A CLEAN REPORT: it predicts publish.ps1's LOCAL decisions only. The existence GET and the
# live-drift pre-flight need Ghost, so a slug this counts as a PUT can still be refused at run time as
# live drift, and one counted as refused-create may in fact exist live under a slug the journal lost.
#
#   .\probe-allergen-backfill.ps1                               whole catalogue, summary to stdout
#   .\probe-allergen-backfill.ps1 -PublishedHashes <path>       journal elsewhere (a worktree has none)
#   .\probe-allergen-backfill.ps1 -OutFile rows.jsonl           one row per slug (measurement.md E24)
#   .\probe-allergen-backfill.ps1 -Slugs a,b -KeepScratch       a sample, keeping the rendered cards
#   .\probe-allergen-backfill.ps1 -SelfTest                     frozen fixtures, hermetic
# Exit 0 the report ran, 1 a rebuilt card still fails the allergen check, 3 could not evaluate.
# WHAT THE SELF-TEST READS: in-file card fixtures and the TEXT of engine\publish.ps1 (hash-formula lockstep); the catalogue is read below the self-test.
# gate-inputs: meal-prep\pipeline\probe-allergen-backfill.ps1
# gate-inputs-text: meal-prep\engine\publish.ps1
# ===================================================================================================
param(
  [string]$Slugs = '',
  [string]$PublishedHashes = '',
  [string]$OutFile = '',
  [switch]$KeepScratch,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runKeep = [bool]$KeepScratch

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $mp 'lib\allergen-lib.ps1')

# ---------------------------------------------------------------------------------------------------
# THE PREDICATES, pure.
# ---------------------------------------------------------------------------------------------------
function Remove-AllergenRender {
  # The two things build-card2 added for I144: the line itself (preceded by the newline its $L join puts
  # before it) and the four .smp-allergen CSS rules in the elite style block.
  param([string]$Html)
  $s = [regex]::Replace($Html, '\r?\n<p class="smp-allergen">.*?</p>', '', [Text.RegularExpressions.RegexOptions]::Singleline)
  return [regex]::Replace($s, '\.smp-allergen[^{]*\{[^}]*\}\r?\n?', '')
}
function Remove-RelatedFooter {
  # "Three more for this week": two of its three cards are the current free picks, which rotate weekly,
  # so this block differs on a rebuild whatever the recipe did.
  param([string]$Html)
  return [regex]::Replace($Html, "<div class='smp-rel'>.*?</div></div>", '', [Text.RegularExpressions.RegexOptions]::Singleline)
}
function Remove-CostBar {
  # The cost-composition block: bar, key and its one-line verdict ("The 93/7 ground beef is the whole
  # bill..."). A build-time snapshot of db\costed.json - build-card2's header says renderComp() redraws it
  # from the release once the feed lands - so its shares, their order and that sentence move whenever a
  # price did. The whole block is one region.
  param([string]$Html)
  return [regex]::Replace($Html, $script:CostBarRe, '', [Text.RegularExpressions.RegexOptions]::Singleline)
}
$script:CostBarRe = "<div class='smp-comp'>.*?<p class='smp-comp-pay'>.*?</p></div>"
function Remove-RecipePaywallClaim {
  # Backlog I44's JSON-LD claim on the Recipe node ("isAccessibleForFree": false plus a hasPart naming
  # .gh-content). Removed from BOTH heads: the Article node has carried the compact form all along.
  param([string]$Head)
  return [regex]::Replace($Head, ',\s*"isAccessibleForFree":\s*false,\s*"hasPart":\s*\{[^}]*\}', '')
}
function Get-FirstDiff {
  param([string]$A, [string]$B)
  $n = [Math]::Min($A.Length, $B.Length)
  for ($i = 0; $i -lt $n; $i++) { if ($A[$i] -ne $B[$i]) { return $i } }
  if ($A.Length -ne $B.Length) { return $n }
  return -1
}
function Test-Same([string]$A, [string]$B) { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }
function Get-BackfillClass {
  <# How a rebuilt card differs from the card on disk today. Returns @{ class; kinds; at; where; old; new }.
     kinds lists EVERY known change present, not only the first: allergen (always, when the line is
     there), footer, cost-bar, paywall-schema. class is the verdict over all of them:
       no-line          the rebuilt card has no allergen line at all (the backfill would not fix it)
       allergen-only    the line and its CSS are the whole difference
       allergen+known   plus only the known drifts named in kinds, nothing else
       other            something UNNAMED moved too, and old/new carry its first differing bytes #>
  param([string]$OldBody, [string]$NewBody, [string]$OldHead, [string]$NewHead)
  if ($null -eq (Get-TcCardAllergenLine $NewBody)) { return @{ class = 'no-line'; kinds = @(); at = -1; old = ''; new = '' } }
  $kinds = @('allergen')
  $a = $OldBody; $b = Remove-AllergenRender $NewBody
  $footRe = "<div class='smp-rel'>.*?</div></div>"
  if (-not (Test-Same ([regex]::Match($a, $footRe, 'Singleline').Value) ([regex]::Match($b, $footRe, 'Singleline').Value))) { $kinds += 'footer' }
  if (-not (Test-Same ([regex]::Match($a, $script:CostBarRe, 'Singleline').Value) ([regex]::Match($b, $script:CostBarRe, 'Singleline').Value))) { $kinds += 'cost-bar' }
  $ha = Remove-RecipePaywallClaim $OldHead; $hb = Remove-RecipePaywallClaim $NewHead
  if (-not (Test-Same ([string]($OldHead.Length - $ha.Length)) ([string]($NewHead.Length - $hb.Length)))) { $kinds += 'paywall-schema' }
  $a = Remove-CostBar (Remove-RelatedFooter $a); $b = Remove-CostBar (Remove-RelatedFooter $b)
  if ((Test-Same $a $b) -and (Test-Same $ha $hb)) {
    return @{ class = $(if ($kinds.Count -eq 1) { 'allergen-only' } else { 'allergen+known' }); kinds = $kinds; at = -1; old = ''; new = '' }
  }
  $where = 'body'; $x = $a; $y = $b
  if (Test-Same $a $b) { $where = 'head'; $x = $ha; $y = $hb }
  $d = Get-FirstDiff $x $y
  $lo = [Math]::Max(0, $d - 60)
  return @{ class = 'other'; kinds = ($kinds + @('unnamed')); at = $d; where = $where
            old = $x.Substring($lo, [Math]::Min(160, $x.Length - $lo)); new = $y.Substring($lo, [Math]::Min(160, $y.Length - $lo)) }
}
# engine\publish.ps1's change-gate hash, COPIED. The self-test pins this spelling against publish.ps1's own
# source, so the day the formula moves there this probe goes red instead of predicting the wrong set.
function Get-PublishContentHash([string]$s){ $sha=[System.Security.Cryptography.SHA1]::Create(); return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-','') }

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0; $ran = 0
  function Check([string]$name, [bool]$ok, [string]$got) {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $name) } else { Write-Output ("  X     " + $name + "   got: " + $got); $script:bad++ }
  }
  $css  = '.smp-rel-p{color:#0c5c3b}' + "`n"
  $cssA = '.smp-allergen{margin:1.1rem 0 0}' + "`n" + '.smp-allergen strong{letter-spacing:.01em}' + "`n"
  $line = '<p class="smp-allergen"><strong>Contains:</strong> wheat. <span class="smp-allergen-note">n</span></p>'
  $foot1 = "<div class='smp-rel'><h2>Three more</h2><div class='smp-rel-grid'><a href='/a/'>A</a></div></div>"
  $foot2 = "<div class='smp-rel'><h2>Three more</h2><div class='smp-rel-grid'><a href='/b/'>B</a></div></div>"
  $old = '<style>' + $css + '</style><ul class="smp-ing"><li>x</li></ul>' + "`n" + '<!--TC-PAYWALL--><p>$4.10</p>' + $foot1
  $newOnly = '<style>' + $css + $cssA + '</style><ul class="smp-ing"><li>x</li></ul>' + "`n" + $line + "`n" + '<!--TC-PAYWALL--><p>$4.10</p>' + $foot1
  $newFoot = $newOnly.Replace($foot1, $foot2)
  $newPrice = $newOnly.Replace('$4.10', '$4.35')

  # CLEAN TWIN: the difference the backfill exists to make is recognised as exactly that.
  $c = Get-BackfillClass $old $newOnly 'h' 'h'
  Check 'CLEAN TWIN a rebuild that adds only the line and its CSS is allergen-only' ($c.class -eq 'allergen-only') $c.class
  $c = Get-BackfillClass $old $newFoot 'h' 'h'
  Check 'CLEAN TWIN a rotated related-recipes footer is named as the footer, not as some other change' ($c.class -eq 'allergen+known' -and ($c.kinds -join ',') -eq 'allergen,footer') ($c.class + ' ' + ($c.kinds -join ','))
  $barOld = $old.Replace('<p>$4.10</p>', "<p>`$4.10</p><div class='smp-comp'><i style='width:63.269%' title='Beef: 63%'></i><p class='smp-comp-pay'>Beef is the bill.</p></div>")
  $barNew = $newOnly.Replace('<p>$4.10</p>', "<p>`$4.10</p><div class='smp-comp'><i style='width:70.1%' title='Beef: 70%'></i><p class='smp-comp-pay'>Beef is most of the bill.</p></div>")
  $c = Get-BackfillClass $barOld $barNew 'h' 'h'
  Check 'CLEAN TWIN moved cost-bar shares are named as cost-bar, not as some other change' ($c.class -eq 'allergen+known' -and ($c.kinds -join ',') -eq 'allergen,cost-bar') ($c.class + ' ' + ($c.kinds -join ','))
  $hOld = '{ "totalTime": "PT1H" }'
  $hNew = '{ "totalTime": "PT1H", "isAccessibleForFree": false, "hasPart": { "@type": "WebPageElement", "cssSelector": ".gh-content" } }'
  $c = Get-BackfillClass $old $newOnly $hOld $hNew
  Check 'CLEAN TWIN the Recipe-node paywall claim (backlog I44) is named as paywall-schema' ($c.class -eq 'allergen+known' -and ($c.kinds -join ',') -eq 'allergen,paywall-schema') ($c.class + ' ' + ($c.kinds -join ','))
  # MUST FIRE: the change a reader could see move, which is what this probe exists to count.
  $c = Get-BackfillClass $old $newPrice 'h' 'h'
  Check 'MUST FIRE  a rebuild that also moves a number in the card body is OTHER, with the bytes named' `
    ($c.class -eq 'other' -and $c.where -eq 'body' -and $c.new -match '4\.35' -and $c.old -match '4\.10') ($c.class + ' ' + $c.new)
  $c = Get-BackfillClass $old $newOnly 'costPerServing 4.10' 'costPerServing 4.35'
  Check 'MUST FIRE  a rebuild that moves the head (JSON-LD) is OTHER even when the body agrees' ($c.class -eq 'other' -and $c.where -eq 'head') $c.class
  $c = Get-BackfillClass $old $old 'h' 'h'
  Check 'MUST FIRE  a rebuilt card with NO allergen line is no-line, never allergen-only' ($c.class -eq 'no-line') $c.class
  # MUST FIRE: the copied hash formula still matches publish.ps1's. The needle is BUILT, so this file's
  # own text is not what it finds (ops rule: a self-test that greps its own source cannot fail).
  $pub = [IO.File]::ReadAllText((Join-Path $mp 'engine\publish.ps1'), [Text.Encoding]::UTF8)
  $needle = '$contentHash = Get-' + 'ContentHash ($body + "`0" + $head + "`0" + [string]$spec.name + "`0" + $desc)'
  Check 'MUST FIRE  publish.ps1 still hashes body, head, name and description in the order this probe copies' ($pub.Contains($needle)) 'the formula in publish.ps1 moved - update Get-BackfillPublishHash'
  $needle2 = '[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace ' + "'-',''"
  Check 'MUST FIRE  and still SHA1s the UTF-8 bytes the same way' ($pub.Contains($needle2)) 'the hash function in publish.ps1 moved'

  $expected = 9
  if ($ran -ne $expected) { Write-Output ("probe-allergen-backfill SELF-TEST FAIL: ran {0} case(s), expected {1}" -f $ran, $expected); exit 1 }
  if ($bad -gt 0) { Write-Output ("probe-allergen-backfill SELF-TEST FAIL ({0} of {1} case(s))" -f $bad, $ran); exit 1 }
  Write-Output ("probe-allergen-backfill SELF-TEST PASS: {0} of {0} case(s)" -f $ran)
  exit 0
}

# ---- the probe -------------------------------------------------------------------------------------
. (Join-Path $mp 'lib\render-tokens.ps1')   # Expand-SpecProse / Move-SpecPriceToReleaseHydration, as publish.ps1 applies them
function Get-BackfillPublishHash {
  # publish.ps1 reads the spec with a bare Get-Content (the system code page under PS 5.1) and hashes the
  # expanded description; mirrored exactly, including that read, or a non-ASCII name would hash apart.
  param([string]$SpecPath, [string]$Body, [string]$Head)
  $spec = Get-Content $SpecPath -Raw | ConvertFrom-Json
  $spec = Expand-SpecProse $spec
  $spec = Move-SpecPriceToReleaseHydration $spec
  $desc = [string]$spec.head.description
  return (Get-PublishContentHash ($Body + "`0" + $Head + "`0" + [string]$spec.name + "`0" + $desc))
}

$recipesDir = Join-Path $mp 'db\recipes'
$builtDir   = Join-Path $mp 'db\built'
$costedPath = Join-Path $mp 'db\costed.json'
$tablePath  = Join-Path $mp 'db\allergens.json'
if (-not $PublishedHashes) { $PublishedHashes = Join-Path $mp 'db\published-hashes.json' }
$blind = @()
foreach ($need in @($recipesDir, $builtDir, $costedPath, $tablePath, $PublishedHashes)) { if (-not (Test-Path -LiteralPath $need)) { $blind += $need } }
if ($blind.Count) {
  Write-Output ("probe-allergen-backfill: COULD NOT EVALUATE - missing: " + ($blind -join ' | ') + '. db\built and the publish journal are gitignored; seed the worktree (ops\seed-worktree.ps1) or pass -PublishedHashes.')
  Exit-Guard -Name 'probe-allergen-backfill' -Summary ('blind=missing-input n=' + $blind.Count) -Code 3
}

$pubHashes = @{}
foreach ($p in (Get-Content -LiteralPath $PublishedHashes -Raw | ConvertFrom-Json).PSObject.Properties) { $pubHashes[$p.Name] = [string]$p.Value }
$held = @{}
$heldFile = Join-Path $mp 'db\held-recipes.json'
if (Test-Path -LiteralPath $heldFile) { foreach ($h in @((Get-Content -LiteralPath $heldFile -Raw | ConvertFrom-Json).held)) { if ($h -and $h.slug) { $held[[string]$h.slug] = 1 } } }
$uncarried = @{}
foreach ($c in (Get-Content -LiteralPath $costedPath -Raw | ConvertFrom-Json)) {
  if (($c.PSObject.Properties.Name -contains 'uncarried') -and @($c.uncarried).Count) { $uncarried[[string]$c.slug] = 1 }
}
$table = Get-TcAllergenTable -Path $tablePath

$specFiles = @(Get-ChildItem -LiteralPath $recipesDir -Filter *.json | Sort-Object Name)
$want = @($Slugs.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($want.Count) { $specFiles = @($specFiles | Where-Object { $want -contains $_.BaseName }) }
$builtNow = @{}
foreach ($b in (Get-ChildItem -LiteralPath $builtDir -Filter *.body.html)) { $builtNow[($b.Name -replace '\.body\.html$', '')] = 1 }

$scratch = Join-Path $env:TEMP ('abf-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
$rows = New-Object System.Collections.Generic.List[object]
$buildErrors = 0
try {
  $global:__tcCostedCache = @{}
  foreach ($sf in $specFiles) {
    $slug = $sf.BaseName
    $row = [ordered]@{ slug = $slug; built_now = $builtNow.ContainsKey($slug) }
    try {
      & (Join-Path $here 'build-card2.ps1') -SpecFile $sf.FullName -CostedFile $costedPath -OutDir $scratch *>$null
    } catch { $row.build = 'error'; $row.error = $_.Exception.Message; $buildErrors++; [void]$rows.Add([pscustomobject]$row); continue }
    $nb = Join-Path $scratch ($slug + '.body.html'); $nh = Join-Path $scratch ($slug + '.head.html')
    if (-not (Test-Path -LiteralPath $nb)) { $row.build = 'error'; $row.error = 'no body html was written'; $buildErrors++; [void]$rows.Add([pscustomobject]$row); continue }
    $row.build = 'ok'
    $newBody = [IO.File]::ReadAllText($nb, [Text.Encoding]::UTF8)
    $newHead = if (Test-Path -LiteralPath $nh) { [IO.File]::ReadAllText($nh, [Text.Encoding]::UTF8) } else { '' }
    $spec = Get-Content -LiteralPath $sf.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    $ing = @(); if ($spec.scaler -and $spec.scaler.ing) { $ing = @($spec.scaler.ing) }
    $res = Get-TcRecipeAllergens $ing $table.Items
    if (@($res.unknown).Count) { $row.allergen = 'unclassified' }
    else { $v = Get-TcAllergenCardVerdict $newBody (Format-TcAllergenLine $res $slug); $row.allergen = $(if ($v) { $v } else { 'agrees' }) }
    $row.contains = @($res.present | ForEach-Object { $_.key })
    if ($row.built_now) {
      $oldBody = [IO.File]::ReadAllText((Join-Path $builtDir ($slug + '.body.html')), [Text.Encoding]::UTF8)
      $ohp = Join-Path $builtDir ($slug + '.head.html')
      $oldHead = if (Test-Path -LiteralPath $ohp) { [IO.File]::ReadAllText($ohp, [Text.Encoding]::UTF8) } else { '' }
      $cls = Get-BackfillClass $oldBody $newBody $oldHead $newHead
      $row.diff = $cls.class
      $row.kinds = @($cls.kinds)
      if ($cls.class -eq 'other') { $row.diff_where = $cls.where; $row.diff_at = $cls.at; $row.diff_old = $cls.old; $row.diff_new = $cls.new }
      $row.built_matches_journal = ($pubHashes.ContainsKey($slug) -and ((Get-BackfillPublishHash $sf.FullName $oldBody $oldHead) -eq $pubHashes[$slug]))
    } else { $row.diff = 'new-card' }
    # publish.ps1 -All iterates db\built, so a card that is not there today enters its list only because
    # build-cards wrote it. Its order of refusals is held, carriage, then create/unchanged/PUT.
    if ($held.ContainsKey($slug)) { $row.publish = 'refused-held' }
    elseif ($uncarried.ContainsKey($slug)) { $row.publish = 'refused-carriage' }
    elseif (-not $pubHashes.ContainsKey($slug)) { $row.publish = 'refused-create-if-not-live' }
    elseif ((Get-BackfillPublishHash $sf.FullName $newBody $newHead) -eq $pubHashes[$slug]) { $row.publish = 'unchanged' }
    else { $row.publish = 'put' }
    [void]$rows.Add([pscustomobject]$row)
  }
} finally {
  if (-not $runKeep) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

$all = $rows.ToArray()
$orphans = @($builtNow.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $recipesDir ($_ + '.json'))) } | Sort-Object)
if ($OutFile) {
  $sb = New-Object Text.StringBuilder
  foreach ($r in $all) { [void]$sb.Append(($r | ConvertTo-Json -Compress -Depth 5)).Append("`n") }
  [IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}
function Get-CountBy($arr, [string]$field) {
  $h = [ordered]@{}
  foreach ($r in $arr) { $k = [string]$r.$field; if (-not $k) { $k = '(none)' }; if (-not $h.Contains($k)) { $h[$k] = 0 }; $h[$k]++ }
  return $h
}
$n = $all.Count
$okRows = @($all | Where-Object { $_.build -eq 'ok' })
Write-Output ("probe-allergen-backfill: {0} spec(s) in db\recipes, {1} card(s) in db\built today, rendered to {2}{3}" -f $n, $builtNow.Count, $scratch, $(if ($runKeep) { ' (kept)' } else { ' (removed)' }))
Write-Output ("  build-card2       rendered {0} of {1}, {2} error(s)" -f $okRows.Count, $n, $buildErrors)
foreach ($e in @($all | Where-Object { $_.build -eq 'error' })) { Write-Output ("    X {0}  {1}" -f $e.slug, $e.error) }
Write-Output ("  allergen check over the REBUILT cards (of {0} rendered):" -f $okRows.Count)
$ab = Get-CountBy $okRows 'allergen'; foreach ($k in $ab.Keys) { Write-Output ("    {0,-28} {1}" -f $k, $ab[$k]) }
Write-Output ("  rebuilt card against the card in db\built today (of {0} rendered):" -f $okRows.Count)
$db = Get-CountBy $okRows 'diff'; foreach ($k in $db.Keys) { Write-Output ("    {0,-28} {1}" -f $k, $db[$k]) }
$bm = @($okRows | Where-Object { $_.built_now })
Write-Output ("  without a rebuild, publish -All would skip as UNCHANGED {0} of {1} card(s): db\built plus today's spec name and description hash equal to the journal ({2})" -f @($bm | Where-Object { $_.built_matches_journal }).Count, $bm.Count, $PublishedHashes)
Write-Output ("  every change present, per card (a card can carry several; of {0} with a card today):" -f $bm.Count)
$kc = [ordered]@{}
foreach ($r in $bm) { foreach ($k in @($r.kinds)) { if (-not $kc.Contains([string]$k)) { $kc[[string]$k] = 0 }; $kc[[string]$k]++ } }
foreach ($k in $kc.Keys) { Write-Output ("    {0,-28} {1}" -f $k, $kc[$k]) }Write-Output ("  engine\publish.ps1 -All over the rebuilt db\built, LOCAL decisions only (of {0} rendered):" -f $okRows.Count)
$pb = Get-CountBy $okRows 'publish'; foreach ($k in $pb.Keys) { Write-Output ("    {0,-28} {1}" -f $k, $pb[$k]) }
Write-Output ("  orphan cards (db\built, no spec; publish -All skips them): {0}{1}" -f $orphans.Count, $(if ($orphans.Count) { ' - ' + ($orphans -join ', ') } else { '' }))
$others = @($okRows | Where-Object { $_.diff -eq 'other' })
foreach ($o in @($others | Select-Object -First 8)) {
  Write-Output ("    OTHER {0} ({1} @ {2})" -f $o.slug, $o.diff_where, $o.diff_at)
  Write-Output ("      was: " + ($o.diff_old -replace '\s+', ' '))
  Write-Output ("      now: " + ($o.diff_new -replace '\s+', ' '))
}
if ($others.Count -gt 8) { Write-Output ("    ... and {0} more OTHER card(s); -OutFile has one row per slug" -f ($others.Count - 8)) }
$notAgree = @($okRows | Where-Object { $_.allergen -ne 'agrees' }).Count
$code = $(if ($buildErrors -gt 0 -or $notAgree -gt 0) { 1 } else { 0 })
Exit-Guard -Name 'probe-allergen-backfill' -Summary ("specs={0} rendered={1} agree={2} put={3} other={4}" -f $n, $okRows.Count, @($okRows | Where-Object { $_.allergen -eq 'agrees' }).Count, @($okRows | Where-Object { $_.publish -eq 'put' }).Count, $others.Count) -Code $code
