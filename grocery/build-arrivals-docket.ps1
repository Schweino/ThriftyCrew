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

  PROSPECTS - THE THIRD SECTION, AND WHY IT IS HERE (2026-08-01). Everything above reviews a product that
  is ALREADY on the board. `discover-hyvee.ps1` produces the opposite: products that are NOT on the board and
  would beat what we hold, written to out\hyvee-discovery.json. That docket had no reader, so discovery paid
  nothing - it found That's Smart! peanut butter 33% under the held price and the finding just sat there.
  It belongs here because it is the same review unit and the same reader: a new product that would take a
  crown, ranked by how far its name sits from its own cohort.

  IT CANNOT BE MACHINE-VETTED, AND THAT IS MEASURED. Family Fare depth is safe because `canonical_url` is a
  shelf path (aisle-test.ps1). Hy-Vee publishes NO per-product department, and the CATEGORY facet its search
  response exposes is SILENTLY IGNORED when passed back as a filter - three request shapes tried, all
  returned the identical unfiltered results with a cat litter still sitting in "baking soda". A filter that
  looks applied and is not is worse than none, so nothing here is gated on it and nothing here is auto-
  accepted. The first live run measured ~14% of candidates as WRONG PRODUCTS (a salad dressing and a pasta
  both matched "olive oil" and both beat the held price), which is the Family Fare browse-test rate.
  So this section RANKS and EXPLAINS; adjudicate-discovery.ps1 records the human's verdict.

  Prospects are scored by the SAME cohort divergence as an arrival, plus a BASIS check on the size string -
  because the Pasta Roni vermicelli "beat" olive oil only by dividing 4.6 WEIGHT ounces as fluid ounces.
  A settled candidate (discovery-verdicts.json) is never listed again: a queue that re-asks a settled
  question teaches its reader to skim.

  WHAT THAT SCORING IS ACTUALLY WORTH, MEASURED ON THE FOUNDING DOCKET (11 candidates, 2026-08-01):
  the two known-wrong products RANK FIRST AND SECOND (Pasta Roni vermicelli and Hendrickson's dressing,
  both div 0.50) above all nine real ones (div 0.33 and 0.00). So the ORDER is informative.
  **The 0.75 FLOOR FIRED ON NEITHER OF THEM** - only the basis check flagged the vermicelli, and the
  dressing carries no machine signal at all. The floor is NOT retuned to fit 11 rows; that is exactly the
  overfit the aisle test walked into by writing its own positive examples. So: FLAG means "look here
  first", it does NOT mean the unflagged ones are clear. EVERY open prospect needs a human ruling, and
  ~1 in 7 of them is a wrong product.

  Exit codes: 0 = docket produced. 3 = could not evaluate (no board, no baseline, or a thin baseline).
              It NEVER exits 1 or 2. This is a review queue; nothing here may hold a publish.
              PROSPECTS never move the exit code either way - they are not a delta of this board.

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
  [string]$DiscoveryFile = '',
  [string]$VerdictsFile = '',
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

