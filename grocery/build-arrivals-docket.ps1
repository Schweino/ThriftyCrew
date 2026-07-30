<#
  build-arrivals-docket.ps1 - THE ARRIVALS DESK. A REVIEW QUEUE, NOT A GATE. It never blocks publish.

  WHY THIS EXISTS. 99 distinct wrong numbers reached shoppers in 22 days. Guards caught 5%, Brad caught 7%
  (and every one of his was a MISSING store or a mismatched LINK, never a wrong price); ~88% were found by
  an agent reading the board. 47 of the 99 were ONE bug - a commodity's include regex matched a product that
  is not the commodity. The rule library is 43,416 excludes against 1,079 includes and still loses: salmon
  carried TEN pet-food patterns and "Dry Food for Adult Cats" walked through all ten.

  WHY NOT THE OBVIOUS FIXES.
    - SKU identity does not fix it. 85% of cells already trace to a first-party product id, and all four of
      the 2026-07-30 wrong products were top-of-ladder verified (Dr Teal's Foaming Bath carries Kroger
      product_id 0081106801501, a real price and a working link). Identity proves "this price belongs to
      this product". NOTHING proves "this product belongs to this commodity" - 0 of 3,164 cells carry that
      decision, and that is the decision that is wrong.
    - Name detectors do not fix it on their own. Best measured precision 21%, and one generic word ("pure",
      shared with "LouAna 100% Pure Coconut Oil") hid a bath soap inside its cohort.
    - Price magnitude does not fix it. The near-misses have no magnitude signal: cat-food-as-salmon was 20.8%
      under the runner-up, Teddy-Grahams-as-cinnamon 4.7%, Lysol-as-stain-remover 2.8%. Ranking by "how big
      a saving is this" ranks the founding cases near the bottom.

  SO RANK THE DELTA INSTEAD. The board barely moves: 99.3% of cells are byte-identical day to day. About 196
  products arrive per cycle and about 44 of those take a crown, and a wrong product is 4x more likely to hold
  a crown. The delta is the reviewable unit, and the only method with a proven hit rate in this estate is an
  agent reading it. This script hands that agent a ranked, capped, honest docket.

  THE SCORE: COHORT DIVERGENCE, computed on the HEAD of the product name.
    head  = the product name cut at the first comma, " with " or " featuring ".
    tokens= lowercased words, light plural fold, size/packaging/marketing stopwords dropped.
    cohort= the OTHER priced cells of the same commodity on the SAME board (needs at least 2).
    consensus = tokens present in the head of at least half the cohort, PLUS the commodity label's tokens.
    div   = 1 - (consensus tokens the arrival's head actually contains) / (consensus tokens).

  THE HEAD CUT IS THE WHOLE TRICK, and it is not a style choice - it is measured. Wrong products get matched
  through a word buried in the TAIL of a long marketing name, so scoring the FULL name scores the bug as a
  perfect match. Run against the three founding cases on the real boards (trailing 14, this exact script with
  only the Substring in Get-ArrivalHead neutered):
        founding case                              WITH head cut        FULL name (control)
        Dr Teal's bath soap as coconut-oil 07-28   div 1.00, rank 1     div 0.00, rank 4
        Blue Buffalo cat food as salmon    07-29   div 1.00, rank 3     NOT LISTED AT ALL
        Idahoan Baby Reds as parmesan      07-23   div 1.00, rank 3     div 0.67, rank 7
  Without the cut the bath soap is a PERFECT match to "coconut oil" and the cat food falls off the docket
  entirely - the detector goes blind to the exact bugs it was written for. Do NOT "improve" this by scoring
  the full name; test-auditors.ps1 pins the bath-soap case for that reason.

  CAP (adaptive, and it says what it drops). A fixed cap covers everything on a 21-arrival day and a few
  percent of a 521-arrival day - which is exactly the day the most wrong products enter - and a silent
  truncation reads as "covered everything". So:
    TIER A "FLAGGED": every arrival at or above the -Floor divergence (default 0.75). NEVER capped. Measured
      across all 18 real deltas on disk this tier is 0-14 crown + 0-66 other rows, so it cannot run away.
    TIER B "CONTEXT": the next best by divergence, K = clamp(ceil(0.10 * section size), 10, 40).
    Everything else is DROPPED and the drop count plus the divergence AT THE CUT is printed and recorded, so
    a reader can see exactly how deep the review went.
  Because Tier A is uncapped, a founding-class case (div 1.00) can never be dropped by the cap.

  THIN COHORTS ARE REPORTED BLIND, NEVER PASSED. On the 2026-07-30 board 22 of 492 commodities have ONE
  priced cell and 19 more have exactly two, so 41 commodities cannot produce a 2-member cohort and scoring
  there is impossible. A name whose head has fewer than 2 content tokens ("Fresh Produce", "Golden") is
  equally unscorable. Both land in the BLIND section with a reason. A check that examined nothing must say so.

  BASELINE ADEQUACY. If the trailing boards hold fewer than half of today's cells the "arrivals" are just the
  board growing, not products arriving (2026-07-12: 268 baseline cells against 1,630 today produced 1,473
  "arrivals"). That case exits 3 - could-not-evaluate - with the docket still written and marked degraded.

  Exit codes: 0 = docket produced. 3 = could not evaluate (no board, no baseline, or a thin baseline).
              It NEVER exits 1 or 2. This is a review queue; nothing here may hold a publish.

  Usage:
    build-arrivals-docket.ps1
    build-arrivals-docket.ps1 -CompareFile out\comparison-2026-07-28.json -N 14
    build-arrivals-docket.ps1 -SelfTest
#>
[CmdletBinding()]
param(
  [string]$CompareFile = '',
  [string]$BaselineDir = '',
  [string]$CommoditiesFile = '',
  [int]$N = 14,
  [string]$OutFile = '',
  [double]$Floor = 0.75,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'

# Size, packaging and marketing words. These are NOT commodity words - they appear on every product of every
# commodity, so counting them as agreement is how a bath soap scores as coconut oil. "fresh"/"value"/"great"
# are here because "Great Value", "Fresh Produce" and "Our Family" are store brands, not identities.
$script:STOP = @{}
foreach ($w in @('the','and','of','for','a','an','in','with','plus','to','on','at','by','or','no','non',
  'ct','pk','pack','count','oz','lb','lbs','fl','g','kg','ml','l','qt','pt','gal','each','ea','size','pc','pcs','x',
  'free','value','great','brand','all','natural','original','classic','premium','fresh','new','style','our',
  'family','pkg','bag','box','bottle','can','jar','container','package','packaged')) { $script:STOP[$w] = $true }

function Get-ArrivalHead {
  param([string]$Name)
  if ([string]::IsNullOrEmpty($Name)) { return '' }
  $idx = $Name.Length
  $c = $Name.IndexOf(',')
  if ($c -ge 0 -and $c -lt $idx) { $idx = $c }
  # [regex]::Match into a LOCAL. $Matches is global in PS 5.1 and gets clobbered by any -match run between
  # here and the read, which is how a guard in this repo once read another function's capture groups.
  $m = [regex]::Match($Name, '(?i)\s(with|featuring)\s')
  if ($m.Success -and $m.Index -lt $idx) { $idx = $m.Index }
  $h = $Name.Substring(0, $idx).Trim()
  if ($h.Length -lt 3) { return $Name.Trim() }
  return $h
}

function Get-ArrivalFold {
  param([string]$T)
  # Light plural fold ONLY. Real stemming merges "cream"/"creamer" and hides products; this exists because
  # "Kroger Olive Oil Mayo" against a cohort saying "mayonnaise" is a naming difference, not a wrong product,
  # and 5 of 11 top flags on 2026-07-30 were exactly that (mayo/mayonnaise, donut/donuts, razor/razors).
  if ($T.Length -gt 4 -and $T.EndsWith('ies')) { return $T.Substring(0, $T.Length - 3) + 'y' }
  if ($T.Length -gt 4 -and ($T.EndsWith('ses') -or $T.EndsWith('xes') -or $T.EndsWith('hes'))) { return $T.Substring(0, $T.Length - 2) }
  if ($T.Length -gt 3 -and $T.EndsWith('s') -and -not $T.EndsWith('ss')) { return $T.Substring(0, $T.Length - 1) }
  return $T
}

function Get-ArrivalTokens {
  param([string]$S)
  $out = New-Object 'System.Collections.Generic.HashSet[string]'
  if ([string]::IsNullOrWhiteSpace($S)) { return $out }
  foreach ($t in [regex]::Split($S.ToLowerInvariant(), '[^a-z0-9]+')) {
    if ($t.Length -lt 2) { continue }
    if ($t -match '^[0-9]') { continue }
    if ($script:STOP.ContainsKey($t)) { continue }
    [void]$out.Add((Get-ArrivalFold $t))
  }
  return $out
}

function Get-ArrivalKey {
  param([string]$Id, [string]$Store, [string]$Item)
  # Punctuation-insensitive so "Raisins 20 Oz" and "Raisins, 20 oz" are the same product, not an arrival.
  # Measured: removes 0-20 phantom arrivals a day (4% of the queue) and costs nothing.
  return ($Id + '|' + $Store + '|' + [regex]::Replace($Item.ToLowerInvariant(), '[^a-z0-9]', ''))
}

function ConvertTo-AsciiLine {
  param([string]$S)
  # Several files in this estate are BOM-less and the logs are ASCII; a non-ASCII product name
  # ("Jalapeno Peppers" spelled with a tilde-n) has produced mojibake in this pipeline before. The JSON keeps
  # the exact bytes; only the console line is folded.
  if ($null -eq $S) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $S.ToCharArray()) { if ([int]$ch -ge 32 -and [int]$ch -le 126) { [void]$sb.Append($ch) } else { [void]$sb.Append('?') } }
  return $sb.ToString()
}

function Read-BoardCells {
  param([string]$Path)
  # ((Get-Content -Raw) + '') because [string]$null is $null, so .Trim() on a zero-byte file THROWS, and
  # '' | ConvertFrom-Json returns $null WITHOUT throwing - both have produced silent wrong answers here.
  $raw = ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) + '').Trim()
  if ($raw -eq '') { return $null }
  $j = $raw | ConvertFrom-Json
  if ($null -eq $j) { return $null }
  $lst = New-Object 'System.Collections.Generic.List[object]'
  foreach ($r in @($j.comparison)) {
    if ($null -eq $r) { continue }
    $id = [string]$r.id
    if ($id -eq '') { continue }
    $cheap = [string]$r.cheapest_store
    # ConvertFrom-Json rows are HETEROGENEOUS - row 0 having .stores says nothing about row 500.
    foreach ($s in @($r.stores)) {
      if ($null -eq $s) { continue }
      $item = [string]$s.item
      if ($item -eq '') { continue }
      $st = [string]$s.store
      $lst.Add([pscustomobject]@{
        id = $id; label = [string]$r.commodity; unit = [string]$r.unit; store = $st; item = $item
        per_unit = $s.per_unit; type = [string]$s.type; crown = ($st -eq $cheap -and $cheap -ne '')
      })
    }
  }
  return $lst
}

