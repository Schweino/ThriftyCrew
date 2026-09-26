<#
  export-feed.ps1 - Builds smp-feed.json, the single public price feed the website fetches at view time.

  This is the "database" the pages read from: instead of baking prices into 113 published posts, every
  page/widget fetches this one file and shows THIS WEEK's numbers, falling back to its own baked-in
  baseline if the fetch ever fails. When a sale moves a price, this file updates and every page is current
  on its next load - no republishing.

  Sources (all already produced by the daily pipeline; no new price logic here):
    - out\recipe-costs.json      (recipe week-costs, from top5-weekly.ps1)
    - out\recipe-board.json      (recipe-ingredient board, sale-overlaid)
    - out\comparison-*.json      (weekly staples board)
    - ..\meal-prep\recipes-db.json (base servings)

  Output: out\smp-feed.json  (committed by the workflow; served publicly via Cloudflare Pages).

  A FEED THAT LOST PART OF ITSELF IS NEVER WRITTEN (2026-09-23, ops lane; founding commit 2dcbe8622, 00:24 that day,
  which served recipes={} for hours because recipe-costs.json was absent from the checkout that ran this). Two refusals,
  both BEFORE either copy of the feed is written, so a lane's write record (lib\pipeline-commit.ps1 records the bytes a
  lane wrote under public\ and the daily commit takes them as the pipeline's own) has nothing to vouch for:
    1. A MISSING OR UNREADABLE INPUT is a refusal that names the file. It is never an empty section.
    2. A SECTION THAT SHRANK by more than $script:FeedMaxDropFraction against the SERVED feed (feed.thriftycrew.com), or
       against the last committed public\smp-feed.json when the served one cannot be read, is a refusal that prints both
       counts and says which feed it compared with. Sections: ingredients, pricing_inputs, recipes (key counts) and
       board_item_count. A section that GREW is never refused.
  Both exit 3 (could not build a trustworthy feed) and leave the served feed as it was. -AcceptShrink '<reason>' is the
  loud, deliberate override for a shrink that is the decision (a catalogue retirement); it is printed with its reason.
  SCOPE: the shrink check is a count. A feed whose sections kept their size and carry wrong values is outside it.
    3. A TOP-LEVEL SECTION PRESENT IN THE SERVED FEED AND ABSENT FROM THIS ONE is a refusal that names it (2026-09-23,
       founding commit cec9779a3: the daily chain built the feed with code older than feed-everyday-ps's recipe_stats and
       shipped it over the newer served feed, so the homepage's live cheapest and range lost their source). The count
       check could not see it: recipe_stats is not a counted section. -RemoveSection 'a,b' with -RemoveReason '<why>'
       declares a removal that is the decision; the check runs on the FINAL feed, after feed-everyday-ps has added
       everyday_ps and recipe_stats in a staging copy, so nothing reaches either served path before it has passed.
  HELD RECIPES NEVER REACH THE FEED (2026-09-23): a slug in meal-prep\db\held-recipes.json is left out of `recipes`,
  so no tool (cheap-dinners, dinner-tonight, my-crew, payday-stretcher) offers a recipe that was taken down. Batch 3
  removed the 17 by hand, and the next daily export put them all back. A missing or unreadable held file is refusal 1.

  Self-test:  powershell -File grocery\export-feed.ps1 -SelfTest
#>
# gate-inputs: grocery\export-feed.ps1, grocery\cell-quarantine-lib.ps1, lib\json-io.ps1, lib\atomic-write.ps1
[CmdletBinding()]
param(
  # Every path is overridable so the self-test can run the WHOLE export in a sandbox; production passes none of them.
  [string]$DataRoot = '',
  [string]$OutDir = '',
  [string]$PublicDir = '',
  [string]$MealPrepDir = '',
  # Compare with this feed file instead of the served one (the self-test, or a deliberate offline run).
  [string]$PriorFeedPath = '',
  [string]$AcceptShrink = '',
  # A comma list (one string: -File cannot bind an array) of top-level sections whose removal is the decision, and why.
  [string]$RemoveSection = '',
  [string]$RemoveReason = '',
  [switch]$SkipEverydayPs,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Test-TcCellQuarantined: a cell guards held at its last verified published price (2026-09-21). The feed carries the
# SAME held value the board shows - no pin may overwrite it and no link rides with it, exactly as on the board.
. (Join-Path $root 'cell-quarantine-lib.ps1')
# Write-TcAtomicFile: the two served feed copies are replaced through it (2026-09-24, see the write at the end).
. (Join-Path (Split-Path $root -Parent) 'lib\atomic-write.ps1')

# THE SHRINK BAR: 10%, THE FIRST PLAUSIBLE NUMBER, NOT THE SURVIVOR OF A SWEEP. Measured 2026-09-23 over the 40 newest
# committed public\smp-feed.json (a2e167727 .. 9827b3c77, 39 consecutive pairs): leaving out the founding pair
# (recipes 583 -> 0), the largest one-step fall in any section was 3.5% (board_item_count 573 -> 553), with ingredients
# 668 -> 648 (3.0%) and a recipe hold 583 -> 566 (2.9%). 10% is about three times the largest normal fall and still
# lets a hold of up to 58 recipes through. What it does when the producer STOPS: nothing, because it only runs when
# export-feed runs; a feed that stops refreshing is feed-freshness.ps1's question, not this one's.
$script:FeedMaxDropFraction = 0.10
$script:FeedServedUrl = 'https://feed.thriftycrew.com/smp-feed.json'
$script:FeedSections = @('ingredients', 'pricing_inputs', 'recipes', 'board_item_count')

function Get-TcFeedSectionSize {
  <# The size of one top-level section: the key count of a map (an ordered dictionary as built here, or a PSCustomObject
     as read back), the value of a count field. An ABSENT section is 0, never skipped: absence is the loudest shrink. #>
  param($Doc, [string]$Name)
  if ($null -eq $Doc) { return 0 }
  $v = $null
  if ($Doc -is [Collections.IDictionary]) { if ($Doc.Contains($Name)) { $v = $Doc[$Name] } }
  elseif ($Doc.PSObject.Properties[$Name]) { $v = $Doc.PSObject.Properties[$Name].Value }
  if ($null -eq $v) { return 0 }
  if ($v -is [Collections.IDictionary]) { return [int]$v.Count }
  if ($v -is [ValueType]) { return [int]$v }
  return [int]@($v.PSObject.Properties).Count
}

function Test-TcFeedShrink {
  <# Compare every section of the NEW feed with the PRIOR one. Returns Findings (the sections that fell past the bar)
     and Lines (one per section, both counts, for the log). A prior section of 0 cannot fall and is said so. #>
  param($New, $Prior, [double]$MaxDrop)
  $findings = New-Object Collections.ArrayList
  $lines = New-Object Collections.ArrayList
  foreach ($s in $script:FeedSections) {
    $p = Get-TcFeedSectionSize $Prior $s
    $n = Get-TcFeedSectionSize $New $s
    if ($p -le 0) { [void]$lines.Add(('{0} {1} (the prior feed had none, so nothing to fall from)' -f $s, $n)); continue }
    $drop = ($p - $n) / [double]$p
    $l = ('{0} {1} -> {2} ({3:+0.0;-0.0;0.0}%)' -f $s, $p, $n, (-100.0 * $drop))
    [void]$lines.Add($l)
    if ($drop -gt $MaxDrop) { [void]$findings.Add($l) }
  }
  return [pscustomobject]@{ Findings = @($findings); Lines = @($lines) }
}

function Get-TcFeedTopNames {
  <# The top-level key names of a feed doc: an ordered dictionary as built here, or a PSCustomObject as read back. #>
  param($Doc)
  if ($null -eq $Doc) { return @() }
  if ($Doc -is [Collections.IDictionary]) { return @($Doc.Keys | ForEach-Object { [string]$_ }) }
  return @($Doc.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-TcFeedMissingSections {
  <# Every top-level section the PRIOR feed carries and the NEW one does not, minus the declared removals. Ordinal
     compare: a section is a JSON key, and the JSON reader of every consumer is case-sensitive. #>
  param($New, $Prior, [string[]]$Declared = @())
  $have = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($n in (Get-TcFeedTopNames $New)) { [void]$have.Add($n) }
  $decl = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($d in $Declared) { if ($d) { [void]$decl.Add($d) } }
  $missing = New-Object Collections.ArrayList
  foreach ($p in (Get-TcFeedTopNames $Prior)) { if (-not $have.Contains($p) -and -not $decl.Contains($p)) { [void]$missing.Add($p) } }
  return ,@($missing)
}

function Get-TcHeldSlugs {
  <# The held slugs from meal-prep\db\held-recipes.json ({ held: [ { slug } ] }). Throws on a missing or unreadable file,
     so the caller refuses by name rather than serving a held recipe. #>
  param([string]$Path)
  $set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $doc = Read-JsonFile $Path
  if ($null -eq $doc -or -not $doc.PSObject.Properties['held']) { throw ($Path + ' has no held list') }
  foreach ($h in @($doc.held)) { if ($h -and $h.slug) { [void]$set.Add([string]$h.slug) } }
  return ,$set
}

. (Join-Path $PSScriptRoot 'feed-served-lib.ps1')   # Get-TcServedFeedDoc: the one served-feed read
function Get-TcPriorFeed {
  <# The feed this build is compared with: -PriorFeedPath when given, else the SERVED feed, else the last committed
     public\smp-feed.json. Doc is $null when none could be read, and Source says which one was used or why none was. #>
  param([string]$Path, [string]$Url, [string]$Repo)
  if ($Path) {
    try { return [pscustomobject]@{ Doc = (Read-JsonFile $Path); Source = ('the feed file ' + $Path) } }
    catch { return [pscustomobject]@{ Doc = $null; Source = ('the feed file ' + $Path + ' could not be read: ' + $_.Exception.Message) } }
  }
  # THE ONE FETCH PATH for a served feed file is grocery\feed-served-lib.ps1 (2026-09-23): the fallback stamp reads the
  # same served feed, and two copies of a fetch drift. Same answer as before: served, else HEAD:public/smp-feed.json.
  return (Get-TcServedFeedDoc -Repo $Repo -Refs @('HEAD') -Url $Url)
}

if ($SelfTest) {
  $script:stFail = 0; $script:stCases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function Test-EfCase([string]$Label, [bool]$Cond, [string]$Got) {
    $script:stCases++
    if ($Cond) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:stFail++ }
  }
  function New-EfFeed([int]$Ing, [int]$Pin, [int]$Rec, [int]$Board) {
    $f = [ordered]@{ ingredients = [ordered]@{}; pricing_inputs = [ordered]@{}; recipes = [ordered]@{}; board_item_count = $Board }
    for ($i = 0; $i -lt $Ing; $i++) { $f.ingredients[('i' + $i)] = 1 }
    for ($i = 0; $i -lt $Pin; $i++) { $f.pricing_inputs[('i' + $i)] = 1 }
    for ($i = 0; $i -lt $Rec; $i++) { $f.recipes[('r' + $i)] = 1 }
    return $f
  }
  $bar = $script:FeedMaxDropFraction
  # The founding bug, 2dcbe8622: every section as served except recipes, which was {}.
  $served = (New-EfFeed 668 668 583 572 | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json   # read back, as the served feed is
  $r1 = Test-TcFeedShrink (New-EfFeed 668 668 0 572) $served $bar
  Test-EfCase ($kMF + '  the empty recipes map of 2dcbe8622 (583 -> 0) is refused, and the finding names recipes') (@($r1.Findings).Count -eq 1 -and (@($r1.Findings)[0] -match '^recipes 583 -> 0')) (@($r1.Findings) -join ' | ')
  $r2 = Test-TcFeedShrink (New-EfFeed 334 668 583 572) $served $bar
  Test-EfCase ($kMF + '  a 50% drop in ingredients (668 -> 334) is refused') (@($r2.Findings).Count -eq 1 -and (@($r2.Findings)[0] -match '^ingredients')) (@($r2.Findings) -join ' | ')
  $r3 = Test-TcFeedShrink ([ordered]@{ ingredients = (New-EfFeed 668 0 0 0).ingredients; recipes = (New-EfFeed 0 0 583 0).recipes; board_item_count = 572 }) $served $bar
  Test-EfCase ($kMF + '  a section ABSENT from the new feed (pricing_inputs) is a fall to zero, never skipped') (@($r3.Findings).Count -eq 1 -and (@($r3.Findings)[0] -match '^pricing_inputs 668 -> 0')) (@($r3.Findings) -join ' | ')
  # A normal day, measured: 469873e4d -> 6053db0fa (ingredients 668 -> 648, board 573 -> 553) and the 9827b3c77 recipe hold (583 -> 566).
  $prevDay = (New-EfFeed 668 668 583 573 | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json
  $r4 = Test-TcFeedShrink (New-EfFeed 648 648 566 553) $prevDay $bar
  Test-EfCase ($kMNF + '  a normal day''s change (the largest measured falls, 3.0% / 2.9% / 3.5%) is not refused') (@($r4.Findings).Count -eq 0) (@($r4.Findings) -join ' | ')
  # THE BAR (10%), AT it and one row PAST it, on a prior of 200 so both sides are whole rows.
  $p200 = New-EfFeed 200 200 200 200
  $r5 = Test-TcFeedShrink (New-EfFeed 180 200 200 200) $p200 $bar
  Test-EfCase ($kMNF + '  a fall of exactly the 10% bar (200 -> 180) is not refused') (@($r5.Findings).Count -eq 0) (@($r5.Findings) -join ' | ')
  $r6 = Test-TcFeedShrink (New-EfFeed 179 200 200 200) $p200 $bar
  Test-EfCase ($kMF + '  one row past the 10% bar (200 -> 179) is refused') (@($r6.Findings).Count -eq 1) (@($r6.Findings) -join ' | ')
  $r7 = Test-TcFeedShrink (New-EfFeed 900 900 900 900) $p200 $bar
  Test-EfCase ($kMNF + '  a section that GREW is never refused') (@($r7.Findings).Count -eq 0) (@($r7.Findings) -join ' | ')
  # REFUSAL 3, pure. The founding shape, cec9779a3: the served feed carried recipe_stats and the stale-code build did not.
  $servedStats = ('{"schema":2,"generated":"2026-09-23T00:21:31","week_of":"2026-09-23","ingredients":{},"pricing_inputs":{},"recipes":{},"board_item_count":1,' + '"recipe_stats":{"n":566,"p25":2.91,"p75":4.03}}') | ConvertFrom-Json
  $staleBuild = [ordered]@{ schema = 2; generated = 'x'; week_of = 'y'; ingredients = @{}; pricing_inputs = @{}; recipes = @{}; board_item_count = 1 }
  $m1 = Get-TcFeedMissingSections $staleBuild $servedStats @()
  Test-EfCase ($kMF + '  the recipe_stats that cec9779a3 dropped is named as absent (a section, not a count, so the shrink bar never saw it)') (@($m1).Count -eq 1 -and @($m1)[0] -ceq 'recipe_stats') (@($m1) -join ',')
  $m2 = Get-TcFeedMissingSections $staleBuild $servedStats @('recipe_stats')
  Test-EfCase ($kMNF + '  a removal declared with -RemoveSection is not refused') (@($m2).Count -eq 0) (@($m2) -join ',')
  $fullBuild = [ordered]@{ schema = 2; generated = 'x'; week_of = 'y'; ingredients = @{}; pricing_inputs = @{}; recipes = @{}; board_item_count = 1; recipe_stats = @{ n = 1 }; new_section = 1 }
  $m3 = Get-TcFeedMissingSections $fullBuild $servedStats @()
  Test-EfCase ($kMNF + '  a build carrying every served section plus a NEW one is not refused') (@($m3).Count -eq 0) (@($m3) -join ',')

  # ---- the WHOLE export, run as a child in a sandbox: the refusals stop the WRITE, and a sound build still writes ----
  $sb = Join-Path $env:TEMP ('tc-ef-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $sb
  try {
    $dG = Join-Path $sb 'grocery'; $dO = Join-Path $sb 'out'; $dP = Join-Path $sb 'public'; $dM = Join-Path $sb 'meal-prep'
    foreach ($d in @($dG, $dO, $dP, $dM)) { $null = New-Item -ItemType Directory -Force -ErrorAction Stop $d }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $dG 'product-urls.json'), '{"items":{}}', $utf8)
    $cmp = '{"week_of":"2026-09-22","comparison":[' + ((0..9 | ForEach-Object { '{"id":"c' + $_ + '","unit":"lb","stores":[{"store":"Aldi","per_unit":1.5,"type":"everyday","size":"2 lb","ad":"$3.00"}]}' }) -join ',') + ']}'
    [IO.File]::WriteAllText((Join-Path $dO 'comparison-2026-09-22.json'), $cmp, $utf8)
    [IO.File]::WriteAllText((Join-Path $dO 'recipe-board.json'), '{"comparison":[]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $dM 'recipes-db.json'), '{"recipes":[]}', $utf8)
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $dM 'db')
    $heldPath = Join-Path $dM 'db\held-recipes.json'
    [IO.File]::WriteAllText($heldPath, '{"held":[]}', $utf8)
    $mkCosts = { param([int]$n) '{"recipes":[' + ((0..($n - 1) | ForEach-Object { '{"slug":"s' + $_ + '","name":"S","week_cost":10,"per_serving":1,"calories":500,"sale_items":[]}' }) -join ',') + ']}' }
    $priorText = (New-EfFeed 10 10 10 10 | ConvertTo-Json -Depth 4 -Compress)
    $pubFeed = Join-Path $dP 'smp-feed.json'; $outFeed = Join-Path $dO 'smp-feed.json'
    $runChild = {
      param([string]$Prior = $priorText, [string[]]$Extra = @())
      [IO.File]::WriteAllText($pubFeed, $Prior, $utf8)
      if (Test-Path -LiteralPath $outFeed) { Remove-Item -LiteralPath $outFeed -Force }
      $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DataRoot $dG -OutDir $dO -PublicDir $dP -MealPrepDir $dM -PriorFeedPath $pubFeed -SkipEverydayPs @Extra)
      return [pscustomobject]@{ Rc = $LASTEXITCODE; Text = ($o -join "`n"); PubSame = ([IO.File]::ReadAllText($pubFeed) -ceq $Prior); OutWritten = (Test-Path -LiteralPath $outFeed) }
    }
    # MUST FIRE: the founding shape, recipe-costs.json absent from the checkout.
    $c1 = & $runChild
    Test-EfCase ($kMF + '  a missing recipe-costs.json is refused BY NAME (exit 3) and neither copy of the feed is written') ($c1.Rc -eq 3 -and $c1.Text -match 'recipe-costs\.json' -and $c1.PubSame -and -not $c1.OutWritten) ("rc={0} pubSame={1} outWritten={2} text={3}" -f $c1.Rc, $c1.PubSame, $c1.OutWritten, $c1.Text)
    # MUST FIRE: an input whose absence USED to be silent (recipes-db.json gave every recipe a guessed 14 servings), with
    # recipe-costs present, so only the missing-input refusal can catch it.
    [IO.File]::WriteAllText((Join-Path $dO 'recipe-costs.json'), (& $mkCosts 10), $utf8)
    Remove-Item -LiteralPath (Join-Path $dM 'recipes-db.json') -Force
    $c1b = & $runChild
    Test-EfCase ($kMF + '  a missing recipes-db.json is refused BY NAME (exit 3) rather than serving guessed servings, and nothing is written') ($c1b.Rc -eq 3 -and $c1b.Text -match 'recipes-db\.json' -and $c1b.PubSame -and -not $c1b.OutWritten) ("rc={0} pubSame={1} outWritten={2} text={3}" -f $c1b.Rc, $c1b.PubSame, $c1b.OutWritten, $c1b.Text)
    [IO.File]::WriteAllText((Join-Path $dM 'recipes-db.json'), '{"recipes":[]}', $utf8)
    # MUST FIRE: every input present, recipes half of what is served.
    [IO.File]::WriteAllText((Join-Path $dO 'recipe-costs.json'), (& $mkCosts 5), $utf8)
    $c2 = & $runChild
    Test-EfCase ($kMF + '  a 50% fall in recipes (10 -> 5) is refused (exit 3), names what it compared with, and writes nothing') ($c2.Rc -eq 3 -and $c2.Text -match 'recipes 10 -> 5' -and $c2.Text -match 'compared with the feed file' -and $c2.PubSame -and -not $c2.OutWritten) ("rc={0} pubSame={1} outWritten={2} text={3}" -f $c2.Rc, $c2.PubSame, $c2.OutWritten, $c2.Text)
    # CLEAN TWIN: the same sandbox with a sound recipe-costs.json exports and writes both copies.
    [IO.File]::WriteAllText((Join-Path $dO 'recipe-costs.json'), (& $mkCosts 10), $utf8)
    $c3 = & $runChild
    $written = $null; try { $written = [IO.File]::ReadAllText($pubFeed) | ConvertFrom-Json } catch {}
    Test-EfCase ($kCT + '  a sound build over the same inputs still exports: exit 0, both copies written, 10 recipes and 10 ingredients served') ($c3.Rc -eq 0 -and $c3.OutWritten -and $null -ne $written -and (Get-TcFeedSectionSize $written 'recipes') -eq 10 -and (Get-TcFeedSectionSize $written 'ingredients') -eq 10) ("rc={0} outWritten={1} text={2}" -f $c3.Rc, $c3.OutWritten, $c3.Text)
    # REFUSAL 3, end to end: the served feed carries recipe_stats and this build (no everyday pass) cannot.
    $priorStats = $priorText.TrimEnd('}') + ',"recipe_stats":{"n":10,"p25":1,"p75":2}}'
    $c4 = & $runChild $priorStats
    Test-EfCase ($kMF + '  a build missing the served recipe_stats section is refused (exit 3) BY NAME and writes nothing') ($c4.Rc -eq 3 -and $c4.Text -match 'ABSENT from this build: recipe_stats' -and $c4.PubSame -and -not $c4.OutWritten) ("rc={0} pubSame={1} outWritten={2} text={3}" -f $c4.Rc, $c4.PubSame, $c4.OutWritten, $c4.Text)
    $c5 = & $runChild $priorStats @('-RemoveSection', 'recipe_stats', '-RemoveReason', 'self-test declared removal')
    Test-EfCase ($kCT + '  the same build with the removal DECLARED exports (exit 0) and prints the declaration') ($c5.Rc -eq 0 -and $c5.OutWritten -and $c5.Text -match 'SECTION REMOVAL DECLARED\s+\*\*\* recipe_stats') ("rc={0} outWritten={1} text={2}" -f $c5.Rc, $c5.OutWritten, $c5.Text)
    # HELD RECIPES: costs list 11, s10 is held, so the feed carries 10 and never s10.
    [IO.File]::WriteAllText((Join-Path $dO 'recipe-costs.json'), (& $mkCosts 11), $utf8)
    [IO.File]::WriteAllText($heldPath, '{"held":[{"slug":"s10","reason":"self-test"}]}', $utf8)
    $c6 = & $runChild
    $w6 = $null; try { $w6 = [IO.File]::ReadAllText($pubFeed) | ConvertFrom-Json } catch {}
    Test-EfCase ($kMF + '  a HELD recipe (s10) never reaches the feed: 11 costed, 10 served, s10 absent, and the log names it') ($c6.Rc -eq 0 -and $null -ne $w6 -and (Get-TcFeedSectionSize $w6 'recipes') -eq 10 -and -not $w6.recipes.PSObject.Properties['s10'] -and $null -ne $w6.recipes.PSObject.Properties['s9'] -and $c6.Text -match '1 held recipe\(s\) left out of recipes .*: s10') ("rc={0} text={1}" -f $c6.Rc, $c6.Text)
    Remove-Item -LiteralPath $heldPath -Force
    $c7 = & $runChild
    Test-EfCase ($kMF + '  a missing held-recipes.json is refused BY NAME (exit 3) rather than serving a held recipe, and nothing is written') ($c7.Rc -eq 3 -and $c7.Text -match 'held-recipes\.json' -and $c7.PubSame -and -not $c7.OutWritten) ("rc={0} pubSame={1} outWritten={2} text={3}" -f $c7.Rc, $c7.PubSame, $c7.OutWritten, $c7.Text)
    [IO.File]::WriteAllText($heldPath, '{"held":[]}', $utf8)

    # ---- A HELD FEED FILE (2026-09-24, triage 0f7b37). The quarantine re-export threw between its two bare WriteAllText
    # calls (out\ replaced, public\ not, exit 1) and the chain logged an info line as the reason. The holder here is a
    # Get-Content-shaped handle (read, shared ReadWrite, no Delete) in THIS process, which is another process to the child.
    $runHeld = {
      param([string]$HoldPath, [switch]$Release)
      [IO.File]::WriteAllText($pubFeed, $priorText, $utf8)
      if (Test-Path -LiteralPath $outFeed) { Remove-Item -LiteralPath $outFeed -Force }
      if ($HoldPath -eq $outFeed) { [IO.File]::WriteAllText($outFeed, 'OLD-OUT', $utf8) }
      $sig = Join-Path $sb ('release-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
      # -Release: let go once the child has staged its temp file (so it met the holder), inside the retry budget.
      # Otherwise: hold until the parent signals after the child EXITED, which is past any budget by construction.
      $h = if ($Release) { Start-TcFileHold -Path $HoldPath -UntilFile ($HoldPath + '.tmp') -GraceMs 150 } else { Start-TcFileHold -Path $HoldPath -UntilFile $sig }
      $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DataRoot $dG -OutDir $dO -PublicDir $dP -MealPrepDir $dM -PriorFeedPath $pubFeed -SkipEverydayPs)
      $rc = $LASTEXITCODE
      [IO.File]::WriteAllText($sig, 'x'); Stop-TcFileHold $h
      $pb = [IO.File]::ReadAllBytes($pubFeed)
      $ob = $null; if (Test-Path -LiteralPath $outFeed) { $ob = [IO.File]::ReadAllBytes($outFeed) }
      return [pscustomobject]@{ Rc = $rc; Text = ($o -join "`n"); Opened = $h.Opened; Saw = $h.Saw; PubSame = ([IO.File]::ReadAllText($pubFeed) -ceq $priorText); PubBytes = $pb; OutBytes = $ob }
    }
    # MUST FIRE: public\ held past the whole retry budget -> a NAMED FAILED line, exit 3, and out\ never written.
    $c8 = & $runHeld $pubFeed
    Test-EfCase ($kMF + '  public\smp-feed.json held past the retry budget: exit 3, a named FAILED line with the exception, served feed intact, out\ NOT written') ($c8.Opened -and $c8.Rc -eq 3 -and $c8.Text -match 'export-feed: FAILED writing \S*public\\smp-feed\.json: Write-TcAtomicFile: could not replace' -and $c8.PubSame -and $null -eq $c8.OutBytes) ("opened={0} rc={1} pubSame={2} outWritten={3} text={4}" -f $c8.Opened, $c8.Rc, $c8.PubSame, ($null -ne $c8.OutBytes), $c8.Text)
    # MUST FIRE: the SECOND write fails after the first landed (the 09-24 shape, order now reversed): exit 3, and the line
    # says the served copy WAS rewritten rather than claiming neither was.
    $c9 = & $runHeld $outFeed
    $c9Out = if ($c9.OutBytes) { [Text.Encoding]::UTF8.GetString($c9.OutBytes) } else { '' }
    Test-EfCase ($kMF + '  out\smp-feed.json held after public\ landed: exit 3, FAILED names out\ and says the served copy WAS rewritten, out\ keeps its old bytes') ($c9.Opened -and $c9.Rc -eq 3 -and $c9.Text -match 'export-feed: FAILED writing \S*out\\smp-feed\.json: .*The served copy .* WAS rewritten' -and -not $c9.PubSame -and $c9Out -ceq 'OLD-OUT') ("opened={0} rc={1} pubSame={2} out={3} text={4}" -f $c9.Opened, $c9.Rc, $c9.PubSame, $c9Out, $c9.Text)
    # CLEAN TWIN: the same holder on public\, released inside the budget once the child has staged its temp file: exit 0,
    # both copies written, public\ BOM-less, out\ the SAME bytes behind a BOM (the bytes the bare WriteAllText wrote).
    $c10 = & $runHeld $pubFeed -Release
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $pubNoBom = ($c10.PubBytes.Length -ge 3 -and -not ($c10.PubBytes[0] -eq 0xEF -and $c10.PubBytes[1] -eq 0xBB -and $c10.PubBytes[2] -eq 0xBF))
    $outIsBomPlusPub = ($null -ne $c10.OutBytes -and $c10.OutBytes.Length -eq $c10.PubBytes.Length + 3 -and [Convert]::ToBase64String($c10.OutBytes) -ceq [Convert]::ToBase64String([byte[]]($bom + $c10.PubBytes)))
    $pubLastByte = if ($c10.PubBytes.Length) { $c10.PubBytes[$c10.PubBytes.Length - 1] } else { -1 }
    Test-EfCase ($kCT + '  the holder released inside the budget: exit 0, public\ BOM-less with no appended newline, out\ byte-identical behind a BOM') ($c10.Opened -and $c10.Saw -and $c10.Rc -eq 0 -and $pubNoBom -and $pubLastByte -eq 0x7D -and $outIsBomPlusPub) ("opened={0} saw={1} rc={2} pubNoBom={3} lastByte={4} outIsBomPlusPub={5} text={6}" -f $c10.Opened, $c10.Saw, $c10.Rc, $pubNoBom, $pubLastByte, $outIsBomPlusPub, $c10.Text)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 21
  if ($script:stCases -ne $want) { Write-Output ('FAIL  the suite ran {0} case(s), expected {1}' -f $script:stCases, $want); $script:stFail++ }
  if ($script:stFail) { Write-Output ('export-feed self-test FAIL: {0} of {1} case(s)' -f $script:stFail, $script:stCases); exit 1 }
  Write-Output ('export-feed self-test PASS: {0} of {0} cases - led by the empty recipes map of 2dcbe8622 being refused before either copy of the feed is written' -f $script:stCases)
  exit 0
}

$dataRoot = if ($DataRoot) { $DataRoot } else { $root }
$out  = if ($OutDir) { $OutDir } else { Join-Path $root 'out' }
$mp   = if ($MealPrepDir) { $MealPrepDir } else { Join-Path (Split-Path $root -Parent) 'meal-prep' }
$pub  = if ($PublicDir) { $PublicDir } else { Join-Path (Split-Path $root -Parent) 'public' }

# ---- REFUSAL 1: every input a section is built from must exist. A missing one is named, never an empty section. ----
$missing = New-Object Collections.ArrayList
foreach ($need in @(
    @{ p = (Join-Path $dataRoot 'product-urls.json'); feeds = 'the See-item links on every ingredient' },
    @{ p = (Join-Path $out 'recipe-costs.json'); feeds = 'recipes' },
    @{ p = (Join-Path $out 'recipe-board.json'); feeds = 'the recipe-only ingredients and pricing_inputs' },
    @{ p = (Join-Path $mp 'recipes-db.json'); feeds = 'every recipe''s base servings' },
    @{ p = (Join-Path $mp 'db\held-recipes.json'); feeds = 'the held recipes left out of recipes' })) {
  if (-not (Test-Path -LiteralPath $need.p)) { [void]$missing.Add(('{0} (feeds {1})' -f $need.p, $need.feeds)) }
}
if (-not (Get-ChildItem (Join-Path $out 'comparison-*.json') -ErrorAction SilentlyContinue | Select-Object -First 1)) { [void]$missing.Add((Join-Path $out 'comparison-*.json') + ' (feeds ingredients, pricing_inputs, week_of and board_item_count)') }
if ($missing.Count) {
  Write-Output ('export-feed: REFUSED - {0} input file(s) missing, so the feed would carry an emptied section: {1}. Nothing was written; the served feed stands.' -f $missing.Count, (@($missing) -join '; '))
  exit 3
}

# ---- ingredients: cheapest verified price per board commodity id (both boards) ----
# durable product links: id -> store -> url (so the feed can point at the exact cheapest item)
$purl = @{}
try {
  $pd = (Read-JsonFile (Join-Path $dataRoot 'product-urls.json')).items
  foreach ($p in $pd.PSObject.Properties) {
    $m = @{}
    foreach ($sp in $p.Value.PSObject.Properties) { if ($sp.Name -ne 'commodity' -and $sp.Value -and $sp.Value.url) { $m[[string]$sp.Name] = [string]$sp.Value.url } }
    $purl[[string]$p.Name] = $m
  }
} catch {
  # UNREADABLE IS MISSING (2026-09-23): this catch used to be empty, so a damaged file shipped a feed with no links at all.
  Write-Output ('export-feed: REFUSED - ' + (Join-Path $dataRoot 'product-urls.json') + ' could not be read (' + $_.Exception.Message + '), so every ingredient would lose its See-item link. Nothing was written; the served feed stands.')
  exit 3
}
# sale windows: id|store -> sale_end, so the feed can carry "sale ends <date>" for the cheapest chip.
# sale-windows.json is gitignored + regenerated daily on both local and cloud (check-ad-cycles runs
# build-sale-windows BEFORE export-feed) - if it is missing we just emit no sale_end fields.
$saleEnd = @{}
try {
  $sw = Read-JsonFile (Join-Path $dataRoot 'sale-windows.json')
  $todayS = (Get-Date).ToString('yyyy-MM-dd')
  foreach ($w in $sw.windows) {
    if (-not $w.sale_end) { continue }
    if ([string]$w.sale_end -lt $todayS) { continue }   # expired window: no badge
    # A DATE WE CHOSE IS NOT A DATE THE STORE STATED (2026-09-26, design\PLAN-board-clock-2026-09-26.md W8). Walmart,
    # Sam's and Fareway publish no rollback end, so compare-deals dates a markdown 30 days from first detection
    # (ad_basis 'ttl'). That end drives the next-day re-price; printed as "sale ends <date>" it would be a date no
    # store ever gave a reader - on 2026-09-26 37 Fareway sale cells carried one. Such a window gets no badge.
    if ($w.PSObject.Properties['end_basis'] -and [string]$w.end_basis -eq 'ttl') { continue }
    $saleEnd[([string]$w.id + '|' + [string]$w.store)] = [string]$w.sale_end
  }
} catch {}

# board-price overrides (same file the page build + audit use): pin an EVERYDAY cell to the verified per-unit
# of the product its link opens, so the PUBLIC feed (CF Worker -> 113 recipe widgets) never serves a stale
# board price either. Sales are never overridden.
$ovr = @{}
$ovrFile = Join-Path $dataRoot 'board-price-overrides.json'
if (Test-Path $ovrFile) { try { foreach ($c in (Read-JsonFile $ovrFile).cells) { $k=[string]$c.id; if (-not $ovr.ContainsKey($k)) { $ovr[$k]=@{} }; $ovr[$k][[string]$c.store]=[double]$c.per_unit } } catch {} }

$ing = [ordered]@{}

# ---- pricing_inputs: the WHOLE-PACKAGE basis the recipe cards price against ----
# WHY THIS EXISTS (2026-08-15). The 544 recipe cards used to fetch this from the V3 platform's
# /api/v2/recipe-feed/<slug>. That platform was deleted on 2026-08-14; the endpoint still answers from a
# STORED release, so it returns 200 for anything that existed when the last release was minted and 404 for
# everything newer, and its prices are frozen at whatever that release captured (butter served $3.99 against
# a real $2.555). Nothing in this repo produces it and nobody here can regenerate it. The cards now read the
# feed we DO own, and this block is the one thing that feed was missing.
#
# A per-unit price cannot answer the card's question. The card prices whole packages, because you cannot buy
# 7.5 tbsp of vinegar, so it needs three more facts per commodity: how big the package is, what the package
# costs, and whether the item is sold loose by weight instead of in a package at all. All three are already
# in the board rows this pipeline produces:
#   basis "size 4 lb"     -> packageBasisUnits 4, ALREADY IN THE ROW'S OWN UNIT (measured 2026-08-15: on
#                            every one of the 2,428 weekly cells where ad and basis are both present, the
#                            two reproduce the row's per_unit within 2%. Zero disagreements.)
#   basis "per-lb marker" -> variableWeight: a meat-counter price, so the card charges the exact amount used
#                            instead of rounding up to a package that does not exist
#   ad    "$10.22"        -> purchasePriceMinor 1022
# A cell with none of that carries perUnitMicros only. The card then falls back to the recipe's OWN authored
# package size (pkg_g/gpu, which every spec already has) rather than this script inventing a package size -
# a guessed package size is a wrong PRICE, which is worse than an honest per-unit one.
$pin = [ordered]@{}
$pinDiverged = 0        # cells where the shelf tag did not divide into its own per-unit price
$pinNoBasis  = 0        # cells shipped per-unit-only, for the card's authored-package fallback

# Size-string units, normalised. Only what the boards actually emit; an unrecognised token is refused, not guessed.
$UNIT_ALIAS = @{
  'oz'='oz'; 'ounce'='oz'; 'ounces'='oz'
  'lb'='lb'; 'lbs'='lb'; 'pound'='lb'; 'pounds'='lb'
  'floz'='floz'; 'fl oz'='floz'; 'fluid ounce'='floz'; 'fluid ounces'='floz'
  'ct'='each'; 'count'='each'; 'ea'='each'; 'each'='each'; 'pk'='each'; 'pack'='each'
  'g'='g'; 'gram'='g'; 'grams'='g'; 'kg'='kg'
  'gal'='gal'; 'gallon'='gal'; 'qt'='qt'; 'quart'='qt'; 'pt'='pt'; 'pint'='pt'
  'l'='l'; 'liter'='l'; 'litre'='l'; 'ml'='ml'
}
function ConvertTo-RowUnit([double]$mag, [string]$from, [string]$to) {
  if ($from -eq $to) { return $mag }
  switch ("$from>$to") {
    'oz>lb'    { return $mag / 16 }
    'lb>oz'    { return $mag * 16 }
    'g>lb'     { return $mag / 453.59237 }
    'g>oz'     { return $mag / 28.349523 }
    'kg>lb'    { return $mag * 2.2046226 }
    'kg>oz'    { return $mag * 35.273962 }
    'gal>floz' { return $mag * 128 }
    'qt>floz'  { return $mag * 32 }
    'pt>floz'  { return $mag * 16 }
    'l>floz'   { return $mag * 33.814023 }
    'ml>floz'  { return $mag / 29.573530 }
    # THE BOARD'S OWN CONVENTION, MIRRORED - not a new one. On a row already established as a liquid (unit
    # floz), a package labelled "32 oz" is 32 fluid ounces, which is exactly what the board's own `basis`
    # field emits for those cells ("size 32 floz" from size "32 oz"). Allowed in this one direction only:
    # any other weight/volume crossing is refused below, because guessing one is a wrong price.
    'oz>floz'  { return $mag }
    default    { return 0 }
  }
}
function Get-PkgBasis($s, [string]$rowUnit) {
  $b = [string]$s.basis
  if ($b -match 'per-lb marker') { return @{ variable = $true;  basis = 0.0 } }
  if ($b -match 'size\s+([\d.]+)') { return @{ variable = $false; basis = [double]$Matches[1] } }   # already in the row's unit
  $sz = [string]$s.size
  if ($sz -match '^\s*([\d.]+)\s*([a-zA-Z][a-zA-Z.\s]*?)\s*$') {
    $mag = [double]$Matches[1]
    $u = ($Matches[2] -replace '\.','' -replace '\s+',' ').Trim().ToLower()
    if ($UNIT_ALIAS.ContainsKey($u)) {
      $v = ConvertTo-RowUnit $mag $UNIT_ALIAS[$u] $rowUnit
      if ($v -gt 0) { return @{ variable = $false; basis = [double]$v } }
    }
  }
  return @{ variable = $false; basis = 0.0 }
}
# PER-STORE URLS ON THE LEAN ENTRIES: MEASURED AND REJECTED (2026-08-15). Once the card picks its winning
# store by COST, a "See item" link may only be shown when it belongs to the store named on that line, and
# the feed carries a url for the per-unit winner only. The two honest options were "ship every store's url"
# or "suppress the link when the winner is not the url's store". Measured before choosing, on the real file:
#   lean (this)          733.0 KB raw / 98.8 KB gzip
#   with per-store urls 1026.9 KB raw / 158.6 KB gzip     (+294 KB raw, +59.6 KB gzip)
# +59.6 KB gzipped on a file EVERY recipe page fetches, to keep a link on lines that already show the
# store name and per-unit price, is not worth it - the threshold set when this was planned was about 20 KB.
# So the card suppresses the link instead (tpl2-scaler-prefix.html, the `url` rule in price()). Flip this to
# $true only with a fresh measurement; the plumbing below is already correct either way.
$PER_STORE_URLS = $false
# $Full=$false emits the lean per-store shape. THE CARD READS FOUR FIELDS off a `stores` entry
# (perUnitMicros, packageBasisUnits, purchasePriceMinor, variableWeight) and takes the store NAME from the
# key and the unit from the ingredients row, so store/unit/url on those entries are pure duplication - and
# there are ~3,200 of them. Carrying them cost 428 KB on a file every recipe page fetches. `current` and
# `everyday` keep the full shape because the card does read store, unit and url off those two.
function New-PricingEntry($s, [double]$perUnit, [string]$rowUnit, [string]$id, [bool]$Full) {
  $pk = Get-PkgBasis $s $rowUnit
  $e = [ordered]@{}
  if ($Full) { $e['store'] = [string]$s.store; $e['unit'] = $rowUnit }
  $e['perUnitMicros']  = [int][math]::Round($perUnit * 1000000)
  $e['variableWeight'] = [bool]$pk.variable
  # SALE FLAG ON THE CELL ITSELF (2026-08-15). The card's everyday tab needs the cheapest NON-SALE cell,
  # and once the card picks its own winner by COST it can no longer learn sale-ness from
  # ingredients[bid].type - that field describes the per-unit winner, which is a different cell. Emitted
  # only on sale cells, so the size cost is a handful of entries rather than one per cell.
  if (([string]$s.type) -eq 'sale') { $e['sale'] = $true }
  if ([double]$pk.basis -gt 0) {
    $e['packageBasisUnits'] = [math]::Round([double]$pk.basis, 6)
    $adMinor = 0
    if (([string]$s.ad) -match '^\s*\$\s*([\d,]+(?:\.\d+)?)\s*$') { $adMinor = [int][math]::Round(([double](($Matches[1]) -replace ',','')) * 100) }
    $derived = [int][math]::Round($perUnit * [double]$pk.basis * 100)
    # SHIP THE SHELF TAG WHEN IT DIVIDES INTO ITS OWN PER-UNIT PRICE, the derived figure when it does not.
    # The card prints both on one receipt line ("$10.22" and "$2.56/lb"), so a pair that does not divide is
    # the arithmetic-fingerprint defect printed straight at the reader.
    if ($adMinor -gt 0 -and $derived -gt 0 -and ([math]::Abs($adMinor - $derived) / [double]$derived) -le 0.02) { $e['purchasePriceMinor'] = $adMinor }
    else { $e['purchasePriceMinor'] = $derived; if ($adMinor -gt 0) { $script:pinDiverged++ } }
  } else { $script:pinNoBasis++ }
  if (($Full -or $PER_STORE_URLS) -and -not (Test-TcCellQuarantined $s) -and $purl.ContainsKey($id) -and $purl[$id].ContainsKey([string]$s.store)) { $e['url'] = $purl[$id][[string]$s.store] }
  return $e
}

function AddBoard($rows) {
  foreach ($r in $rows) {
    $id = [string]$r.id
    # weekly board wins ties for a shared id (it carries this week's ad price); don't overwrite it with recipe floor
    if ($ing.Contains($id)) { continue }
    $rowUnit = [string]$r.unit
    $lo = $null; $los = ''; $lot = ''; $nStores = 0; $loCell = $null
    $evLo = $null; $evStore = ''; $evCell = $null
    $st = [ordered]@{}         # per-store per-unit prices (same unit as the row) - the Meal Plan Builder's store split needs these
    $pinSt = [ordered]@{}      # per-store WHOLE-PACKAGE inputs, same cells, same override, same loop
    foreach ($s in $r.stores) {
      $p = [double]$s.per_unit
      if (([string]$s.type) -eq 'everyday' -and -not (Test-TcCellQuarantined $s) -and $ovr.ContainsKey($id) -and $ovr[$id].ContainsKey([string]$s.store)) { $ov=[double]$ovr[$id][[string]$s.store]; if ($ov -gt 0) { $p = $ov } }
      if ($p -le 0) { continue }
      $nStores++; $st[[string]$s.store] = [math]::Round($p,4)
      # ONE LOOP, ONE WINNER. The cheapest chip and the card's `current` pricing basis are picked here
      # together on purpose: computed twice they can disagree, and a receipt whose store chip names a
      # different store from the price beside it is the board-match-collision class, on a recipe page.
      $pinSt[[string]$s.store] = (New-PricingEntry $s $p $rowUnit $id $false)
      if ($null -eq $lo -or $p -lt $lo) { $lo = $p; $los = [string]$s.store; $lot = [string]$s.type; $loCell = $s }
      if ((([string]$s.type) -eq 'everyday') -and ($null -eq $evLo -or $p -lt $evLo)) { $evLo = $p; $evStore = [string]$s.store; $evCell = $s }
    }
    if ($null -eq $lo) { continue }
    $u = if (-not (Test-TcCellQuarantined $loCell) -and $purl.ContainsKey($id) -and $purl[$id].ContainsKey($los)) { $purl[$id][$los] } else { '' }
    # n = how many of the 6 stores actually have a price for this ingredient - so the UI never overclaims
    # "checked at 6 stores" for an item only 1-2 stores have been priced at yet (new adds, or an item some
    # stores simply don't carry).
    $row = [ordered]@{ unit=$rowUnit; cheapest=[math]::Round($lo,4); store=$los; type=$lot; url=$u; n=$nStores; stores=$st }
    # attach the sale's end date when the winning chip IS the sale and its window is known
    if ($lot -eq 'sale') { $sk = $id + '|' + $los; if ($saleEnd.ContainsKey($sk)) { $row['sale_end'] = $saleEnd[$sk] } }
    $ing[$id] = $row
    # `everyday` is the cheapest NON-SALE cell, which is what the card's "everyday" tab means and what its
    # savings delta subtracts from. With no everyday cell at all the two tabs collapse to the same number,
    # which the card already detects and refuses to print twice under two labels.
    # The per-unit-only counter is charged once per CELL, on the lean pass above; the two full entries below
    # re-describe cells already counted, so they must not be counted again.
    $seenNoBasis = $pinNoBasis; $seenDiv = $pinDiverged
    $pinEntry = [ordered]@{ current = (New-PricingEntry $loCell $lo $rowUnit $id $true) }
    # OMIT `everyday` WHEN IT IS THE SAME CELL AS `current`, which it is for most commodities most weeks
    # (nothing is on sale, so the cheapest price IS the everyday price). The card reads
    # `inputs.everyday||inputs.current`, so the absent case is the identical case, said once instead of
    # twice. Worth 180 KB on a file every recipe page fetches.
    if ($evCell -and $evStore -ne $los) { $pinEntry['everyday'] = (New-PricingEntry $evCell $evLo $rowUnit $id $true) }
    $pinEntry['stores'] = $pinSt
    $pin[$id] = $pinEntry
    $pinNoBasis = $seenNoBasis; $pinDiverged = $seenDiv
  }
}
$cmpF = Get-ChildItem (Join-Path $out 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$weekOf = ''
if ($cmpF) { $cdoc = Read-JsonFile $cmpF.FullName; $weekOf = [string]$cdoc.week_of; AddBoard $cdoc.comparison }   # weekly first (wins ties)
$rbF = Join-Path $out 'recipe-board.json'
if (Test-Path $rbF) { AddBoard (Read-JsonFile $rbF).comparison }

# ---- recipe-namespace aliases: a de-duped commodity must still RESOLVE, even though its row is gone ----
# THE PAGE DE-DUPS, THE FEED MUST NOT (2026-08-09). recipe-overlay drops a recipe row whose commodity also
# lives on the weekly board (f8c997f4, via recipe-floor-id-map.json) - correct for the page, which was
# publishing two prices for one product. But this file is not a page, it is the priceable NAMESPACE, and
# db\ingredients.json bids, the spec scaler bids and the widget keys are all written in the RECIPE spelling
# ('93-7-ground-beef', not 'ground-beef-93-7'). When the rows went, the keys went with them: the first
# pipeline run after the de-dup could not price 297 ingredient lines across 239 recipes, took the bid FK
# down with them and left the db rebuild refused by its own constraint. The commodity did not go anywhere -
# it is on the weekly board under its other spelling at a FRESHER price, which is exactly why the recipe row
# lost the tie. So re-point the key instead of dropping it.
# UNIT IDENTITY IS THE GATE, NOT A CONVERSION. grams_per_unit downstream is expressed in the served row's
# unit; a row served per lb under a key whose consumers convert grams with an 'each' factor is a wrong
# PRICE, which is worse than the missing one. Pairs that do not share a unit are reported and stay
# unresolved until their db\ingredients.json row is re-anchored (unit AND gpu together).
$aliased = 0
$aliasSkipped = New-Object System.Collections.Generic.List[string]
$idMapFile = Join-Path $dataRoot 'recipe-floor-id-map.json'
if (Test-Path $idMapFile) {
  # the recipe row's OWN unit, read from the everyday baseline - it predates the drop, so it survives it
  $baseUnit = @{}
  $rbeF = Join-Path $out 'recipe-board-everyday.json'
  if (Test-Path $rbeF) { try { foreach ($r in (Read-JsonFile $rbeF).comparison) { $baseUnit[[string]$r.id] = [string]$r.unit } } catch {} }
  try {
    foreach ($p in ((Read-JsonFile $idMapFile).map.PSObject.Properties)) {
      $rid = [string]$p.Name; $wid = [string]$p.Value
      if ($ing.Contains($rid)) { continue }                                                    # recipe row survived
      if (-not $ing.Contains($wid)) { $aliasSkipped.Add("$rid -> $wid (twin not priced either)"); continue }
      $ru = if ($baseUnit.ContainsKey($rid)) { $baseUnit[$rid] } else { '' }
      $wu = [string]$ing[$wid].unit
      if ($ru -and $ru -ne $wu) { $aliasSkipped.Add("$rid -> $wid (unit $ru vs $wu)"); continue }
      $clone = [ordered]@{}
      foreach ($f in @($ing[$wid].Keys)) { $clone[$f] = $ing[$wid][$f] }
      $clone['alias_of'] = $wid
      $ing[$rid] = $clone
      # THE ALIAS HAS TO CARRY THE PACKAGE BASIS TOO. Aliasing only the per-unit row would leave the recipe
      # spelling priceable by every surface except the recipe cards, which is the one surface this map was
      # written for. Same unit gate above already applies: it is what makes this clone safe.
      if ($pin.Contains($wid)) { $pin[$rid] = $pin[$wid] }
      $aliased++
    }
  } catch { Write-Output 'export-feed: WARNING - recipe-floor-id-map.json unreadable; recipe-spelling bids will NOT resolve' }
} else {
  Write-Output 'export-feed: WARNING - no recipe-floor-id-map.json, so a de-duped commodity leaves its recipe-spelling bid unpriceable'
}
Write-Output ("export-feed: {0} recipe-spelling key(s) re-pointed at their weekly twin{1}" -f $aliased, $(if ($aliasSkipped.Count) { "; " + $aliasSkipped.Count + " NOT aliased: " + ($aliasSkipped -join '; ') } else { '' }))

# ---- recipes: this week's cost per slug (+ base servings for the scaler) ----
$servings = @{}
try { foreach ($r in (Read-JsonFile (Join-Path $mp 'recipes-db.json')).recipes) { $servings[[string]$r.slug] = [int]$r.servings } } catch {
  # UNREADABLE IS MISSING (2026-09-23): an empty catch here gave every recipe a guessed 14 servings.
  Write-Output ('export-feed: REFUSED - ' + (Join-Path $mp 'recipes-db.json') + ' could not be read (' + $_.Exception.Message + '), so every recipe would carry a guessed serving count. Nothing was written; the served feed stands.')
  exit 3
}
$heldF = Join-Path $mp 'db\held-recipes.json'
try { $heldSet = Get-TcHeldSlugs $heldF } catch {
  Write-Output ('export-feed: REFUSED - ' + $heldF + ' could not be read (' + $_.Exception.Message + '), so a held recipe could reach the tools. Nothing was written; the served feed stands.')
  exit 3
}
$heldOut = New-Object Collections.ArrayList
$rec = [ordered]@{}
$rcF = Join-Path $out 'recipe-costs.json'
if (Test-Path $rcF) {
  foreach ($c in (Read-JsonFile $rcF).recipes) {
    $slug = [string]$c.slug
    if ($heldSet.Contains($slug)) { [void]$heldOut.Add($slug); continue }
    $rec[$slug] = [ordered]@{
      name        = [string]$c.name
      servings    = if ($servings.ContainsKey($slug)) { $servings[$slug] } else { 14 }
      week_cost   = [double]$c.week_cost
      per_serving = [double]$c.per_serving
      calories    = [int]$c.calories
      sale_items  = @($c.sale_items)
    }
  }
}

# A FEED WITH NO RECIPES IS NEVER WRITTEN (2026-09-23). recipe-costs.json lives in grocery\out, which a worktree does not carry,
# and without it this wrote recipes={} and recipe_count 0: commit 2dcbe8622 shipped exactly that at 00:24 on 2026-09-23 and the
# cheap-dinners, dinner-tonight, my-crew and payday-stretcher tools lost every recipe cost until it was repaired. Refuse and leave
# the served feed as it was; a could-not-build is exit 3, never an empty map.
if ($rec.Count -eq 0) {
  Write-Output ("export-feed: REFUSED - no recipe costs ({0}), so the feed would carry zero recipes. Nothing was written; the served feed stands." -f $(if (Test-Path $rcF) { 'recipe-costs.json lists none' } else { 'no ' + $rcF }))
  exit 3
}
# board_item_count: distinct commodities on the WEEKLY board (the "N items at seven stores" claim on
# the homepage). Served in the feed so the tc-ic site markers stay current without any page edits.
$boardItemCount = 0
try {
  $cmpF = Get-ChildItem (Join-Path $out 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if($cmpF){ $boardItemCount = @(((Read-JsonFile $cmpF.FullName).comparison)).Count }
} catch {}
$feed = [ordered]@{
  # SCHEMA MARKER (2026-08-15). The card's everyday tab picks the cheapest NON-SALE cell by scanning
  # `stores` for entries WITHOUT a `sale` flag. Absence of flags is ambiguous between "this feed predates
  # sale flags" and "nothing is on sale this week", and the wrong reading lets a sale price masquerade as
  # an everyday one - which matters because the feed is CDN-cached (30 min, worker max-age 60), so a new
  # card can genuinely meet an old feed. The card enables the everyday scan only at schema>=2. The
  # CHEAPEST scan needs no flag and is correct against a feed of any age.
  schema      = 2
  generated   = (Get-Date).ToString('s')
  week_of     = $weekOf
  ingredient_count = $ing.Count
  recipe_count     = $rec.Count
  board_item_count = $boardItemCount
  ingredients = $ing
  pricing_inputs = $pin
  recipes     = $rec
}
Write-Output ("export-feed: pricing_inputs for {0} commodities ({1} cell(s) per-unit-only -> card uses its authored package size; {2} cell(s) where the shelf tag did not divide into its per-unit price -> derived)" -f $pin.Count, $pinNoBasis, $pinDiverged)
Write-Output ("export-feed: {0} held recipe(s) left out of recipes (of {1} listed in {2}){3}" -f $heldOut.Count, $heldSet.Count, $heldF, $(if ($heldOut.Count) { ': ' + (@($heldOut) -join ', ') } else { '' }))

# ---- THE FINAL FEED, STAGED: everyday_ps and recipe_stats are added to a staging copy, so every refusal below judges
#      exactly the bytes that would ship, and nothing reaches out\ or public\ until all of them have passed. ----
$json = $feed | ConvertTo-Json -Depth 8 -Compress
if ($SkipEverydayPs) {
  Write-Output 'export-feed: -SkipEverydayPs, so the feed is built without everyday_ps'
} else {
  $stage = Join-Path ([IO.Path]::GetTempPath()) ('tc-efs-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $stage
  try {
    $stF = Join-Path $stage 'feed.json'; $stP = Join-Path $stage 'public.json'
    [IO.File]::WriteAllText($stF, $json, (New-Object Text.UTF8Encoding($false)))
    try { & (Join-Path (Split-Path $root -Parent) 'meal-prep\pipeline\feed-everyday-ps.ps1') -FeedPath $stF -PublicPath $stP | ForEach-Object { Write-Output ("  " + $_) } } catch { Write-Output ("feed-everyday-ps threw: " + $_.Exception.Message + " - feed built without everyday_ps") }
    if (Test-Path -LiteralPath $stP) { $json = [IO.File]::ReadAllText($stP).TrimStart([char]0xFEFF) }
    else { Write-Output 'export-feed: feed-everyday-ps wrote no feed, so it is built without everyday_ps and recipe_stats' }
  } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
$final = $json | ConvertFrom-Json

# ---- REFUSAL 3: no top-level section the served feed carries may vanish from this one, unless declared. ----
$declared = @($RemoveSection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($declared.Count -and -not $RemoveReason) { Write-Output 'export-feed: REFUSED - -RemoveSection needs -RemoveReason ''<why>''. Nothing was written; the served feed stands.'; exit 3 }
$prior = Get-TcPriorFeed -Path $PriorFeedPath -Url $script:FeedServedUrl -Repo (Split-Path $root -Parent)
if ($null -ne $prior.Doc) {
  $gone = Get-TcFeedMissingSections $final $prior.Doc $declared
  if (@($gone).Count) {
    Write-Output ('export-feed: REFUSED - {0} top-level section(s) in {1} are ABSENT from this build: {2}. Nothing was written; the served feed stands. If the removal is the decision, run again with -RemoveSection ''{3}'' -RemoveReason ''<why>''.' -f @($gone).Count, $prior.Source, (@($gone) -join ', '), (@($gone) -join ','))
    exit 3
  }
  foreach ($d in $declared) { Write-Output ('export-feed: *** SECTION REMOVAL DECLARED *** ' + $d + ': ' + $RemoveReason) }
}

# ---- REFUSAL 2: no section may fall past the bar against what readers are served now. BEFORE either write. ----
if ($null -eq $prior.Doc) {
  if ($AcceptShrink) {
    Write-Output ('export-feed: *** SHRINK CHECK NOT RUN *** ' + $prior.Source + '. Writing anyway under -AcceptShrink: ' + $AcceptShrink)
  } else {
    Write-Output ('export-feed: REFUSED - COULD NOT EVALUATE the shrink check: ' + $prior.Source + ', so a fall in a section cannot be ruled out. Nothing was written; the served feed stands.')
    exit 3
  }
} else {
  $sk = Test-TcFeedShrink $final $prior.Doc $script:FeedMaxDropFraction
  Write-Output ('export-feed: shrink check compared with ' + $prior.Source + ': ' + (@($sk.Lines) -join '; '))
  if (@($sk.Findings).Count) {
    if ($AcceptShrink) {
      Write-Output ('export-feed: *** SHRINK ACCEPTED (-AcceptShrink) *** past the {0:0}% bar: {1}. Reason given: {2}' -f (100 * $script:FeedMaxDropFraction), (@($sk.Findings) -join '; '), $AcceptShrink)
    } else {
      Write-Output ('export-feed: REFUSED - {0} section(s) fell past the {1:0}% bar: {2}. Nothing was written; the served feed stands. If the fall is the decision, run again with -AcceptShrink ''<reason>''.' -f @($sk.Findings).Count, (100 * $script:FeedMaxDropFraction), (@($sk.Findings) -join '; '))
      exit 3
    }
  }
}
# Write to the repo-root public\ dir - this is the ONLY folder Cloudflare Pages serves, so nothing else
# in the repo is exposed. _headers there sets CORS + cache. Keep a copy in out\ for local inspection.
# -Compress (2026-07-26 scale hardening): the feed is fetched client-side by EVERY recipe card widget.
# Pretty-printing bloated it ~4x (973 KB raw for ~236 KB of data); at 1500 recipes that is a ~2.3 MB
# raw file JSON.parse'd on every mobile page view. Compact keeps the wire small (worker still gzips) and
# the on-device parse cheap. No consumer depends on whitespace.
# The out\ copy keeps the BOM it has always carried (feed-everyday-ps wrote it that way); public\ is BOM-less, below.
# BOM-LESS (L7, 2026-08-01). Set-Content -Encoding UTF8 emits a UTF-8 BOM in PS 5.1. Browsers strip it
# per spec so the live page was never broken - but PS 5.1's OWN ConvertFrom-Json chokes on it, which is
# how a verification pass reported this feed "malformed" when it was fine. Our own tooling has to be able
# to read what we publish.
# THROUGH Write-TcAtomicFile, PUBLIC\ FIRST (2026-09-24, triage 0f7b37). Both copies were bare WriteAllText, which
# throws when another process holds or maps the file (09-23: two chain audits died on "a user-mapped section open").
# On 09-24 the quarantine re-export threw BETWEEN the two writes: out\ replaced, public\ not, exit 1, and the chain
# logged an informational shrink line as the reason and held the whole board. Now a held file is retried, the served
# copy goes first so a failure never leaves the local copy ahead of the served one, and a write that still fails is a
# NAMED exit 3 carrying the real exception. Bytes are unchanged: -NoNewline everywhere (WriteAllText appended nothing),
# -NoBom on public\ only.
$pubFeedPath = Join-Path $pub 'smp-feed.json'; $outFeedPath = Join-Path $out 'smp-feed.json'
try {
  if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Force -Path $pub | Out-Null }
  $null = Write-TcAtomicFile -Path $pubFeedPath -Text $json -NoBom -NoNewline
} catch {
  Write-Output ('export-feed: FAILED writing ' + $pubFeedPath + ': ' + $_.Exception.Message + ' Neither copy was rewritten; the served feed stands.')
  exit 3
}
try {
  $null = Write-TcAtomicFile -Path $outFeedPath -Text $json -NoNewline
} catch {
  Write-Output ('export-feed: FAILED writing ' + $outFeedPath + ': ' + $_.Exception.Message + ' The served copy ' + $pubFeedPath + ' WAS rewritten with this build; only the local out\ copy is stale.')
  exit 3
}
Write-Output ("smp-feed.json: " + $ing.Count + " ingredients, " + $rec.Count + " recipes, week " + $weekOf + " -> out\ + public\")
# EVERYDAY_PS (2026-09-23): each recipe's per-serving price on its card's own basis, computed by running the card's own
# script against the feed, so a recipe price on an article or the homepage fills from the feed. It runs on the STAGED copy
# above, before the refusals, so the section check judges the feed that ships. Non-fatal per recipe: one it cannot price
# carries no key and its span keeps the stamped fallback.
exit 0