# ------------------------------------------------------------------ PROSPECTS (the discovery docket)
# Scored against the SAME board and the SAME cohort as an arrival, because a prospect that beats the crown
# is an arrival that has not happened yet. It never touches $adequate or the exit code: the baseline
# adequacy question is about THIS board's delta, and a prospect is not part of that delta.
$prospects = New-Object 'System.Collections.Generic.List[object]'
$prospectBlind = New-Object 'System.Collections.Generic.List[object]'
$discState = ''
$discSettled = 0
$discFile = if ($DiscoveryFile -ne '') { $DiscoveryFile } else { Join-Path $outDir 'hyvee-discovery.json' }
$verdFile = if ($VerdictsFile -ne '') { $VerdictsFile } else { Join-Path $root 'discovery-verdicts.json' }
try {
  . (Join-Path $root 'discovery-lib.ps1')
  if (-not (Test-Path $discFile)) {
    $discState = 'no discovery docket on disk (' + $discFile + ') - discovery has not run, which is NOT the same as "no candidates"'
  } else {
    $draw = ((Get-Content -LiteralPath $discFile -Raw -Encoding UTF8) + '').Trim()
    if ($draw -eq '') { $discState = 'discovery docket is EMPTY on disk - unreadable, not "nothing found"' }
    else {
      # assign FIRST: @(Get-Content | ConvertFrom-Json) does not unroll a bare top-level JSON array in PS 5.1
      $dj = $draw | ConvertFrom-Json
      $cands = @($dj)
      if ($null -ne $dj -and $dj.PSObject.Properties.Name -contains 'candidates') { $cands = @($dj.candidates) }
      $verdicts = Get-DiscoveryVerdicts $verdFile
      # per-commodity floor and unit, straight off the board this docket was built against
      $bestById = @{}; $unitById = @{}
      foreach ($c in $today) {
        $pu = [double]$c.per_unit
        if ($pu -gt 0 -and ((-not $bestById.ContainsKey($c.id)) -or $pu -lt $bestById[$c.id])) { $bestById[$c.id] = $pu }
        if (-not $unitById.ContainsKey($c.id)) { $unitById[$c.id] = [string]$c.unit }
      }
      foreach ($cd in @($cands | Where-Object { $_ })) {
        $cid = [string]$cd.id; $cstore = [string]$cd.store; $cname = [string]$cd.product
        if ($cid -eq '' -or $cname -eq '') { continue }
        $key = Get-DiscoveryKey -Store $cstore -Commodity $cid -ProductId ([string]$cd.product_id) -Product $cname
        if ($verdicts.ContainsKey($key)) { $discSettled++; continue }
        $basis = Test-DiscoveryBasisSuspect -Size ([string]$cd.size) -Unit ([string]$cd.unit)
        $head = Get-ArrivalHead $cname
        $tokA = Get-ArrivalTokens $head
        $cohort = @()
        if ($byId.ContainsKey($cid)) { $cohort = @($byId[$cid] | Where-Object { $_.store -ne $cstore }) }
        # WOULD IT TAKE THE CROWN? Only answerable when the board prices this commodity in the SAME unit the
        # candidate was measured in. A cross-unit comparison here would be the basis bug wearing a verdict.
        $takes = $null; $floorPu = $null
        if ($bestById.ContainsKey($cid) -and ([string]$unitById[$cid] -eq [string]$cd.unit)) {
          $floorPu = [double]$bestById[$cid]
          $takes = ([double]$cd.per_unit -gt 0 -and [double]$cd.per_unit -lt $floorPu)
        }
        # $pWhy, NOT $why. $why is the BASELINE-ADEQUACY reason for the whole docket, and reusing the name
        # here overwrote it with the last prospect's message - so a run with no baseline printed
        # "DEGRADED: no-board-row for ketchup" instead of "ZERO baseline boards", and its exit-3 line lied
        # about why it could not evaluate. Same clobber family as $Matches being global in PS 5.1.
        $pWhy = ''
        if (-not $byId.ContainsKey($cid)) { $pWhy = 'no-board-row (this board prices no cell for "' + $cid + '", so there is no cohort to judge the name against)' }
        elseif ($cohort.Count -lt 2) { $pWhy = 'thin-cohort (' + $cohort.Count + ' other priced cell(s); scoring is impossible, NOT a pass)' }
        elseif ($tokA.Count -lt 2) { $pWhy = 'short-head ("' + $head + '" carries no identity words after the cut)' }
        $div = $null; $consTxt = ''
        if ($pWhy -eq '') {
          $cnt = @{}
          foreach ($m in $cohort) { foreach ($t in (Get-ArrivalTokens (Get-ArrivalHead $m.item))) { if ($cnt.ContainsKey($t)) { $cnt[$t]++ } else { $cnt[$t] = 1 } } }
          $need = [Math]::Ceiling($cohort.Count / 2.0)
          $cons = New-Object 'System.Collections.Generic.HashSet[string]'
          foreach ($k in $cnt.Keys) { if ($cnt[$k] -ge $need) { [void]$cons.Add($k) } }
          foreach ($t in (Get-ArrivalTokens $labels[$cid])) { [void]$cons.Add($t) }
          if ($cons.Count -eq 0) { $pWhy = 'no-consensus (the cohort shares no word and the commodity label carries none)' }
          else {
            $hit = 0; foreach ($t in $cons) { if ($tokA.Contains($t)) { $hit++ } }
            $div = [Math]::Round(1.0 - ($hit / [double]$cons.Count), 4)
            $consTxt = (($cons | Sort-Object) -join ' ')
          }
        }
        $rec = [pscustomobject]@{
          key = $key; id = $cid; store = $cstore; product = $cname; head = $head
          size = [string]$cd.size; price = $cd.price; per_unit = $cd.per_unit; unit = [string]$cd.unit
          held_per_unit = $cd.held_per_unit; beats_by_pct = $cd.beats_by_pct
          board_floor = $floorPu; would_take_crown = $takes
          product_id = [string]$cd.product_id
          cohort = $cohort.Count; consensus = $consTxt; div = $div
          basis_suspect = $basis
          unscorable = $pWhy
        }
        # A prospect we could not SCORE is still a prospect a human must rule on, so it stays in the queue
        # with its reason attached rather than being filed away in a BLIND list nobody adjudicates from.
        if ($pWhy -ne '') { $prospectBlind.Add($rec) } else { $prospects.Add($rec) }
      }
      $discState = 'ok'
    }
  }
} catch {
  # LOUD, never silent: a prospects section that threw must not read like a prospects section that found
  # nothing. Same failure shape as the guards that died on a delegated child's stderr.
  $discState = 'THREW while reading the discovery docket: ' + $_.Exception.Message
}