# ------------------------------------------------------------------ SELF-TEST (hermetic, touches no out\)
if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Write-Output ("  PASS  " + $msg); $script:p++ } else { Write-Output ("  FAIL  " + $msg); $script:f++ } }
  Write-Output 'build-arrivals-docket -SelfTest'
  T ((Get-ArrivalHead "Dr Teal's Foaming Bath with Pure Epsom Salt, Nourish & Protect with Coconut Oil") -eq "Dr Teal's Foaming Bath") 'head cut drops the tail that hid the founding bug'
  T ((Get-ArrivalHead 'Blue Buffalo Wilderness Natural High Protein Dry Food for Adult Cats, Salmon, 9.5-lb Bag') -eq 'Blue Buffalo Wilderness Natural High Protein Dry Food for Adult Cats') 'head cut at the first comma'
  T ((Get-ArrivalHead 'Idahoan Baby Reds with Roasted Garlic & Parmesan Mashed Potatoes') -eq 'Idahoan Baby Reds') 'head cut at " with "'
  T ((Get-ArrivalHead 'Kroger Olive Oil Mayo') -eq 'Kroger Olive Oil Mayo') 'head cut leaves a clean name alone'
  $tk = Get-ArrivalTokens 'Great Value Raisins, 20 oz Bag'
  T (-not $tk.Contains('great') -and -not $tk.Contains('bag') -and $tk.Contains('raisin')) 'stopwords dropped and plural folded'
  T ((Get-ArrivalFold 'mayonnaise') -eq 'mayonnaise' -and (Get-ArrivalFold 'donuts') -eq 'donut' -and (Get-ArrivalFold 'glass') -eq 'glass') 'plural fold does not eat -ss'
  T ((Get-ArrivalKey 'raisins' 'Family Fare' 'Raisins, 20 Oz') -eq (Get-ArrivalKey 'raisins' 'Family Fare' 'Raisins 20 oz')) 'arrival key ignores punctuation churn'
  T ((ConvertTo-AsciiLine 'Jalapeno') -eq 'Jalapeno') 'ascii fold leaves ascii alone'
  if ($f -gt 0) { Write-Output ("SelfTest: " + $f + " FAILED"); exit 3 }
  Write-Output ("SelfTest: all " + $p + " passed"); exit 0
}

