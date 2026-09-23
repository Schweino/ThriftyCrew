<#
  update-history.ps1 - Maintains a persistent per-commodity CHEAPEST-PRICE HISTORY so we can later say
  "cheapest since <date>" / "lowest in N weeks" when a big sale lands.

  Run ONCE per week after finalizing the comparison (generate it at -MinStores 1 so single-store lows are
  tracked too - a price point is a price point). It:
    1) upserts this week's cheapest (overall + per-store) into price-history.json (keyed by commodity, by week),
    2) recomputes each commodity's all-time record low,
    3) prints + saves this week's BADGES (record low / ties / cheapest-since-<date> / lowest-in-N-weeks).
  Idempotent: re-running for the same week replaces that week's row (no double-count).

  (Written with plain arrays + Where-Object + [ordered] hashtables only - this Windows PowerShell 5.1
   host throws on several generic-List / id-keyed-hashtable constructs.)
#>
param(
  [string]$CompareFile = "",
  [string]$HistoryFile = "",
  [string]$OutDir = "",
  # -Reconcile (2026-09-22, plan-2026-09-22-10 item 2026-09-21-274e4b): after the usual upsert, re-derive every history
  # entry whose week still has a comparison-<week>.json on disk from THAT board, so a board rebuilt on any road (a
  # triage rebuild, a hand run) cannot leave a second, stale record here. See RECONCILE below.
  [switch]$Reconcile,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)      { $OutDir = Join-Path $root 'out' }
if (-not $HistoryFile) { $HistoryFile = Join-Path $root 'price-history.json' }
# ---- ONE BUILDER FOR A WEEK'S ENTRY, AND THE BOARD IT CAME FROM (2026-09-22, plan-2026-09-22-10 274e4b) ----------
# The upsert and the reconcile below both build an entry through this, so the two can never disagree on its shape.
# `board` names the file and its built_at (or a SHA-256 prefix when it has none): the entry says which board it is a
# copy of, and a rebuilt board is recognised by a stamp that no longer matches.
function Get-BoardStamp([string]$Path, $Doc) {
  $leaf = Split-Path $Path -Leaf
  if ($Doc -and $Doc.PSObject.Properties['built_at'] -and [string]$Doc.built_at) { return ($leaf + '@' + [string]$Doc.built_at) }
  return ($leaf + '@sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Substring(0, 16))
}
function New-HistoryEntry($Row, [string]$Week, [string]$Stamp) {
  $ps = [ordered]@{}; foreach ($s in $Row.stores) { $ps[[string]$s.store] = $s.per_unit }
  return [ordered]@{ week_of=$Week; cheapest_price=[double]$Row.cheapest_price; cheapest_store=$Row.cheapest_store; unit=([string]$Row.unit); per_store=$ps; board=$Stamp }
}
# The VALUES of an entry, as one comparable string (the stamp is deliberately not part of it).
# -NoUnit: an entry banked before 2026-09-06 carries no unit, and gaining the board's unit is enrichment, not a disagreement.
function Get-EntryValueKey($E, [switch]$NoUnit) {
  $pairs = @()
  if ($E.per_store) {
    $props = if ($E.per_store -is [System.Collections.IDictionary]) { @($E.per_store.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $E.per_store[$_] } }) } else { @($E.per_store.PSObject.Properties) }
    foreach ($pp in ($props | Sort-Object Name)) { $pairs += ([string]$pp.Name + '=' + ([double]$pp.Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)) }
  }
  return (([double]$E.cheapest_price).ToString('R', [Globalization.CultureInfo]::InvariantCulture) + '|' + [string]$E.cheapest_store + '|' + $(if ($NoUnit) { '' } else { [string]$E.unit }) + '|' + ($pairs -join ';'))
}

