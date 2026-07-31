<#
  build-rescue-worklist.ps1 - turn the board's own expiry math into a per-store SEARCH LIST a browser
  session can execute, instead of a full-list fire drill nobody has time for.

  *** WHY THIS EXISTS (measured 2026-07-31, not assumed) ***
  The four walled stores (Walmart, Sam's Club, Aldi, Fareway) are captured by hand through a browser and
  priced through compare-deals' 14-day union: every capture inside the window is unioned and the FRESHEST
  file carrying a commodity wins it OUTRIGHT. Two failure classes fall straight out of that design:

    1. THE SILENT COUNTDOWN. 21 of 436 Walmart cells traced to walmart-regular-2026-07-18.json, which left
       the window the next day. Nearly all of them were produce (cantaloupe, celery, cilantro, honeydew,
       kale, lemons, limes, mangoes, pineapple, watermelon) because Walmart RENAMES produce - "Fresh
       Pineapple" becomes "Fresh Pineapple, Each" - so newer captures missed them by name. The fullpull
       watch COUNTS those cells; nothing ever emitted "capture exactly these 21 terms today".
    2. THE NARROWER RE-CAPTURE. Aldi's 2026-07-29 pass was its biggest ever (1,664 rows vs 438) and still
       cost 7 live staple cells (bottled water, bread, canned mushrooms, gelatin, hamburger buns, hot dog
       buns, microwave popcorn), because the new pass never searched those terms and the old file holding
       them aged out the same day. audit-cell-drops reported them AFTER the loss; nothing turned them into
       a re-search list.

  Plus a standing third: ~20 Sam's cells serve from 15-18 day old captures (sams-regular-2026-07-14.json is
  an orphan nothing writes). Those are already past the union window - a permanent staleness pocket that
  should be visible every single run rather than rediscovered.

  This tool emits, per walled store, out\rescue-terms-<urlkey>.txt: the terms to search FIRST.

  *** IT IS ADVISORY AND ALWAYS WILL BE ***
  Exit 1 means "there is capture work", not "hold the board". Nothing here may gate a publish.
    0 = ran, every walled cell is healthy
    1 = ran, at least one store has a non-empty section (advisory: work exists)
    3 = COULD NOT EVALUATE - no board to read, no walled store in the registry, or cells existed and not
        one traced. The house rule: a check that examined nothing must never print ok.

  *** DELIBERATE DUPLICATION, DO NOT "FIX" IT ***
  audit-walmart-fullpull.ps1 carries its own copy of the item|price capture tracer. That is on purpose:
  it has its own fixtures and a different job (watching comprehensive-capture AGE), and a shared lib means
  one edit can blind both. Duplicated tracing is an accepted drift risk; a broken freshness watcher is not.

  Usage: build-rescue-worklist.ps1
         build-rescue-worklist.ps1 -AsOf 2026-07-31 -OutDir <dir>     (frozen fixture form)
#>
param(
  [string]$OutDir = "",            # default <root>\out; holds comparisons, captures, and the emitted lists
  [string]$StoresFile = "",        # default <OutDir>\stores.json if present, else <root>\stores.json
  [string]$TermsFile = "",         # default <OutDir>\commodity-search.json if present, else <root>\...
  [string]$PullOrderDir = "",      # default $OutDir; holds pull-order-<slug>.txt
  [int]$WindowDays = 14,           # MUST match compare-deals' union window ($WalmartMaxAgeDays/$SamsMaxAgeDays)
  [int]$ExpireWithinDays = 5,      # matches audit-walmart-fullpull's cell-expiry warn horizon
  [int]$DropLookbackDays = 7,      # comparison-diff span for the DROPPED section
  [string]$AsOf = ""               # 'yyyy-MM-dd'; default today. REQUIRED for frozen fixtures - Get-Date
)                                  # appears NOWHERE else in this file, so every age is injectable.
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $PullOrderDir) { $PullOrderDir = $OutDir }

# -OutDir WINS for the two config files, same precedence as audit-everyday-mismatch's product-urls lookup:
# $root's copy always exists, so checking it first would make every fixture read the LIVE registry and prove
# nothing. An explicit -StoresFile/-TermsFile beats both.
if (-not $StoresFile) {
  $StoresFile = Join-Path $OutDir 'stores.json'
  if (-not (Test-Path $StoresFile)) { $StoresFile = Join-Path $root 'stores.json' }
}
if (-not $TermsFile) {
  $TermsFile = Join-Path $OutDir 'commodity-search.json'
  if (-not (Test-Path $TermsFile)) { $TermsFile = Join-Path $root 'commodity-search.json' }
}
$asOfDate = if ($AsOf) { ([datetime]$AsOf).Date } else { (Get-Date).Date }

