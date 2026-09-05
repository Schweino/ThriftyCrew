# audit-capture-eviction.ps1 - is any board cell dearer than the row the engine's OWN rule says should win?
#
# WHY THIS EXISTS (2026-08-06 Sam's baby-formula finding, measured live):
#   Select-FreshestCaptureRows decides which capture prices a commodity at a store. Until 2026-08-06 the
#   freshest capture that held even ONE matching row won it outright. Sam's and Walmart captures are partial
#   term-based pulls, so a capture that swept one premium product beat a capture that swept twenty:
#     sams-deals-2026-08-05.json  1,808 deals, exactly 1 baby-formula row: Bubs Goat Milk, $1.4445/oz
#     sams-deals-2026-07-29.json  2,475 deals, 20+ baby-formula rows incl Member's Mark, $0.7704/oz
#   The live Sam's cell read $1.4445/oz, +87%, and NOTHING could see it: both rows real, both prices real,
#   the arithmetic reproduces, the crown never moved. 58 cells estate-wide, worst 18.17x. It is also how a
#   wrong product reaches the board - a bad rule is harmless while outranked and becomes the cell the moment
#   it is ALONE in its capture. Six live wrong products got there exactly that way.
#
#   The engine now keeps an older capture whenever it holds MORE rows for that commodity than the newest one
#   (compare-deals -SelfTest cases 25-28). This audit is the outcome check on that rule.
#
# WHAT IT ASKS, AND WHY IT IS PHRASED THIS WAY.
#   The first draft of this guard re-simulated the ranking from the candidate pool. That is a PROXY, and this
#   estate has now been bitten by a proxy at every layer: 2026-07-31 measured crowns when it meant routes,
#   2026-08-06 measured routes when it meant CELLS. So this reads the actual board and asks one question:
#       is the published cell materially dearer than the cheapest row the engine's own eligibility rule
#       says should have been available to it?
#   Eligible = undated rows (a store's only source, never filtered) + rows from the newest capture + rows
#   from any older in-window capture holding MORE rows for this commodity than the newest one does. That is
#   Select-FreshestCaptureRows restated. On a healthy board the answer is zero findings. A finding means the
#   board and the rule disagree, which is either a ranking regression or a capture the engine should have
#   kept and did not - both worth a human.
#
#   It stays silent on the ONIONS founding bug by construction: there the cheaper row came from an older,
#   THINNER capture, which the rule deliberately discards (a 16-day-old hand-promotion pricing Sam's onions
#   at a stale-LOW $0.737/lb against a live $0.8267). If this guard ever fires on that shape, the eligibility
#   rule has been rewritten as "cheapest in the window" and the bug the ranker exists for is back.
#
#   .\audit-capture-eviction.ps1                    audit the newest board against the newest candidates
#   .\audit-capture-eviction.ps1 -Ratio 1.5         only cells 1.5x or more above the eligible cheapest
#   .\audit-capture-eviction.ps1 -SelfTest          frozen founding-bug fixture + clean twins
# Exit 0 = clean or advisory findings. Exit 2 = self-test regression. Exit 3 = BLIND (cannot see src_date).
param([string]$CandidatesFile = '', [string]$CompareFile = '', [double]$Ratio = 1.25, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# ONE implementation of the ruling matcher, two callers (compare-deals enforces it, this audits against it).
. (Join-Path $root 'known-wrong-lib.ps1')
# ONE implementation of the ELIGIBILITY rule, same two callers, same reason. See capture-depth-lib's header.
. (Join-Path $root 'capture-depth-lib.ps1')

# THE DETECTOR, pure so the fixture reaches the REAL code path with no data files on disk
# (fix-needs-reachable-selftest: two same-day fixes regressed in this estate because their self-test could
# not reach the new code). $Board maps "<commodity id>|<store>" -> @{ per_unit = <double>; item = <string> }.
function Find-CaptureEvictions {
  param([object[]]$Commodities, [hashtable]$Board, [double]$Ratio = 1.25, [hashtable]$Blocks = @{})
  $out = @()
  foreach ($c in $Commodities) {
    $all = @($c.candidates | Where-Object { $null -ne $_.unit_price -and [double]$_.unit_price -gt 0 })
    # ADJUDICATED-WRONG ROWS ARE NOT AVAILABLE PRICES. candidates-*.json is emitted BEFORE compare-deals
    # drops known-wrong rows, so the pool contains rows the board is right to refuse. The first live run of
    # this guard reported exactly one finding and it was this: furniture-polish at Sam's, where a duplicate
    # capture of the SAME $12.52 Pledge 3-pack had been parsed once as 87 oz and once as 29 oz. Pledge lemon
    # cans are 9.7 oz, so "3 ct., 29 oz." is 29 oz TOTAL and the cheaper $0.1439/oz row is the wrong-basis
    # one - already ruled, correctly, in known-wrong.json. Reporting it would have been a guard telling a
    # human to un-fix a fixed bug. Blocks come from known-wrong-lib, the SAME matcher the engine enforces.
    if ($Blocks.Count) {
      $all = @($all | Where-Object { -not (Test-KnownWrong -Blocks $Blocks -CommodityId ([string]$c.id) -Store ([string]$_.store) -ProductName ([string]$_.name)) })
    }
    if (-not $all.Count) { continue }
    foreach ($sg in ($all | Group-Object store)) {
      $rows = @($sg.Group)
      $store = [string]$sg.Name
      $key = ([string]$c.id) + '|' + $store
      if (-not $Board.ContainsKey($key)) { continue }   # this store has no published cell here
      $cell = $Board[$key]
      $boardPu = [double]$cell.per_unit
      if ($boardPu -le 0) { continue }

      # ELIGIBILITY - THE ENGINE'S OWN FUNCTION, not a restatement of it (2026-08-21).
      # This used to be a hand-copied transcription with a comment asking the next editor to keep both in
      # lockstep, backed by a test-auditors grep for a shared literal. The copies drifted the first time
      # the rule's MEANING changed rather than its text: when the everyday/sale split made one captured
      # product emit two candidate rows, "count the rows" quietly stopped meaning "how much does this
      # capture know". A grep cannot see that. Both sides now call capture-depth-lib, so an audit that
      # measures a rule the engine does not run is no longer expressible.
      $dated = @($rows | Where-Object { $_.src_date })
      if ($dated.Count) {
        $newest = @($dated | ForEach-Object { [string]$_.src_date } | Sort-Object -Descending)[0]
        $eligible = @(Select-FreshestCaptureRows $rows)
      } else {
        $eligible = $rows
        $newest = ''
      }
      if (-not $eligible.Count) { continue }

      $shouldWin = @($eligible | Sort-Object { [double]$_.unit_price })[0]
      if ([double]$shouldWin.unit_price -le 0) { continue }
      $ratioGot = $boardPu / [double]$shouldWin.unit_price
      if ($ratioGot -lt $Ratio) { continue }

      $boardRow = @($rows | Where-Object { [string]$_.name -eq [string]$cell.item })[0]
      $boardSrc = if ($boardRow) { [string]$boardRow.src_date } else { '' }
      $out += [pscustomobject]@{
        id = [string]$c.id; commodity = [string]$c.label; unit = [string]$c.unit; store = $store
        board_price = $boardPu; board_item = [string]$cell.item; board_src = $boardSrc
        should_price = [double]$shouldWin.unit_price; should_item = [string]$shouldWin.name
        should_src = [string]$shouldWin.src_date
        ratio = [math]::Round($ratioGot, 3)
        newest_capture = [string]$newest
        should_capture_rows = @($rows | Where-Object { [string]$_.src_date -eq [string]$shouldWin.src_date }).Count
      }
    }
  }
  return $out
}

if ($SelfTest) {
  $bad = 0
  # ---- MUST FIRE: the frozen 2026-08-06 Sam's baby-formula case, as the board actually published it.
  # Synthetic and FROZEN, never re-read from the board, so a later fix cannot quietly disarm the fixture
  # that proves this guard works. The board shows the 1-row capture's premium bottle; the pool holds the
  # 4-row capture the engine's rule says is eligible.
  $pool = @(
    [pscustomobject]@{ id='baby-formula'; label='Baby Formula'; unit='oz'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.'; unit_price=1.4445; src_date='2026-08-05' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark, Advantage Premium, Infant Formula, 48 oz."; unit_price=0.7704; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark, Infant Premium, Infant Formula, 48 oz."; unit_price=0.8017; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark Advantage Premium Baby Formula Powder with Iron, 36 oz."; unit_price=0.805; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name="Member's Mark Sensitivity Premium Baby Formula, 48 oz."; unit_price=0.8329; src_date='2026-07-29' }
    )}
  )
  $boardBad = @{ "baby-formula|Sam's Club" = @{ per_unit = 1.4445; item = 'Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.' } }
  $f1 = @(Find-CaptureEvictions -Commodities $pool -Board $boardBad -Ratio $Ratio)
  if ($f1.Count -ne 1) { Write-Output ("  X MUST-FIRE: baby-formula did not flag (found " + $f1.Count + ")"); $bad++ }
  else {
    if ([math]::Abs($f1[0].ratio - 1.875) -gt 0.01) { Write-Output ("  X MUST-FIRE: wrong ratio, got " + $f1[0].ratio); $bad++ }
    if ($f1[0].should_item -notlike "*Advantage Premium, Infant Formula*") { Write-Output ("  X MUST-FIRE: named the wrong row: " + $f1[0].should_item); $bad++ }
  }
  # CLEAN TWIN 1: the SAME pool, with the board showing what the fixed engine publishes. Must be silent.
  $boardGood = @{ "baby-formula|Sam's Club" = @{ per_unit = 0.7704; item = "Member's Mark, Advantage Premium, Infant Formula, 48 oz." } }
  $f2 = @(Find-CaptureEvictions -Commodities $pool -Board $boardGood -Ratio $Ratio)
  if ($f2.Count -ne 0) { Write-Output ("  X CLEAN TWIN: fired on the CORRECT board (" + $f2[0].ratio + "x)"); $bad++ }

  # CLEAN TWINS: evictions that are CORRECT and must stay silent.
  $clean = @(
    # 2. THE FOUNDING ONIONS BUG. The cheaper $0.737 row is from an older, THINNER capture, so the rule
    #    deliberately discards it. Firing here would argue against the fix that created the ranker.
    [pscustomobject]@{ id='onions'; label='Onions'; unit='lb'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Yellow Onions, 10 lbs.'; unit_price=0.737; src_date='2026-07-14' }
      [pscustomobject]@{ store="Sam's Club"; name='Sweet Onions, 6 lbs.'; unit_price=0.8267; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Red Onions, 5 lbs.'; unit_price=0.9100; src_date='2026-07-29' }
      [pscustomobject]@{ store="Sam's Club"; name='Vidalia Onions, 10 lbs.'; unit_price=0.9500; src_date='2026-07-29' }
    )}
    # 3. A store with NO capture dates at all is never filtered, so its cheapest always wins and there is
    #    nothing to report. Dating these would filter a whole store's catalogue - see case 23 in the engine.
    [pscustomobject]@{ id='bread'; label='Bread'; unit='each'; candidates=@(
      [pscustomobject]@{ store="Baker's"; name='Kroger White Bread'; unit_price=1.10; src_date='' }
      [pscustomobject]@{ store="Baker's"; name='Private Selection Sourdough'; unit_price=3.49; src_date='' }
    )}
  )
  $cleanBoard = @{
    "onions|Sam's Club" = @{ per_unit = 0.8267; item = 'Sweet Onions, 6 lbs.' }
    "bread|Baker's"     = @{ per_unit = 1.10;   item = 'Kroger White Bread' }
  }
  $f3 = @(Find-CaptureEvictions -Commodities $clean -Board $cleanBoard -Ratio $Ratio)
  if ($f3.Count -ne 0) {
    foreach ($c in $f3) { Write-Output ("  X CLEAN TWIN fired: " + $c.commodity + " / " + $c.store + " at " + $c.ratio + "x") }
    $bad += $f3.Count
  }
  # CLEAN TWIN 4: a commodity the store has candidates for but NO published cell must never be reported.
  $f4 = @(Find-CaptureEvictions -Commodities $pool -Board @{} -Ratio $Ratio)
  if ($f4.Count -ne 0) { Write-Output '  X CLEAN TWIN: reported a store with no board cell'; $bad++ }
  # CLEAN TWIN 5: an ADJUDICATED-WRONG cheaper row is not an available price. Frozen from the first live
  # run: the guard's only finding was furniture-polish at Sam's, where the cheaper row is a duplicate of the
  # same $12.52 Pledge 3-pack parsed as 87 oz instead of 29, and known-wrong.json already rules it. Without
  # this the guard tells a human to reverse a correct fix. Uses the REAL blocklist matcher, not a stub.
  $kwPool = @(
    [pscustomobject]@{ id='furniture-polish'; label='Furniture Polish'; unit='oz'; candidates=@(
      [pscustomobject]@{ store="Sam's Club"; name='Pledge Furniture Enhancing Polish Spray, Lemon, 3 ct., 29 oz.'; unit_price=0.4317; src_date='2026-08-01' }
      [pscustomobject]@{ store="Sam's Club"; name='Pledge Furniture Enhancing Polish Spray, Lemon, 3ct., 29 oz.'; unit_price=0.1439; src_date='2026-08-01' }
    )}
  )
  $kwBoard = @{ "furniture-polish|Sam's Club" = @{ per_unit = 0.4317; item = 'Pledge Furniture Enhancing Polish Spray, Lemon, 3 ct., 29 oz.' } }
  $kwBlocks = @{ "furniture-polish|Sam's Club" = @{ (KwNorm 'Pledge Furniture Enhancing Polish Spray, Lemon, 3ct., 29 oz.') = $true } }
  $f5 = @(Find-CaptureEvictions -Commodities $kwPool -Board $kwBoard -Ratio $Ratio -Blocks $kwBlocks)
  if ($f5.Count -ne 0) { Write-Output ('  X CLEAN TWIN: reported an adjudicated-wrong row as an available price (' + $f5[0].ratio + 'x)'); $bad++ }
  # ...and the same pool with NO ruling must still fire, or the twin above proves nothing.
  $f6 = @(Find-CaptureEvictions -Commodities $kwPool -Board $kwBoard -Ratio $Ratio)
  if ($f6.Count -ne 1) { Write-Output '  X MUST-FIRE: the known-wrong twin is unreachable - it passes even with no ruling'; $bad++ }

  if ($bad -eq 0) { Write-Output 'audit-capture-eviction SELF-TEST PASS (2 must-fire, 5 clean twins)'; exit 0 }
  Write-Output ("audit-capture-eviction SELF-TEST FAIL ($bad)"); exit 2
}