if ($SelfTest) {
  # FROZEN FIXTURES, run as a CHILD over a temp tree named per run. Weeks sit in DIFFERENT calendar weeks so the
  # compaction below (one entry per old week) can never merge two fixture weeks, whatever today's date is.
  $bad = 0; $ran = 0
  function TT([string]$n, [bool]$ok, [string]$got) {
    $script:ran++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $fx = Join-Path $env:TEMP ('uh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $fx -Force -ErrorAction Stop)
  try {
    function Board([string]$wk, [string]$built, [double]$p, [string]$st) {
      $d = [ordered]@{ built_at = $built; week_of = $wk; comparison = @([ordered]@{ id = 'cherries'; commodity = 'Cherries'; unit = 'lb'; cheapest_price = $p; cheapest_store = $st; stores = @([ordered]@{ store = $st; per_unit = $p }) }) }
      ($d | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $fx ('comparison-' + $wk + '.json')) -Encoding UTF8
    }
    # A: the founding shape - comparison-2026-09-01.json was REBUILT (new built_at) with a different cheapest (the
    # real 2026-08-10 cherries row: history 2.4133 Walmart, board 1.7209 Aldi), and history kept the old one.
    Board '2026-09-01' '2026-09-01T15:00:00' 1.7209 'Aldi'
    # B: a week whose stamp already matches its board.
    Board '2026-09-08' '2026-09-08T08:00:00' 2.10 'Hy-Vee'
    # V: a week judged by the semantic verify: history was banked from the VERIFIED board, so it is not reconciled.
    Board '2026-09-15' '2026-09-15T08:00:00' 0.0833 'Hy-Vee'
    '{"verdicts":[]}' | Set-Content -LiteralPath (Join-Path $fx 'verify-verdicts-2026-09-15.json') -Encoding UTF8
    # D: today's board, the one the upsert banks.
    Board '2026-09-22' '2026-09-22T08:00:00' 1.99 'Aldi'
    $hist = [ordered]@{ updated = '2026-09-15'; weeks_on_record = 4; commodities = @([ordered]@{ id = 'cherries'; label = 'Cherries'; unit = 'lb'; record_low = $null; history = @(
        [ordered]@{ week_of = '2026-08-04'; cheapest_price = 2.50; cheapest_store = 'Walmart'; unit = 'lb'; per_store = [ordered]@{ Walmart = 2.50 } },
        [ordered]@{ week_of = '2026-09-01'; cheapest_price = 2.4133; cheapest_store = 'Walmart'; unit = 'lb'; per_store = [ordered]@{ Walmart = 2.4133 } },
        [ordered]@{ week_of = '2026-09-08'; cheapest_price = 2.10; cheapest_store = 'Hy-Vee'; unit = 'lb'; per_store = [ordered]@{ 'Hy-Vee' = 2.10 }; board = 'comparison-2026-09-08.json@2026-09-08T08:00:00' },
        [ordered]@{ week_of = '2026-09-15'; cheapest_price = 0.1666; cheapest_store = "Sam's Club"; unit = 'lb'; per_store = [ordered]@{ "Sam's Club" = 0.1666 } }) }) }
    $hf = Join-Path $fx 'price-history.json'
    ($hist | ConvertTo-Json -Depth 9) | Set-Content -LiteralPath $hf -Encoding UTF8
    $before = Read-JsonFile $hf
    $o = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -HistoryFile $hf -CompareFile (Join-Path $fx 'comparison-2026-09-22.json') -Reconcile
    $rc = $LASTEXITCODE; $txt = ($o -join "`n")
    $after = Read-JsonFile $hf
    $h = @($after.commodities)[0].history
    function Wk([string]$w) { return (@($h | Where-Object { [string]$_.week_of -eq $w }) | Select-Object -First 1) }
    function Bk([string]$w) { return (@(@($before.commodities)[0].history | Where-Object { [string]$_.week_of -eq $w }) | Select-Object -First 1) }
    TT 'the run exits 0 and prints its marker last' ($rc -eq 0 -and ([string]@($o)[-1]) -match '^UPDATE-HISTORY-COMPLETE ') ("rc=$rc last=" + [string]@($o)[-1])
    TT 'MUST FIRE: a week whose board was rebuilt with a different cheapest (2.4133 Walmart -> 1.7209 Aldi) is rewritten' `
      ([double](Wk '2026-09-01').cheapest_price -eq 1.7209 -and [string](Wk '2026-09-01').cheapest_store -eq 'Aldi' -and [string](Wk '2026-09-01').board -eq 'comparison-2026-09-01.json@2026-09-01T15:00:00') ((Wk '2026-09-01') | ConvertTo-Json -Compress)
    TT 'MUST FIRE: the rewrite is counted and named' ($txt -match 'reconciled=1 ' -and $txt -match 'RECONCILED cherries 2026-09-01') ($txt -split "`n" | Select-Object -Last 1)
    TT 'CLEAN TWIN: a week whose stamp matches is byte-identical after -Reconcile' `
      (((Wk '2026-09-08') | ConvertTo-Json -Compress) -eq ((Bk '2026-09-08') | ConvertTo-Json -Compress)) ((Wk '2026-09-08') | ConvertTo-Json -Compress)
    TT "CLEAN TWIN: today's week is still appended as before, with its unit (lb), stamped with its board" `
      ([double](Wk '2026-09-22').cheapest_price -eq 1.99 -and [string](Wk '2026-09-22').board -eq 'comparison-2026-09-22.json@2026-09-22T08:00:00' -and [string](Wk '2026-09-22').unit -eq 'lb') ((Wk '2026-09-22') | ConvertTo-Json -Compress)
    TT 'MUST NOT FIRE: a week whose comparison file is absent is left untouched and counted in nofile=, never deleted' `
      ([double](Wk '2026-08-04').cheapest_price -eq 2.50 -and $txt -match 'nofile=1 ') ((Wk '2026-08-04') | ConvertTo-Json -Compress)
    TT 'MUST NOT FIRE: a week the semantic verify judged keeps its VERIFIED entry (never re-raised to the raw board 0.0833) and is counted' `
      ([double](Wk '2026-09-15').cheapest_price -eq 0.1666 -and $txt -match 'verified=1 ') ((Wk '2026-09-15') | ConvertTo-Json -Compress)
    TT 'CLEAN TWIN: record_low is recomputed over the reconciled weeks and the plausibility floor still refuses the 0.1666 outlier (1.7209)' `
      ([double]@($after.commodities)[0].record_low.price -eq 1.7209) ([string]@($after.commodities)[0].record_low.price)
    # a plain run (no -Reconcile) must not touch another week: the 2026-09-01 entry stays wrong, as before.
    ($hist | ConvertTo-Json -Depth 9) | Set-Content -LiteralPath $hf -Encoding UTF8
    $o2 = & powershell -NoProfile -File $PSCommandPath -OutDir $fx -HistoryFile $hf -CompareFile (Join-Path $fx 'comparison-2026-09-22.json')
    $h2 = @((Read-JsonFile $hf).commodities)[0].history
    TT 'CLEAN TWIN: without -Reconcile only today is upserted and the rebuilt week keeps its old entry' `
      ([double](@($h2 | Where-Object { [string]$_.week_of -eq '2026-09-01' })[0]).cheapest_price -eq 2.4133 -and (($o2 -join ' ') -match 'reconcile=off')) ([string]@($o2)[-1])
  }
  finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($bad -eq 0 -and $ran -eq 9) { Write-Output ('update-history self-test: PASS (' + $ran + ' case(s), 0 failure(s))'); exit 0 }
  Write-Output ('update-history self-test: FAIL (' + $bad + ' failure(s) of ' + $ran + ' case(s) run, 9 expected)')
  exit 1
}

$explicitCompare = [bool]$CompareFile
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }

$cmpDoc = Read-JsonFile $CompareFile
$week   = [string]$cmpDoc.week_of
$rows   = @($cmpDoc.comparison)
$boardStamp = Get-BoardStamp $CompareFile $cmpDoc
# A RAW board is not banked over a week the semantic verify judged (2026-09-22). check-ad-cycles banks such a week from
# verified-history.json by -CompareFile; a triage run of '-Reconcile' after compare-deals names no file, and banking the
# raw board there would re-raise every wrong-product winner the verify dropped as a record low.
$skipUpsert = $Reconcile -and -not $explicitCompare -and (Test-Path (Join-Path $OutDir ('verify-verdicts-' + $week + '.json')))
if ($skipUpsert) { Write-Output ('upsert SKIPPED for ' + $week + ': a verify-verdicts file exists, so this week is banked from the VERIFIED board by check-ad-cycles, never from the raw one') ; $rows = @() }

$existing = @()
if (Test-Path $HistoryFile) { $existing = @((Read-JsonFile $HistoryFile).commodities) }

function Weeks-Between($a, $b) { try { return [math]::Round([math]::Abs((([datetime]$a) - ([datetime]$b)).Days) / 7.0) } catch { return $null } }

# (the rule below is Get-RecordLow's body, lifted into a function on 2026-09-22 so -Reconcile recomputes a rewritten
# commodity's record low with exactly the same plausibility floor)
function Get-RecordLow($History, [string]$Id) {
  $newHistory = @($History); $id = $Id
  $rl = $null
  $ordered = @($newHistory | Where-Object { $null -ne $_.cheapest_price } | Sort-Object { [double]$_.cheapest_price })
  $skip = @{}
  if ($ordered.Count -ge 3) {
    $lo = [double]$ordered[0].cheapest_price
    $nx = [double]$ordered[1].cheapest_price
    if ($lo -gt 0 -and ($nx / $lo) -ge 2.0) {
      $skip[[string]$ordered[0].week_of] = $true
      Write-Output ("  record_low REFUSED for {0}: {1} on {2} is {3}x under the next lowest week ({4}) - treating as a parse error, not a record" -f `
        $id, $lo, $ordered[0].week_of, [math]::Round($nx / $lo, 1), $nx)
    }
  }
  foreach ($h in $newHistory) {
    if ($skip.ContainsKey([string]$h.week_of)) { continue }
    $hp=[double]$h.cheapest_price; if ($rl -eq $null -or $hp -lt $rl.price) { $rl=[ordered]@{ price=$hp; store=$h.cheapest_store; week_of=$h.week_of } }
  }
  if ($null -eq $rl) { foreach ($h in $newHistory) { $hp=[double]$h.cheapest_price; if ($rl -eq $null -or $hp -lt $rl.price) { $rl=[ordered]@{ price=$hp; store=$h.cheapest_store; week_of=$h.week_of } } } }
  return $rl
}

$updated    = @()   # rebuilt commodity records (ordered hashtables)
$updatedIds = @{}
$badges     = @()

foreach ($row in $rows) {
  $id  = [string]$row.id
  $P   = [double]$row.cheapest_price
  $ec  = $existing | Where-Object { $_.id -eq $id } | Select-Object -First 1
  $prior = @()
  if ($ec) { $prior = @($ec.history | Where-Object { $_.week_of -ne $week }) }

  # ---- badge from prior weeks ----
  $status='baseline'; $detail='first week tracked'; $since=$null; $weeks=$null
  if (@($prior).Count -gt 0) {
    $priorMin = $null
    foreach ($h in $prior) { $hp=[double]$h.cheapest_price; if ($priorMin -eq $null -or $hp -lt $priorMin) { $priorMin=$hp } }
    if ($P -lt $priorMin) { $status='record_low'; $detail=("new record low, prev best `$" + ('{0:N2}' -f $priorMin)) }
    elseif ($P -eq $priorMin) { $status='ties_record'; $detail='ties the record low' }
    else {
      # count consecutive most-recent weeks strictly ABOVE P; stop at the first week at-or-below P.
      # only a genuine dip (>=2 recent weeks were pricier) earns a "lowest in N weeks" flag.
      $weeksAbove=0; $since=$null
      foreach ($h in ($prior | Sort-Object week_of -Descending)) {
        if ([double]$h.cheapest_price -gt $P) { $weeksAbove++ } else { $since=$h.week_of; break }
      }
      if ($weeksAbove -ge 2) { $weeks=$weeksAbove; $status='low_since'; $detail=("cheapest since $since, lowest in ~$weeksAbove wk") }
      else { $status='tracking'; $detail='not lower than recent weeks' }
    }
  }
  $badges += ,([ordered]@{ id=$id; commodity=$row.commodity; unit=$row.unit; price=$P; store=$row.cheapest_store; weeks_tracked=(@($prior).Count+1); status=$status; detail=$detail; since=$since; weeks_since=$weeks })

  # ---- this week's record + upsert ----
  $ps = [ordered]@{}; foreach ($s in $row.stores) { $ps[[string]$s.store] = $s.per_unit }
  # ---- BANK THE UNIT, NOT JUST THE NUMBER (2026-09-06, queue 2026-09-06-24ac66) -------------------
  # A history entry carried week_of, cheapest_price, cheapest_store and per_store - and never the UNIT
  # those prices were measured in. So a deliberate RE-BASING of a commodity reads as a price move to the
  # week-over-week detector downstream. Measured 2026-09-06: aluminum-foil went each -> sq_ft, the band
  # was refitted, the cells came back, and sanity-check paged 'cheapest moved down 97% ($1.79 -> $0.06)'
  # comparing 1.79 PER EACH against 0.0624 PER SQUARE FOOT. Nothing was wrong with either number.
  # saffron was re-based gram -> oz on 2026-08-30 and will produce the identical false crash the day it
  # has two weeks of history, unless the unit travels with the price.
  # This is the estate's two-facts-published-without-the-fact-that-binds-them shape, and the binding fact
  # is one field. Old entries simply have no unit and the reader downstream says so out loud.
  $thisWeek = New-HistoryEntry -Row $row -Week $week -Stamp $boardStamp
  $newHistory = @()
  foreach ($h in $prior) { $newHistory += ,$h }
  $newHistory += ,$thisWeek

  # ---- all-time record low over the full history ----
  # PLAUSIBILITY FLOOR. record_low drives the buy/wait verdict, and the compaction rule below deliberately keeps
  # each old week's LOWEST entry - so a corrupt low can never age out on its own. On 2026-07-12 a whole-board
  # per-oz-rate-as-per-lb error banked brown sugar at $0.03/lb, and for 17 days the page told shoppers "Lowest
  # we have tracked: $0.03/lb. If it can wait, it usually comes back down." A price that low never existed.
  # So a candidate low that sits >= 2x under the lowest OTHER week on record is not a record, it is a parse bug:
  # keep the week in the history (it is evidence) but refuse to let it set record_low, and say so out loud.
  $rl = Get-RecordLow -History $newHistory -Id $id
  $updated += ,([ordered]@{ id=$id; label=$row.commodity; unit=$row.unit; record_low=$rl; history=$newHistory })
  $updatedIds[$id] = $true
}


# ---- ALSO track the recipe-ingredient board (added 2026-07-11 for the per-item history popup) ----
# Same weekly upsert, marked src='recipe' so trend-page generation and staples trend-links can
# exclude them until we choose to expand. NO badges for these (they'd flood records-<week>.json).
$riFile = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riFile) {
  foreach ($row in @((Read-JsonFile $riFile).comparison)) {
    $id = [string]$row.id
    if ($updatedIds.ContainsKey($id)) { continue }   # weekly board already recorded this id
    $P = $null; foreach ($s in $row.stores) { $sp = [double]$s.per_unit; if ($sp -gt 0 -and ($null -eq $P -or $sp -lt $P)) { $P = $sp } }
    if ($null -eq $P) { continue }
    $cs = ''; foreach ($s in $row.stores) { if ([double]$s.per_unit -eq $P) { $cs = [string]$s.store; break } }
    $ec = $existing | Where-Object { $_.id -eq $id } | Select-Object -First 1
    $prior = @()
    if ($ec) { $prior = @($ec.history | Where-Object { $_.week_of -ne $week }) }
    $ps = [ordered]@{}; foreach ($s in $row.stores) { if ([double]$s.per_unit -gt 0) { $ps[[string]$s.store] = $s.per_unit } }
    $thisWeek = [ordered]@{ week_of=$week; cheapest_price=$P; cheapest_store=$cs; per_store=$ps }
    $newHistory = @()
    foreach ($h in $prior) { $newHistory += ,$h }
    $newHistory += ,$thisWeek
    $rl = $null
    foreach ($h in $newHistory) { $hp=[double]$h.cheapest_price; if ($rl -eq $null -or $hp -lt $rl.price) { $rl=[ordered]@{ price=$hp; store=$h.cheapest_store; week_of=$h.week_of } } }
    $updated += ,([ordered]@{ id=$id; label=[string]$row.commodity; unit=[string]$row.unit; src='recipe'; record_low=$rl; history=$newHistory })
    $updatedIds[$id] = $true
  }
}

# ---- carry forward commodities that had no ad this week (unchanged) ----
foreach ($ec in $existing) { if (-not $updatedIds.ContainsKey([string]$ec.id)) { $updated += ,$ec } }

# ---- RECONCILE: THE BOARD IS THE ONE SOURCE, THIS FILE IS A RECONCILED COPY (2026-09-22, plan-2026-09-22-10 274e4b) ----
# The upsert above runs once a morning for TODAY's week only. A board rebuilt on any other road (a triage rebuild, a
# hand run, a second chain run) rewrites comparison-<week>.json and leaves this file holding what the board USED to
# say: 78 of 18,084 commodity-weeks disagreed on 2026-09-22 over the 33 boards on disk, and 18 of 124 week-over-week
# flags were unexplained because of it. -Reconcile re-derives every entry whose week still has a board on disk:
#   stamp matches            -> unchanged (the fast path, and every run after the first)
#   stamp differs, same values -> stamped only (the first run over an entry written before stamps existed)
#   values differ            -> RECONCILED to what the board published, and printed by name
#   no entry for the week        -> left alone: compacted= outside the 21-day daily window, missing= inside it
# Left alone and COUNTED, never deleted: a week with no board on disk (nofile=), and a week the semantic verify judged
# (verified=), because check-ad-cycles banks that week from verified-history.json and the raw board would re-raise the
# wrong-product winners the verify dropped. A board that will not parse is unreadable= and check-ad-cycles pages it:
# that is the disagreement this cannot repair.
$rc_weeks = 0; $rc_reconciled = 0; $rc_stamped = 0; $rc_unchanged = 0; $rc_nofile = 0; $rc_verified = 0; $rc_unreadable = 0; $rc_compacted = 0; $rc_missing = 0
$rcUnreadable = @()
if ($Reconcile) {
  $dailyCutR = (Get-Date).AddDays(-21).ToString('yyyy-MM-dd')
  $byIdR = @{}; foreach ($u in $updated) { $byIdR[[string]$u.id] = $u }
  $boardWeeks = @{}; $touched = @{}
  foreach ($bf in (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name)) {
    $bd = $null
    try { $bd = Read-JsonFile $bf.FullName } catch { $bd = $null }
    $bwk = if ($bd) { [string]$bd.week_of } else { '' }
    if (-not $bd -or -not $bwk -or -not $bd.comparison) { $rc_unreadable++; $rcUnreadable += $bf.Name; continue }
    $rc_weeks++
    $boardWeeks[$bwk] = $true
    if (Test-Path (Join-Path $OutDir ('verify-verdicts-' + $bwk + '.json'))) { $rc_verified++; continue }
    $bstamp = Get-BoardStamp $bf.FullName $bd
    foreach ($brow in @($bd.comparison)) {
      $bid = [string]$brow.id
      $u = $byIdR[$bid]
      if (-not $u -or ([string]$u.src) -eq 'recipe') { continue }
      $want = New-HistoryEntry -Row $brow -Week $bwk -Stamp $bstamp
      $hl = @($u.history)
      $ix = -1
      for ($i = 0; $i -lt $hl.Count; $i++) { if ([string]$hl[$i].week_of -eq $bwk) { $ix = $i; break } }
      # NO ENTRY FOR THIS WEEK: never ADDED here. Outside the 21-day daily window the week was compacted to one
      # entry by design (compacted=); inside it the board was never banked (missing=), which is the upsert's job, not a
      # disagreement with a record that exists. Adding them was measured and refused on 2026-09-22: it would have banked
      # 571 entries from comparison-2026-09-05.json, a board nobody banked or verified that day.
      if ($ix -lt 0) { if ($bwk -ge $dailyCutR) { $rc_missing++ } else { $rc_compacted++ }; continue }
      $have = $hl[$ix]
      if ($have.PSObject.Properties['board'] -and [string]$have.board -eq $bstamp) { $rc_unchanged++; continue }
      if ($have -is [System.Collections.IDictionary] -and $have.Contains('board') -and [string]$have['board'] -eq $bstamp) { $rc_unchanged++; continue }
      $noU = -not [string]$have.unit -and -not ($have -is [System.Collections.IDictionary] -and [string]$have['unit'])
      if ((Get-EntryValueKey $have -NoUnit:$noU) -eq (Get-EntryValueKey $want -NoUnit:$noU)) { $rc_stamped++ }
      else {
        $rc_reconciled++
        Write-Output ('  RECONCILED ' + $bid + ' ' + $bwk + ': ' + [string]$have.cheapest_price + ' at ' + [string]$have.cheapest_store + ' -> ' + $want.cheapest_price + ' at ' + $want.cheapest_store + ' (' + $bstamp + ')')
      }
      $hl[$ix] = $want; $u.history = $hl; $touched[$bid] = $u
    }
  }
  foreach ($u in $updated) { foreach ($hh in @($u.history)) { if (-not $boardWeeks.ContainsKey([string]$hh.week_of)) { $rc_nofile++ } } }
  foreach ($k in $touched.Keys) { $u = $touched[$k]; $u.history = @($u.history | Sort-Object { [string]$_.week_of }); $u.record_low = Get-RecordLow -History $u.history -Id $k }
  foreach ($x in $rcUnreadable) { Write-Output ('  UNREADABLE board ' + $x + ': its week could not be reconciled') }
}

# ---- compaction (Brad 2026-07-11): keep DAILY granularity for the last 21 days, then collapse
# older entries to ONE per calendar week. We keep each old week's LOWEST-cheapest entry (not the
# last one) so a mid-week record low is never erased and record_low recomputation stays honest.
$dailyCut = (Get-Date).AddDays(-21).ToString('yyyy-MM-dd')
$compacted = @()
foreach ($u in $updated) {
  $recent = @(); $old = @()
  foreach ($h in $u.history) { if ([string]$h.week_of -ge $dailyCut) { $recent += ,$h } else { $old += ,$h } }
  if (@($old).Count -gt 0) {
    $byWeek = @{}
    foreach ($h in $old) {
      try { $d = [datetime]$h.week_of } catch { continue }
      $ws = $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd')   # Monday of that week
      if (-not $byWeek.ContainsKey($ws) -or [double]$h.cheapest_price -lt [double]$byWeek[$ws].cheapest_price) { $byWeek[$ws] = $h }
    }
    $keptOld = @(); foreach ($k in ($byWeek.Keys | Sort-Object)) { $keptOld += ,$byWeek[$k] }
    $newHist = @(); foreach ($h in $keptOld) { $newHist += ,$h }; foreach ($h in $recent) { $newHist += ,$h }
    $u.history = @($newHist | Sort-Object week_of)
  }
  $compacted += ,$u
}
$updated = $compacted

# ---- persist ----
$maxWeeks = 0; foreach ($u in $updated) { $hc = @($u.history).Count; if ($hc -gt $maxWeeks) { $maxWeeks = $hc } }
# WRITTEN ATOMICALLY, AND RE-PARSED BEFORE IT COUNTS (2026-08-22). This is the largest state file in the
# estate (13+ MB) and it was written with a plain truncating Set-Content, twice per chain. The chain runs
# under a 2-hour Task Scheduler limit; a kill inside this write leaves an EMPTY file, and the reader in
# build-deals-page.ps1 turns '' into $null without throwing - so every record_low silently vanishes and
# the buy/wait badge confidently tells a reader "cheapest ever" about a price it can no longer compare.
# The temp+move+re-parse pattern is already in this folder (purge-verdict-lows.ps1); this uses it, and
# refuses the swap if the rewritten file does not re-parse with the same commodity count.
$histTmp = $HistoryFile + '.tmp'
$histDoc = [ordered]@{ updated=$week; weeks_on_record=$maxWeeks; commodities=$updated }
($histDoc | ConvertTo-Json -Depth 9) | Set-Content $histTmp -Encoding UTF8
$histCheck = $null
try { $histCheck = Get-Content $histTmp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if (-not $histCheck -or @($histCheck.commodities.PSObject.Properties).Count -ne @($histDoc.commodities.PSObject.Properties).Count) {
  Remove-Item $histTmp -Force -ErrorAction SilentlyContinue
  throw 'update-history: the rewritten price-history.json did not re-parse with the same commodity count - REFUSING the swap; the previous file stands'
}
Move-Item $histTmp $HistoryFile -Force

# ---- this week's highlight badges ----
$notable = @($badges | Where-Object { $_.status -eq 'record_low' -or $_.status -eq 'ties_record' -or $_.status -eq 'low_since' } | Sort-Object @{E={$_.weeks_since};Descending=$true})
if (-not $skipUpsert) { ([ordered]@{ week_of=$week; notable=$notable; all=$badges } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir ("records-"+$week+".json")) -Encoding UTF8 }

Write-Output ("Price history updated: " + $HistoryFile)
Write-Output ("Week $week  -  commodities tracked this week: " + (@($rows).Count) + "   weeks on record (max): " + $maxWeeks)
Write-Output ""
if (@($notable).Count -gt 0) {
  Write-Output "HEADLINE-WORTHY THIS WEEK:"
  foreach ($b in $notable) {
    $tag = switch ($b.status) { 'record_low' {'RECORD LOW'} 'ties_record' {'TIES RECORD'} 'low_since' {("LOWEST IN ~"+$b.weeks_since+" WK")} default {$b.status} }
    Write-Output ('  {0,-24} ${1,-7}/{2,-5} {3,-11} [{4}] {5}' -f $b.commodity, ('{0:N2}' -f $b.price), $b.unit, $b.store, $tag, $b.detail)
  }
} else {
  Write-Output "No records to flag yet - looks like week 1 of tracking. Badges activate automatically as weeks accumulate."
}
$rcMode = if ($Reconcile) { 'on' } else { 'off' }
Write-Output ('UPDATE-HISTORY-COMPLETE reconcile=' + $rcMode + ' weeks=' + $rc_weeks + ' reconciled=' + $rc_reconciled + ' stamped=' + $rc_stamped + ' unchanged=' + $rc_unchanged + ' nofile=' + $rc_nofile + ' verified=' + $rc_verified + ' compacted=' + $rc_compacted + ' missing=' + $rc_missing + ' unreadable=' + $rc_unreadable)