function Read-JsonFile([string]$path) {
  # [IO.File]::ReadAllText, not Get-Content: bare Get-Content reads ANSI in this tree. '' | ConvertFrom-Json
  # returns $null WITHOUT throwing in PS 5.1, so emptiness is tested here rather than trusted to an exception.
  if (-not $path -or -not (Test-Path $path)) { return $null }
  $txt = ''
  try { $txt = ((([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) + '')).Trim() } catch { return $null }
  if (-not $txt) { return $null }
  $doc = $null
  try { $doc = $txt | ConvertFrom-Json } catch { return $null }
  return $doc
}
function Get-DatedFiles([string]$glob, [datetime]$notAfter) {
  # ascending by date; files dated after $notAfter are skipped so a fixture stays frozen no matter what
  # else lands in its directory. Filenames whose date does not parse are skipped (and counted by the caller).
  $rows = New-Object System.Collections.ArrayList
  foreach ($f in (Get-ChildItem $glob -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')      # [regex]::Match, never -match: $Matches is GLOBAL
    if (-not $m.Success) { continue }
    $d = $null
    try { $d = ([datetime]$m.Groups[1].Value).Date } catch { continue }
    if ($d -gt $notAfter) { continue }
    [void]$rows.Add([pscustomobject]@{ date = $d; file = $f })
  }
  return @($rows.ToArray() | Sort-Object date)
}
function Get-CellKey([string]$item, [string]$price) {
  return (([string]$item).ToLower().Trim() + '|' + ([string]$price).Trim())
}

# ---- the registry decides which stores are walled; nothing here hardcodes a store name ----
$reg = Read-JsonFile $StoresFile
if ($null -eq $reg -or -not @($reg.stores).Count) {
  Write-Output ("rescue: COULD NOT EVALUATE - no readable store registry at " + $StoresFile)
  exit 3
}
$walled = @(@($reg.stores) | Where-Object { $_.PSObject.Properties['walled'] -and $_.walled } | Sort-Object { [int]$_.order })
if (-not $walled.Count) {
  # CONFIG, not data: the flag was dropped or renamed. Never a clean exit - this run proved nothing.
  Write-Output ("rescue: COULD NOT EVALUATE - not one store in " + $StoresFile + " carries `"walled`": true, so there is no store to build a rescue list for (the flag was renamed or dropped, which is a config error, not a healthy board)")
  exit 3
}

# ---- the board ----
$boards = @(Get-DatedFiles (Join-Path $OutDir 'comparison-*.json') $asOfDate | Where-Object { $_.file.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' })
if (-not $boards.Count) {
  Write-Output ("rescue: COULD NOT EVALUATE - no dated comparison-*.json at or before " + $asOfDate.ToString('yyyy-MM-dd') + " under " + $OutDir + ", so ZERO board cells were examined (comparison-*.json is gitignored, so a fresh clone / the cloud runner always lands here). Run compare-deals.")
  try {
    $covLib0 = Join-Path $root 'coverage-lib.ps1'
    if (Test-Path $covLib0) { . $covLib0; Write-CoverageRecord -Check 'build-rescue-worklist' -OutDir $OutDir -Eligible 0 -Examined 0 -Detail 'everyday walled-store board cells traced to a dated capture file' -Blind }
  } catch { }
  exit 3
}
$newBoardRow = $boards[$boards.Count - 1]
$cmp = Read-JsonFile $newBoardRow.file.FullName
if ($null -eq $cmp -or -not @($cmp.comparison).Count) {
  Write-Output ("rescue: COULD NOT EVALUATE - " + $newBoardRow.file.Name + " parsed to no comparison rows, so ZERO board cells were examined")
  try {
    $covLib1 = Join-Path $root 'coverage-lib.ps1'
    if (Test-Path $covLib1) { . $covLib1; Write-CoverageRecord -Check 'build-rescue-worklist' -OutDir $OutDir -Eligible 0 -Examined 0 -Detail 'everyday walled-store board cells traced to a dated capture file' -Blind }
  } catch { }
  exit 3
}

# The DROPPED baseline: the newest retained board at least $DropLookbackDays older than today's. NO SILENT
# CAP - if nothing is old enough we fall back to the oldest board we still have and SAY SO in the header,
# and if there is no older board at all the section is reported as not-evaluated rather than as zero.
$oldBoardRow = $null; $dropNote = ''
$older = @($boards | Where-Object { $_.date -le $newBoardRow.date.AddDays(-$DropLookbackDays) })
if ($older.Count) { $oldBoardRow = $older[$older.Count - 1] }
elseif ($boards.Count -ge 2) {
  $oldBoardRow = $boards[0]
  $dropNote = ('no retained board is ' + $DropLookbackDays + ' day(s) older than ' + $newBoardRow.file.BaseName + '; fell back to the OLDEST retained board, so the drop window is only ' + [int]($newBoardRow.date - $oldBoardRow.date).TotalDays + ' day(s)')
}
else { $dropNote = 'NOT EVALUATED - only one dated board is retained, so nothing can be diffed against' }
$oldCmp = $null
if ($oldBoardRow) {
  $oldCmp = Read-JsonFile $oldBoardRow.file.FullName
  if ($null -eq $oldCmp -or -not @($oldCmp.comparison).Count) {
    $dropNote = ('NOT EVALUATED - ' + $oldBoardRow.file.Name + ' parsed to no comparison rows')
    $oldCmp = $null
  }
}

# ---- commodity -> search term ----
$termDoc = Read-JsonFile $TermsFile
$terms = @{}
if ($termDoc -and $termDoc.PSObject.Properties['terms'] -and $termDoc.terms) {
  foreach ($p in $termDoc.terms.PSObject.Properties) { $terms[[string]$p.Name] = [string]$p.Value }
}

# ---- today's cells, indexed by store ----
# @($row.stores) around the property, always: ConvertFrom-Json rows are heterogeneous and a single-store
# row unwraps to a bare object that foreach would iterate as its PROPERTIES.
$todayCells = @{}     # "store" -> hashtable id -> cell object (everyday only)
$todayAny   = @{}     # "store" -> hashtable id -> $true    (ANY type: a cell that turned into a sale is not a drop)
foreach ($row in @($cmp.comparison)) {
  $id = [string]$row.id
  foreach ($s in @($row.stores)) {
    $st = [string]$s.store
    if (-not $todayAny.ContainsKey($st)) { $todayAny[$st] = @{}; $todayCells[$st] = @{} }
    $todayAny[$st][$id] = $true
    if (([string]$s.type) -eq 'everyday') { $todayCells[$st][$id] = $s }
  }
}
$oldEveryday = @{}    # "store" -> hashtable id -> $true
if ($oldCmp) {
  foreach ($row in @($oldCmp.comparison)) {
    $id = [string]$row.id
    foreach ($s in @($row.stores)) {
      if (([string]$s.type) -ne 'everyday') { continue }
      $st = [string]$s.store
      if (-not $oldEveryday.ContainsKey($st)) { $oldEveryday[$st] = @{} }
      $oldEveryday[$st][$id] = $true
    }
  }
}

$totalEligible = 0; $totalExamined = 0; $anyWork = $false
$summaryLines = New-Object System.Collections.ArrayList

foreach ($store in $walled) {
  $name   = [string]$store.name
  $urlkey = [string]$store.urlkey
  $prefix = [string]$store.regular_prefix
  $adCycle = if ($store.PSObject.Properties['ad_cycle']) { [string]$store.ad_cycle } else { '' }

  # ---- which capture files price this store ----
  # ALWAYS out\regular\<prefix>-regular-*.json. deals_glob is added ONLY when the store has no ad cycle:
  # Sam's "deals" files ARE its everyday captures (ad_cycle "none (national/club everyday pricing)"), but
  # Fareway's deals_glob is a genuine weekly SALE feed, and indexing that would let a coincidental
  # name+price match attribute an everyday cell to a younger sale file and hide a real expiry.
  $globs = New-Object System.Collections.ArrayList
  [void]$globs.Add((Join-Path $OutDir ('regular\' + $prefix + '-regular-*.json')))
  $dealsSkipped = ''
  if ($store.PSObject.Properties['deals_glob'] -and $store.deals_glob) {
    $dg = ([string]$store.deals_glob) -replace '/', '\'
    $dg = $dg -replace '^out\\', ''            # deals_glob is written relative to the grocery root; we anchor on -OutDir
    if ($adCycle -and $adCycle.ToLower().StartsWith('none')) { [void]$globs.Add((Join-Path $OutDir $dg)) }
    else { $dealsSkipped = ([string]$store.deals_glob) }
  }

  # ---- trace index: key -> newest capture date carrying it ----
  # NO window filter here on purpose. The STALE section exists to surface cells whose only source is ALREADY
  # past the union window (Sam's serves ~20 cells from 15-18 day old files today), and a windowed index would
  # report those as UNTRACEABLE - "unknown provenance" - hiding the fact that we know exactly how old they are.
  $idx = @{}
  $capCount = 0; $capUndated = 0
  foreach ($g in $globs.ToArray()) {
    $all = @(Get-ChildItem $g -ErrorAction SilentlyContinue)
    $dated = Get-DatedFiles $g $asOfDate
    $capUndated += ($all.Count - @($dated).Count)
    foreach ($cf in $dated) {                  # ascending: the LAST write of a key is the newest file, which wins
      $j = Read-JsonFile $cf.file.FullName
      if ($null -eq $j) { continue }
      $capCount++
      foreach ($d in @($j.deals)) {
        if ($null -eq $d) { continue }
        $idx[(Get-CellKey ([string]$d.item) ([string]$d.ad_price))] = $cf.date
      }
    }
  }

  # ---- pull-order ranking ----
  # THE FILENAME IS THE STORE-NAME SLUG, NOT THE URLKEY. build-pull-order (no extension here on purpose:
  # audit-script-census substring-matches script names in any .ps1, and a naming COMMENT is not a caller -
  # spelling it out would tell the census to drop that script's deliberate-orphan line) writes
  # pull-order-$($name.ToLower() -replace '[^a-z0-9]','').txt, so Sam's Club lands in pull-order-samsclub.txt
  # while its urlkey is "sams". Both spellings are tried; if neither exists the section keeps its natural
  # order and the header says "unranked" rather than pretending to a priority it does not have.
  $rank = @{}
  $slug = ($name.ToLower() -replace '[^a-z0-9]', '')
  $poFile = ''
  foreach ($cand in @(('pull-order-' + $slug + '.txt'), ('pull-order-' + $urlkey + '.txt'))) {
    $p = Join-Path $PullOrderDir $cand
    if (Test-Path $p) { $poFile = $p; break }
  }
  if ($poFile) {
    $ln = 0
    foreach ($line in [IO.File]::ReadAllLines($poFile)) {
      $ln++
      $cid = ([string]$line -split "`t")[0]
      $cid = $cid.Trim([char]0xFEFF).Trim()     # build-pull-order writes UTF8 WITH a BOM; line 1's id carries it
      if ($cid -and -not $rank.ContainsKey($cid)) { $rank[$cid] = $ln }
    }
  }
  $rankOf = { param($id) if ($rank.ContainsKey($id)) { [int]$rank[$id] } else { 999999 } }

  # ---- classify every EVERYDAY cell this store publishes today ----
  $expiring = New-Object System.Collections.ArrayList
  $stale    = New-Object System.Collections.ArrayList
  $untraced = New-Object System.Collections.ArrayList
  $eligible = 0; $examined = 0
  $mine = if ($todayCells.ContainsKey($name)) { $todayCells[$name] } else { @{} }
  foreach ($id in @($mine.Keys)) {
    $cell = $mine[$id]
    $eligible++
    $key = Get-CellKey ([string]$cell.item) ([string]$cell.ad)
    if (-not $idx.ContainsKey($key)) {
      # UNKNOWN PROVENANCE = CAPTURE IT. Conservative on purpose: a cell we cannot attribute to any file we
      # still hold is a cell we cannot promise will survive the next union.
      [void]$untraced.Add([pscustomobject]@{ id = $id; detail = 'no capture on disk still carries this exact row' })
      continue
    }
    $examined++
    $age = [int]($asOfDate - $idx[$key]).TotalDays
    if ($age -gt $WindowDays) {
      # ALREADY past the window. Order matters: this test must precede the days-left test, because a negative
      # days-left is trivially <= $ExpireWithinDays and would file a long-dead cell as merely "expiring".
      [void]$stale.Add([pscustomobject]@{ id = $id; age = $age; detail = ('only source is ' + $idx[$key].ToString('yyyy-MM-dd') + ', ' + $age + 'd old - ALREADY past the ' + $WindowDays + 'd union window') })
      continue
    }
    $left = $WindowDays - $age
    if ($left -le $ExpireWithinDays) {
      [void]$expiring.Add([pscustomobject]@{ id = $id; left = $left; detail = ($left.ToString() + 'd left - only source ' + $idx[$key].ToString('yyyy-MM-dd') + ' leaves the window on ' + $idx[$key].AddDays($WindowDays + 1).ToString('yyyy-MM-dd')) })
    }
  }

  # ---- DROPPED: had an everyday cell on the older board, has NO cell of any type today ----
  # DELIBERATE DIVERGENCE FROM audit-cell-drops.ps1, which EXCLUDES Sam's Club because its slices aging out
  # is policy. This tool INCLUDES Sam's: the shopper still lost the price, and a capture is what fixes it.
  # (audit-cell-drops carries the mirror of this comment.)
  $dropped = New-Object System.Collections.ArrayList
  if ($oldCmp -and $oldEveryday.ContainsKey($name)) {
    $nowAny = if ($todayAny.ContainsKey($name)) { $todayAny[$name] } else { @{} }
    foreach ($id in @($oldEveryday[$name].Keys)) {
      if ($nowAny.ContainsKey($id)) { continue }
      [void]$dropped.Add([pscustomobject]@{ id = $id; detail = ('priced on ' + $oldBoardRow.file.BaseName + ', gone from ' + $newBoardRow.file.BaseName) })
    }
  }

  # ---- rank + emit ----
  $dropSorted = @($dropped.ToArray() | Sort-Object @{e={ & $rankOf $_.id }}, id)
  $untrSorted = @($untraced.ToArray() | Sort-Object @{e={ & $rankOf $_.id }}, id)
  # EXPIRING sorts by days-left FIRST: the cell that dies tomorrow outranks the one that dies in five days
  # no matter how the pull order values them. Ties fall back to shopper value, like every other section.
  $expSorted  = @($expiring.ToArray() | Sort-Object @{e={ [int]$_.left }}, @{e={ & $rankOf $_.id }}, id)
  $stlSorted  = @($stale.ToArray()    | Sort-Object @{e={ -[int]$_.age }}, @{e={ & $rankOf $_.id }}, id)

  $lines = New-Object System.Collections.ArrayList
  $noTerm = New-Object System.Collections.ArrayList
  $emit = {
    param($rows, $section)
    foreach ($r in $rows) {
      $t = if ($terms.ContainsKey([string]$r.id)) { [string]$terms[[string]$r.id] } else { '' }
      if (-not $t) { [void]$noTerm.Add(([string]$r.id + "`t" + $section + "`t" + [string]$r.detail)); continue }
      [void]$lines.Add(($t + "`t" + [string]$r.id + "`t" + $section + "`t" + [string]$r.detail))
    }
  }
  & $emit $dropSorted 'DROPPED'
  & $emit $untrSorted 'UNTRACEABLE'
  & $emit $expSorted  'EXPIRING'
  & $emit $stlSorted  'STALE-UNREFRESHABLE'

  $outFile = Join-Path $OutDir ('rescue-terms-' + $urlkey + '.txt')
  $hdr = New-Object System.Collections.ArrayList
  [void]$hdr.Add('# rescue worklist for ' + $name + ' - the terms to search FIRST on the next browser pass')
  [void]$hdr.Add('# generated ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + '  as-of ' + $asOfDate.ToString('yyyy-MM-dd') + '  board ' + $newBoardRow.file.BaseName)
  [void]$hdr.Add('# window ' + $WindowDays + 'd | expiring-within ' + $ExpireWithinDays + 'd | drop-lookback ' + $DropLookbackDays + 'd | ' + $capCount + ' capture file(s) indexed')
  [void]$hdr.Add('# DROPPED ' + $dropSorted.Count + '  UNTRACEABLE ' + $untrSorted.Count + '  EXPIRING ' + $expSorted.Count + '  STALE-UNREFRESHABLE ' + $stlSorted.Count + '  (of ' + $eligible + ' everyday cell(s), ' + $examined + ' traced)')
  if ($dropNote) { [void]$hdr.Add('# DROPPED section: ' + $dropNote) }
  elseif ($oldBoardRow) { [void]$hdr.Add('# DROPPED section: diffed against ' + $oldBoardRow.file.BaseName) }
  if ($poFile) { [void]$hdr.Add('# ranked by ' + (Split-Path $poFile -Leaf) + ' (shopper value; EXPIRING is sorted by days-left first)') }
  else { [void]$hdr.Add('# UNRANKED - no pull-order-' + $slug + '.txt or pull-order-' + $urlkey + '.txt under ' + $PullOrderDir + ', so these are in natural order, NOT shopper-value order') }
  if ($dealsSkipped) { [void]$hdr.Add('# NOT indexed: ' + $dealsSkipped + ' - that is a weekly SALE feed for a store with an ad cycle, and a sale row must never be read as the source of an everyday cell') }
  if ($capUndated -gt 0) { [void]$hdr.Add('# ' + $capUndated + ' capture file(s) skipped: no yyyy-MM-dd in the filename, so their age cannot be known') }
  # VERBATIM AND LOAD-BEARING. compare-deals hands a commodity to the freshest capture OUTRIGHT, so a shallow
  # re-capture does not top up the old data, it REPLACES it with less.
  [void]$hdr.Add('# DEEP CAPTURE REQUIRED: for every term below, capture ALL qualifying products, not the first')
  [void]$hdr.Add('# match - a narrow re-capture WINS the commodity with thinner data (grapefruit went fresh->canned')
  [void]$hdr.Add('# this way). If a term cannot be captured deep, skip it and leave the old file to serve.')
  [void]$hdr.Add('# columns: term<TAB>commodityId<TAB>section<TAB>detail')
  if (-not $lines.Count -and -not $noTerm.Count) { [void]$hdr.Add('# nothing at risk - no dropped, untraceable, expiring or stale everyday cell for this store today') }
  foreach ($l in $lines.ToArray()) { [void]$hdr.Add($l) }
  if ($noTerm.Count) {
    # NEVER SILENTLY DROPPED. A rescue commodity with no commodity-search entry cannot be searched, and that
    # is a hole in commodity-search.json, not an absence of work.
    [void]$hdr.Add('# NO SEARCH TERM in ' + (Split-Path $TermsFile -Leaf) + ' for the ' + $noTerm.Count + ' commodity(ies) below - they need a term added before they can be rescued')
    foreach ($l in $noTerm.ToArray()) { [void]$hdr.Add('# ' + $l) }
  }
  # Written on EVERY run, including the empty one: a stale list left over from yesterday must never be
  # mistaken for today's worklist.
  Set-Content -Path $outFile -Value $hdr.ToArray() -Encoding UTF8

  $totalEligible += $eligible
  $totalExamined += $examined
  $work = $dropSorted.Count + $untrSorted.Count + $expSorted.Count + $stlSorted.Count
  if ($work -gt 0) { $anyWork = $true }
  $noTermNote = if ($noTerm.Count) { ('  NO-TERM ' + $noTerm.Count) } else { '' }
  [void]$summaryLines.Add(('rescue [{0}]: DROPPED {1}  UNTRACEABLE {2}  EXPIRING {3}  STALE {4}{5} -> {6}' -f $name, $dropSorted.Count, $untrSorted.Count, $expSorted.Count, $stlSorted.Count, $noTermNote, (Join-Path (Split-Path $OutDir -Leaf) (Split-Path $outFile -Leaf))))
}

foreach ($l in $summaryLines.ToArray()) { Write-Output $l }

# COVERAGE, so the ledger sees this going quiet the way it sees every other check. Eligible = every everyday
# cell of a walled store; Examined = the ones actually traced to a dated capture. Wrapped, like every emitter:
# a logger must never be able to throw into the thing it is logging.
try {
  $covLib = Join-Path $root 'coverage-lib.ps1'
  if (Test-Path $covLib) {
    . $covLib
    if ($totalExamined -le 0 -and $totalEligible -gt 0) {
      Write-CoverageRecord -Check 'build-rescue-worklist' -OutDir $OutDir -Eligible $totalEligible -Examined $totalExamined -Detail 'everyday walled-store board cells traced to a dated capture file' -Blind
    } else {
      Write-CoverageRecord -Check 'build-rescue-worklist' -OutDir $OutDir -Eligible $totalEligible -Examined $totalExamined -Detail 'everyday walled-store board cells traced to a dated capture file'
    }
  }
} catch { }

# BLIND OUTRANKS ADVISORY. Walled cells existed and not one traced means the capture files are gone from
# out\ (the fresh-clone / cloud-runner state) - every cell would be reported UNTRACEABLE and the emitted
# lists would be a full re-pull of everything, which is exactly the fire drill this tool exists to end.
if ($totalEligible -gt 0 -and $totalExamined -eq 0) {
  Write-Output ('rescue: COULD NOT EVALUATE - ' + $totalEligible + ' everyday walled-store cell(s) and NOT ONE traced to a capture file on disk. The lists above name every cell and are a full re-pull, not a rescue; treat them as unproven until out\regular\ holds this store''s captures again.')
  exit 3
}
if ($anyWork) { exit 1 }
Write-Output 'rescue: ok - every everyday cell of every walled store traces to a capture with room left in the union window'
exit 0