# ------------------------------------------------------------------ inputs
if ($BaselineDir -eq '') { $BaselineDir = $outDir }
if (-not (Test-Path $BaselineDir)) { Write-Output ('arrivals-docket: BLIND - baseline dir not found: ' + $BaselineDir); exit 3 }
$allBoards = @(Get-ChildItem (Join-Path $BaselineDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
if ($CompareFile -eq '') {
  if ($allBoards.Count -eq 0) { Write-Output ('arrivals-docket: BLIND - no comparison-*.json in ' + $BaselineDir); exit 3 }
  $CompareFile = $allBoards[$allBoards.Count - 1].FullName
}
if (-not (Test-Path $CompareFile)) { Write-Output ('arrivals-docket: BLIND - board not found: ' + $CompareFile); exit 3 }
$cmpItem = Get-Item $CompareFile
$mDate = [regex]::Match($cmpItem.Name, 'comparison-(\d{4}-\d{2}-\d{2})\.json')
$boardDate = if ($mDate.Success) { $mDate.Groups[1].Value } else { $cmpItem.BaseName }
if ($OutFile -eq '') { $OutFile = Join-Path $outDir 'arrivals-docket.json' }

# The baseline is every board BEFORE this one by name (dates sort lexically), newest N. Recording the exact
# file set in the docket is not decoration: this estate has shipped guards whose answer depended on which
# files happened to be on disk, and a docket that cannot name its own baseline cannot be re-derived.
# A board named comparison-<date>.json excludes itself AND anything dated on or after it. A board handed in
# under any other name (a fixture, a one-off slice) cannot be date-ordered against the dir, so the whole dir
# is its baseline - and it is never its own baseline, by full path.
$prior = @($allBoards | Where-Object { $_.FullName -ne $cmpItem.FullName -and ((-not $mDate.Success) -or $_.Name -lt $cmpItem.Name) })
if ($N -gt 0 -and $prior.Count -gt $N) { $prior = @($prior[($prior.Count - $N)..($prior.Count - 1)]) }
if ($N -le 0) { $prior = @() }

$today = Read-BoardCells $cmpItem.FullName
if ($null -eq $today -or $today.Count -eq 0) {
  Write-Output ('arrivals-docket: BLIND - ' + $cmpItem.Name + ' parsed to ZERO priced cells; "no arrivals" would be an empty claim')
  exit 3
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$baseFiles = New-Object 'System.Collections.Generic.List[string]'
foreach ($pf in $prior) {
  $pc = Read-BoardCells $pf.FullName
  if ($null -eq $pc) { continue }
  $baseFiles.Add($pf.Name)
  foreach ($c in $pc) { [void]$seen.Add((Get-ArrivalKey $c.id $c.store $c.item)) }
}

$adequate = $true; $why = ''
if ($baseFiles.Count -eq 0) {
  $adequate = $false; $why = 'ZERO baseline boards - every cell on the board reads as an arrival'
} elseif ($seen.Count -lt ($today.Count * 0.5)) {
  $adequate = $false
  $why = ('baseline union holds ' + $seen.Count + ' cells against ' + $today.Count + ' today (' +
    [Math]::Round($seen.Count / [double]$today.Count, 2) + 'x) - this delta is the BOARD GROWING, not products arriving')
}

# ------------------------------------------------------------------ score
$byId = @{}
foreach ($c in $today) {
  if (-not $byId.ContainsKey($c.id)) { $byId[$c.id] = New-Object 'System.Collections.Generic.List[object]' }
  $byId[$c.id].Add($c)
}
$labels = @{}
$comFile = if ($CommoditiesFile -ne '') { $CommoditiesFile } else { Join-Path $root 'commodities.json' }
if (Test-Path $comFile) {
  $craw = ((Get-Content -LiteralPath $comFile -Raw -Encoding UTF8) + '').Trim()
  if ($craw -ne '') { foreach ($cr in @($craw | ConvertFrom-Json)) { if ($cr -and [string]$cr.id -ne '') { $labels[[string]$cr.id] = [string]$cr.label } } }
}

$scored = New-Object 'System.Collections.Generic.List[object]'
$blind  = New-Object 'System.Collections.Generic.List[object]'
$nArr = 0
foreach ($c in $today) {
  if ($seen.Contains((Get-ArrivalKey $c.id $c.store $c.item))) { continue }
  $nArr++
  $head = Get-ArrivalHead $c.item
  $tokA = Get-ArrivalTokens $head
  $cohort = @($byId[$c.id] | Where-Object { $_.store -ne $c.store })
  $bReason = ''
  if ($cohort.Count -lt 2) { $bReason = 'thin-cohort (' + $cohort.Count + ' other priced cell(s); scoring is impossible, NOT a pass)' }
  elseif ($tokA.Count -lt 2) { $bReason = 'short-head ("' + $head + '" carries no identity words after the cut)' }
  if ($bReason -eq '') {
    $cnt = @{}
    foreach ($m in $cohort) { foreach ($t in (Get-ArrivalTokens (Get-ArrivalHead $m.item))) { if ($cnt.ContainsKey($t)) { $cnt[$t]++ } else { $cnt[$t] = 1 } } }
    $need = [Math]::Ceiling($cohort.Count / 2.0)
    $cons = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $cnt.Keys) { if ($cnt[$k] -ge $need) { [void]$cons.Add($k) } }
    foreach ($t in (Get-ArrivalTokens $labels[$c.id])) { [void]$cons.Add($t) }
    if ($cons.Count -eq 0) { $bReason = 'no-consensus (the cohort shares no word and the commodity label carries none)' }
    else {
      $hit = 0; foreach ($t in $cons) { if ($tokA.Contains($t)) { $hit++ } }
      $scored.Add([pscustomobject]@{
        id = $c.id; store = $c.store; item = $c.item; head = $head; crown = $c.crown
        per_unit = $c.per_unit; unit = $c.unit; type = $c.type; cohort = $cohort.Count
        consensus = (($cons | Sort-Object) -join ' ')
        div = [Math]::Round(1.0 - ($hit / [double]$cons.Count), 4)
      })
    }
  }
  if ($bReason -ne '') {
    $blind.Add([pscustomobject]@{ id = $c.id; store = $c.store; item = $c.item; head = $head; crown = $c.crown
      per_unit = $c.per_unit; unit = $c.unit; why = $bReason })
  }
}

function Select-Section {
  param($Rows, [double]$Fl)
  $sorted = @($Rows | Sort-Object -Property @{ Expression = { -$_.div } }, @{ Expression = { $_.id } })
  $flag = @($sorted | Where-Object { $_.div -ge $Fl })
  $k = [Math]::Ceiling($sorted.Count * 0.10)
  if ($k -lt 10) { $k = 10 }
  if ($k -gt 40) { $k = 40 }
  $take = $flag.Count
  if ($k -gt $take) { $take = $k }
  if ($take -gt $sorted.Count) { $take = $sorted.Count }
  $listed = if ($take -gt 0) { @($sorted[0..($take - 1)]) } else { @() }
  $ctx = @()
  if ($listed.Count -gt $flag.Count) { $ctx = @($listed[$flag.Count..($listed.Count - 1)]) }
  $cutDiv = $null
  if ($sorted.Count -gt $take) { $cutDiv = $sorted[$take].div }
  return [pscustomobject]@{ flag = $flag; context = $ctx; dropped = ($sorted.Count - $take); cut = $cutDiv; total = $sorted.Count }
}

$crownSec = Select-Section @($scored | Where-Object { $_.crown }) $Floor
$otherSec = Select-Section @($scored | Where-Object { -not $_.crown }) $Floor

# ------------------------------------------------------------------ console docket
$hdr = 'arrivals-docket: ' + $boardDate + ' vs ' + $baseFiles.Count + ' baseline board(s)'
if ($baseFiles.Count -gt 0) { $hdr += ' (' + $baseFiles[0] + ' .. ' + $baseFiles[$baseFiles.Count - 1] + ')' }
Write-Output $hdr
Write-Output ('  cells today ' + $today.Count + ' | baseline union ' + $seen.Count + ' | ARRIVALS ' + $nArr +
  ' (crown ' + @($scored | Where-Object { $_.crown }).Count + ') | scored ' + $scored.Count + ' | blind ' + $blind.Count)
Write-Output ('  FLAGGED at div >= ' + $Floor + ': ' + ($crownSec.flag.Count + $otherSec.flag.Count) +
  '  (this is a REVIEW QUEUE - measured precision is low; nothing here blocks a publish)')
if (-not $adequate) { Write-Output ('  DEGRADED: ' + $why) }

$fn = 0
function Show-Rows {
  param($Rows, [string]$Tag, [switch]$Crown)
  foreach ($r in $Rows) {
    $script:fn++
    Write-Output ('')
    Write-Output ('  ' + $Tag + '#' + $script:fn + '  div=' + ('{0:N2}' -f $r.div) + '  ' + $(if ($Crown) { 'CROWN  ' } else { '       ' }) +
      $r.id + ' @ ' + (ConvertTo-AsciiLine $r.store) + '   $' + ('{0:N4}' -f [double]$r.per_unit) + '/' + (ConvertTo-AsciiLine $r.unit))
    Write-Output ('        board item  : ' + (ConvertTo-AsciiLine $r.item))
    Write-Output ('        scored head : ' + (ConvertTo-AsciiLine $r.head))
    Write-Output ('        cohort says : ' + (ConvertTo-AsciiLine $r.consensus) + '   (' + $r.cohort + ' other cell(s))')
  }
}

Write-Output ''
Write-Output ('CROWN ARRIVALS (' + $crownSec.total + ') - a wrong product is 4x more likely to hold a crown')
if ($crownSec.total -eq 0) { Write-Output '  none' }
Show-Rows $crownSec.flag 'FLAG' -Crown
Show-Rows $crownSec.context 'ctx' -Crown
if ($crownSec.dropped -gt 0) { Write-Output ('  ... ' + $crownSec.dropped + ' more crown arrival(s) NOT listed, all at div <= ' + ('{0:N2}' -f [double]$crownSec.cut)) }

Write-Output ''
Write-Output ('OTHER ARRIVALS (' + $otherSec.total + ')')
if ($otherSec.total -eq 0) { Write-Output '  none' }
Show-Rows $otherSec.flag 'FLAG'
Show-Rows $otherSec.context 'ctx'
if ($otherSec.dropped -gt 0) { Write-Output ('  ... ' + $otherSec.dropped + ' more arrival(s) NOT listed, all at div <= ' + ('{0:N2}' -f [double]$otherSec.cut)) }

Write-Output ''
Write-Output ('BLIND - COULD NOT SCORE (' + $blind.Count + '). These were examined and produced NO verdict. Not a pass.')
if ($blind.Count -eq 0) { Write-Output '  none' }
foreach ($b in @($blind | Sort-Object -Property @{ Expression = { -[int][bool]$_.crown } }, @{ Expression = { $_.id } })) {
  Write-Output ('  BLIND ' + $(if ($b.crown) { 'CROWN ' } else { '      ' }) + $b.id + ' @ ' + (ConvertTo-AsciiLine $b.store) + ' : ' + (ConvertTo-AsciiLine $b.item))
  Write-Output ('        ' + (ConvertTo-AsciiLine $b.why))
}

# ------------------------------------------------------------------ docket file
$doc = [ordered]@{
  generated_at = (Get-Date).ToString('s')
  board = $cmpItem.Name
  board_date = $boardDate
  baseline_files = $baseFiles.ToArray()
  baseline_boards = $baseFiles.Count
  baseline_union_cells = $seen.Count
  baseline_adequate = $adequate
  degraded_reason = $why
  floor = $Floor
  cap_rule = 'tier A: every arrival with div >= floor, UNCAPPED. tier B: next best by div, K = clamp(ceil(0.10*section), 10, 40). Everything else is dropped and counted.'
  cells_today = $today.Count
  arrivals = $nArr
  crown_arrivals = @($scored | Where-Object { $_.crown }).Count
  scored = $scored.Count
  blind_count = $blind.Count
  flagged_count = ($crownSec.flag.Count + $otherSec.flag.Count)
  dropped_crown = $crownSec.dropped
  dropped_other = $otherSec.dropped
  dropped_below_div = @{ crown = $crownSec.cut; other = $otherSec.cut }
  crown_flagged = @($crownSec.flag)
  crown_context = @($crownSec.context)
  other_flagged = @($otherSec.flag)
  other_context = @($otherSec.context)
  blind = $blind.ToArray()
}
$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Output ''
Write-Output ('arrivals-docket: wrote ' + $OutFile)

if (-not $adequate) { Write-Output ('arrivals-docket: BLIND/DEGRADED - ' + $why); exit 3 }
exit 0