# FLAG a prospect on divergence OR on a suspect basis - they are independent defects and the Pasta Roni
# vermicelli carried both. Crown-takers first: a prospect that cannot win changes no shopper's price.
# .ToArray() on BOTH, not @(...). `@($aList) + @($bList)` throws "Argument types do not match" in PS 5.1:
# the array subexpression does NOT unroll a List[object] (same family as it not unrolling a bare top-level
# JSON array), so this is List + List, which has no + operator - and it takes the whole docket down before
# a single line of it prints.
$prospectAll = @($prospects.ToArray() + $prospectBlind.ToArray())
$prospectFlagged = @($prospectAll | Where-Object { ($null -ne $_.div -and $_.div -ge $Floor) -or $_.basis_suspect -ne '' -or $_.unscorable -ne '' })
# ONE STRING SORT KEY, not four typed expressions. A multi-expression Sort-Object in PS 5.1 compares the
# results pairwise, so a column that is Int32 on one row and Double on another (div is $null for an
# unscorable prospect) throws "Argument types do not match" and takes the whole docket down with it.
# Digits, in order: crown-taker, flagged, unscorable, 1-div (so higher divergence sorts first), id.
$prospectSorted = @($prospectAll | Sort-Object -Property @{ Expression = {
  $flagged = (($null -ne $_.div -and [double]$_.div -ge $Floor) -or $_.basis_suspect -ne '' -or $_.unscorable -ne '')
  $d = if ($null -eq $_.div) { 0.0 } else { [double]$_.div }
  ('{0}{1}{2}{3:00000}{4}' -f `
    $(if ($_.would_take_crown -eq $true) { 0 } else { 1 }), `
    $(if ($flagged) { 0 } else { 1 }), `
    $(if ($_.unscorable -ne '') { 0 } else { 1 }), `
    [int][Math]::Round((1.0 - $d) * 10000), [string]$_.id)
} })

# ------------------------------------------------------------------ console docket
$hdr = 'arrivals-docket: ' + $boardDate + ' vs ' + $baseFiles.Count + ' baseline board(s)'
if ($baseFiles.Count -gt 0) { $hdr += ' (' + $baseFiles[0] + ' .. ' + $baseFiles[$baseFiles.Count - 1] + ')' }
Write-Output $hdr
Write-Output ('  cells today ' + $today.Count + ' | baseline union ' + $seen.Count + ' | ARRIVALS ' + $nArr +
  ' (crown ' + @($scored | Where-Object { $_.crown }).Count + ') | scored ' + $scored.Count + ' | blind ' + $blind.Count)
Write-Output ('  FLAGGED at div >= ' + $Floor + ': ' + ($crownSec.flag.Count + $otherSec.flag.Count) +
  '  (this is a REVIEW QUEUE - measured precision is low; nothing here blocks a publish)')