# ---- live run ----
$OutDir = Join-Path $root 'out'
if (-not $CandidatesFile) {
  $cf = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { Write-Output 'BLIND: no candidates-*.json to audit'; exit 3 }
  $CandidatesFile = $cf.FullName
}
if (-not $CompareFile) {
  $mf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $mf) { Write-Output 'BLIND: no comparison-*.json to audit'; exit 3 }
  $CompareFile = $mf.FullName
}
$doc = Read-JsonFile $CandidatesFile
$cs = @($doc.commodities)
if (-not $cs.Count) { Write-Output 'BLIND: candidates file has no commodities'; exit 3 }

# BLIND, LOUDLY. compare-deals did not emit src_date into candidates until 2026-08-06. Reading an older
# file would report a confident zero over a corpus that cannot express the defect - the exact failure this
# guard was written about. Say so and exit 3 rather than printing a clean line.
$dated = 0
foreach ($c in $cs) { $dated += @($c.candidates | Where-Object { $_.src_date }).Count }
if ($dated -eq 0) {
  Write-Output ("BLIND: no candidate row in " + (Split-Path $CandidatesFile -Leaf) + " carries src_date.")
  Write-Output '       That file predates the 2026-08-06 compare-deals change that emits it. Rebuild with'
  Write-Output '       compare-deals.ps1 before trusting any result here - a zero from this file is not a clean board.'
  exit 3
}

$cmp = Read-JsonFile $CompareFile
$rows = @($cmp.comparison)
if (-not $rows.Count) { Write-Output 'BLIND: comparison file has no rows'; exit 3 }
$board = @{}
foreach ($r in $rows) {
  foreach ($s in @($r.stores)) {
    if ([double]$s.per_unit -le 0) { continue }
    $board[([string]$r.id) + '|' + ([string]$s.store)] = @{ per_unit = [double]$s.per_unit; item = [string]$s.item }
  }
}
if (-not $board.Count) { Write-Output 'BLIND: comparison carries no priced store cells'; exit 3 }

$blocks = Get-KnownWrongBlocks -Path (Join-Path $root 'known-wrong.json')
$findings = @(Find-CaptureEvictions -Commodities $cs -Board $board -Ratio $Ratio -Blocks $blocks)
$ranked = @($findings | Sort-Object @{e={-$_.ratio}})
Write-Output ("audit-capture-eviction: $($board.Count) published cell(s), $dated dated candidate row(s), $($findings.Count) cell(s) dearer than the engine's own eligibility rule allows at or above $($Ratio)x")
foreach ($f in ($ranked | Select-Object -First 25)) {
  Write-Output ("  [{0,-11}] {1,-26} board {2}/{3} ({4})  should be {5} from {6} ({7} rows)  {8}x" -f `
    $f.store, $f.commodity, ('{0:N4}' -f $f.board_price), $f.unit, $f.board_src, `
    ('{0:N4}' -f $f.should_price), $f.should_src, $f.should_capture_rows, $f.ratio)
  Write-Output ("                board:  {0}" -f $f.board_item)
  Write-Output ("                should: {0}" -f $f.should_item)
}
if ($ranked.Count -gt 25) { Write-Output ("  ... and " + ($ranked.Count - 25) + " more (nothing truncated silently: rerun with -Ratio to widen or narrow)") }
$outFile = Join-Path $OutDir 'capture-evictions.json'
@{ generated = (Get-Date).ToString('s'); candidates_file = (Split-Path $CandidatesFile -Leaf); compare_file = (Split-Path $CompareFile -Leaf); ratio = $Ratio; findings = $ranked } |
  ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("  -> $outFile")
Write-GuardComplete -Name 'capture-eviction' -Summary ''
exit 0