Write-Output ('  PROSPECTS awaiting a ruling: ' + $prospectAll.Count + ' (' +
  @($prospectAll | Where-Object { $_.would_take_crown -eq $true }).Count + ' would take a crown, ' +
  $prospectFlagged.Count + ' flagged, ' + $discSettled + ' already ruled)' +
  $(if ($discState -ne 'ok') { '  [' + $discState + ']' } else { '' }))
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
Write-Output ('PROSPECTS - NOT ON THE BOARD, WOULD BEAT WHAT WE HOLD (' + $prospectAll.Count + ' open, ' + $discSettled + ' already adjudicated)')
if ($discState -ne 'ok') {
  Write-Output ('  BLIND: ' + $discState)
} elseif ($prospectAll.Count -eq 0) {
  Write-Output '  none open'
} else {
  Write-Output ('  ~14% of these are WRONG PRODUCTS (measured). Hy-Vee publishes no per-product department, so')
  Write-Output ('  NOTHING machine-vetted them and NONE of them is passed here. FLAG is reading order, not a')
  Write-Output ('  verdict - on the founding docket the floor fired on neither wrong product. Rule every one:')
  Write-Output ('    .\adjudicate-discovery.ps1 -Key <key> -Accept|-Reject -RuledBy <you> -Evidence "..."')
  $pn = 0
  foreach ($p in $prospectSorted) {
    $pn++
    $tag = if (($null -ne $p.div -and $p.div -ge $Floor) -or $p.basis_suspect -ne '' -or $p.unscorable -ne '') { 'FLAG' } else { 'ctx ' }
    $divTxt = if ($null -eq $p.div) { ' n/a' } else { ('{0:N2}' -f $p.div) }
    $crownTxt = if ($p.would_take_crown -eq $true) { 'TAKES CROWN' } elseif ($null -eq $p.would_take_crown) { 'crown UNKNOWN (unit/row mismatch)' } else { 'no crown' }
    Write-Output ''
    Write-Output ('  ' + $tag + '#' + $pn + '  div=' + $divTxt + '  ' + $crownTxt + '  ' + $p.id + ' @ ' + (ConvertTo-AsciiLine $p.store) +
      '   $' + ('{0:N4}' -f [double]$p.per_unit) + '/' + (ConvertTo-AsciiLine $p.unit))
    Write-Output ('        candidate   : ' + (ConvertTo-AsciiLine $p.product) + '   [' + (ConvertTo-AsciiLine $p.size) + ' @ $' + ('{0:N2}' -f [double]$p.price) + ']')
    Write-Output ('        vs we hold  : $' + ('{0:N4}' -f [double]$p.held_per_unit) + '/' + (ConvertTo-AsciiLine $p.unit) +
      $(if ($null -ne $p.beats_by_pct) { '   beats by ' + $p.beats_by_pct + '%' } else { '   (we hold nothing here)' }) +
      $(if ($null -ne $p.board_floor) { '   board floor $' + ('{0:N4}' -f [double]$p.board_floor) } else { '' }))
    if ($p.unscorable -ne '') { Write-Output ('        UNSCORABLE  : ' + (ConvertTo-AsciiLine $p.unscorable)) }
    else { Write-Output ('        cohort says : ' + (ConvertTo-AsciiLine $p.consensus) + '   (' + $p.cohort + ' other cell(s))') }
    if ($p.basis_suspect -ne '') { Write-Output ('        BASIS       : ' + (ConvertTo-AsciiLine $p.basis_suspect)) }
    Write-Output ('        key         : ' + $p.key)
  }
}

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
  prospects_source = $discFile
  prospects_state = $discState
  prospects_open = $prospectAll.Count
  prospects_settled = $discSettled
  prospects_flagged = $prospectFlagged.Count
  prospects_crown_takers = @($prospectAll | Where-Object { $_.would_take_crown -eq $true }).Count
  prospects = $prospectSorted
}
$doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Output ''
Write-Output ('arrivals-docket: wrote ' + $OutFile)

if (-not $adequate) { Write-Output ('arrivals-docket: BLIND/DEGRADED - ' + $why); exit 3 }
exit 0

