<#
  build-verification-sample.ps1 - THE OUT-OF-BAND SAMPLE. Draws a reproducible random sample of published
  board cells and writes a BLIND worklist for an outside verifier (agent with a browser, or a human).

  WHY THIS EXISTS (2026-07-30). Every number this estate prints about its own accuracy is written by the
  same code that wrote the board. On the morning of 2026-07-30 the internal reports all read clean -
  "ACCURACY 0 of 1,844", "guards exit 0", "2,640 cells scanned" - and all of them were true as printed while
  a bag of cat food ("Dry Food for Adult Cats") sat on the board holding the SALMON crown. 99 distinct wrong
  numbers reached shoppers in 22 days; the guards caught 5% of them. 47 of the 99 were one bug: a commodity's
  include regex matched a product that is not the commodity. Nothing in the pipeline decides "this product
  belongs to this commodity" - 0 of 2,792 cells carry that decision - so nothing in the pipeline can check it.
  SKU identity does not help (85% of cells already trace to a first-party product id, and all four of that
  morning's wrong products were top-of-ladder verified with real ids, real prices and working links). Name
  detectors do not help (best measured precision 21%).
  The only statement about the board that the board did not write about itself is a human or an agent
  opening the store's own site, finding the cheapest qualifying product, and saying what it is.

  BLIND ON PURPOSE. The worklist carries the commodity LABEL, its UNIT and the STORE, and nothing else.
  It does NOT carry the product name, the size, the price, or whether the cell is crowned. Handing the
  verifier our own answer is exactly what makes an internal check worthless: shown "Fresh Atlantic Salmon
  Fillet, $6.98/lb", a verifier confirms the price and never asks whether the row is salmon at all. The
  board's own answer is written to a SEALED KEY file that only record-sample-verdict.ps1 opens, at
  adjudication time, after the verdicts are in.

  DETERMINISTIC, NOT RANDOM. No Get-Random anywhere: every cell gets a score from
  SHA256(seed + '|' + id + '|' + store), the cells are sorted by that score, and the first n win. The seed
  defaults to the BOARD DATE, so the same board always draws the same sample and anyone can re-run this and
  get the identical worklist - which is what makes a disputed verdict auditable months later. Sorting by a
  hash of the key (rather than shuffling a list) also makes the draw independent of the order the board
  happens to be written in.

  CROWN-STRATIFIED. A wrong product is ~4x more likely to hold a crown (a wrong match usually wins by being
  implausibly cheap), so the draw over-samples crown cells. *** READ THIS ***: a crown-weighted sample does
  NOT estimate the whole-board defect rate on its own. It estimates the CROWN rate and the NON-CROWN rate
  separately, and the whole-board number is the population-weighted combination of the two. That reweighting
  is done by record-sample-verdict.ps1, which needs the stratum sizes this script writes into the key file.
  Draw with -CrownShare 0 for a plain whole-board simple random sample.

  OUTPUTS (both under out\):
    verification-worklist-<board-date>.csv  - the BLIND worklist. Give the verifier THIS FILE ONLY.
    verification-sample-<board-date>.json   - the SEALED key: board answers + strata. Do not open it before
                                              the verdicts are recorded.

  Exit codes: 0 = sample written. 3 = BLIND (no board, or zero cells - this proved nothing). 1 = error.

  Next step after the verifier fills in the verdict column:
      powershell -File record-sample-verdict.ps1 -VerdictFile out\verification-worklist-<date>.csv
#>
param(
  [int]$N = 100,
  # share of the draw spent on crown (cheapest_store) cells. 0 = plain whole-board simple random sample.
  [double]$CrownShare = 0.6,
  [string]$CompareFile = '',
  [string]$Seed = '',
  # scope the draw to named stores (exact names from stores.json). Empty = whole board, as before.
  # A per-store rate needs a per-store POPULATION; slicing a whole-board sample afterwards just yields
  # ~14% of n per store and quotes an interval too wide to act on.
  [string[]]$Store = @(),
  [switch]$Force,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
function Say([string]$s) { if (-not $Quiet) { Write-Output $s } }

# ---------------------------------------------------------------------------------------------------------
# BEGIN-SAMPLE-DRAW  (extracted and executed verbatim by test-auditors.ps1 - do not rename these sentinels)
# ---------------------------------------------------------------------------------------------------------
function Get-SampleScore([string]$seed, [string]$key) {
  # A deterministic uniform in [0,1) for one cell. SHA256 so the ordering carries no relationship to the
  # id text (an alphabetical or length-correlated "random" order would quietly sample one shape of commodity).
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed + '|' + $key))
  } finally { $sha.Dispose() }
  # 6 bytes -> 0 .. 2^48-1. Built by hand rather than BitConverter to keep it endian-stable and to stay
  # clear of Int64 sign flips; 2^48 buckets over <3,000 cells makes a score collision a non-event.
  $v = 0.0
  for ($i = 0; $i -lt 6; $i++) { $v = ($v * 256.0) + [double]$bytes[$i] }
  return ($v / 281474976710656.0)
}

function Get-StratumAllocation([int]$n, [double]$crownShare, [int]$crownPop, [int]$nonPop) {
  # How many of the n draws go to each stratum, after clamping to what actually exists.
  # THE SPILL RULE: if one stratum is smaller than its target, the remainder goes to the other one rather
  # than shrinking the sample - a 100-cell request must return 100 cells whenever the board holds 100.
  if ($n -lt 0) { $n = 0 }
  if ($crownShare -lt 0) { $crownShare = 0.0 }
  if ($crownShare -gt 1) { $crownShare = 1.0 }
  $total = $crownPop + $nonPop
  if ($n -gt $total) { $n = $total }
  $c = [int][Math]::Round($n * $crownShare, [MidpointRounding]::AwayFromZero)
  if ($c -gt $crownPop) { $c = $crownPop }
  $nc = $n - $c
  if ($nc -gt $nonPop) { $nc = $nonPop; $c = $n - $nc; if ($c -gt $crownPop) { $c = $crownPop } }
  return [pscustomobject]@{ crown = $c; noncrown = $nc; drawn = ($c + $nc) }
}

function Select-SampleCells($cells, [string]$seed, [int]$take) {
  # Score, then sort by (score, key). The key tiebreak is what keeps the draw stable if two hashes ever
  # collide AND stops Sort-Object's unstable sort from making a re-run differ from the first run.
  if ($take -le 0) { return @() }
  $scored = @()
  foreach ($c in $cells) {
    $k = ([string]$c.id) + '|' + ([string]$c.store)
    $scored += [pscustomobject]@{ cell = $c; key = $k; score = (Get-SampleScore $seed $k) }
  }
  $ordered = @($scored | Sort-Object @{Expression = 'score'}, @{Expression = 'key'})
  $out = @()
  for ($i = 0; $i -lt $take -and $i -lt $ordered.Count; $i++) { $out += $ordered[$i] }
  return $out
}

function Get-Ticket([string]$seed, [string]$key) {
  # The blind worklist identifies a cell by an opaque ticket, not by its board row, so a verifier cannot
  # casually grep the board for the answer they are supposed to produce independently. This is a procedural
  # blind, not a cryptographic one - anyone with the repo and this script can recompute it. It is here to
  # make leaking the answer take a deliberate act instead of an idle glance.
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('ticket|' + $seed + '|' + $key)) }
  finally { $sha.Dispose() }
  $s = ''
  for ($i = 0; $i -lt 5; $i++) { $s += ('{0:x2}' -f $b[$i]) }
  return $s.ToUpper()
}
# ---------------------------------------------------------------------------------------------------------
# END-SAMPLE-DRAW
# ---------------------------------------------------------------------------------------------------------

# ---- find the board ------------------------------------------------------------------------------------
if (-not $CompareFile) {
  $boards = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue |
              Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
  if ($boards.Count -eq 0) {
    Say 'verification-sample: BLIND - no comparison-<date>.json in out\, zero cells drawn; this sampler proved NOTHING (comparison-*.json is gitignored, so a fresh clone always lands here).'
    exit 3
  }
  $CompareFile = $boards[0].FullName
}
if (-not (Test-Path $CompareFile)) { Say ('verification-sample: BLIND - board file not found: ' + $CompareFile); exit 3 }

# ((Get-Content -Raw) + '') because [string]$null is $null in 5.1, so .Trim() THROWS on a zero-byte file;
# and '' | ConvertFrom-Json returns $null WITHOUT throwing, so the emptiness is tested by hand.
$raw = ((Get-Content $CompareFile -Raw -Encoding UTF8) + '')
if ($raw.Trim().Length -eq 0) { Say ('verification-sample: BLIND - board file is empty: ' + $CompareFile); exit 3 }
try { $board = $raw | ConvertFrom-Json } catch { Say ('verification-sample: BLIND - board file is not JSON: ' + $_.Exception.Message); exit 3 }
if ($null -eq $board -or $null -eq $board.comparison) { Say ('verification-sample: BLIND - board has no .comparison array: ' + $CompareFile); exit 3 }

$mDate = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($CompareFile), '(\d{4}-\d{2}-\d{2})$')
$boardDate = if ($mDate.Success) { $mDate.Groups[1].Value } else { (Get-Date -Format 'yyyy-MM-dd') }
if (-not $Seed) { $Seed = $boardDate }

# ---- flatten the board into cells ----------------------------------------------------------------------
$crownCells = New-Object System.Collections.ArrayList
$otherCells = New-Object System.Collections.ArrayList
foreach ($r in $board.comparison) {
  $cheap = [string]$r.cheapest_store
  foreach ($s in @($r.stores)) {
    if ($null -eq $s.per_unit) { continue }          # an unpriced cell publishes no number to be wrong about
    # -Store scopes the draw to named stores (C3, 2026-08-02). The whole-board sample answers "how accurate
    # is the board"; it cannot answer "how accurate is ALDI", because a proportional draw gives each store
    # ~14% of n and a 5-defect stratum quotes nothing useful. Aldi and Fareway had never been measured at
    # all, and they are the two stores whose prices come from an Instacart storefront rather than a
    # first-party feed - the one architecture that has already served us a marked-up catalogue.
    # It filters the POPULATION before the draw, so the crown/other stratification, the deterministic hash
    # ordering and the reweighting downstream all keep working unchanged on the smaller population.
    if ($Store.Count -gt 0 -and ($Store -notcontains ([string]$s.store))) { continue }
    $isCrown = ($cheap -ne '' -and ([string]$s.store) -eq $cheap)
    $cell = [pscustomobject]@{
      id       = [string]$r.id
      label    = [string]$r.commodity
      unit     = [string]$r.unit
      store    = [string]$s.store
      crown    = $isCrown
      item     = [string]$s.item          # SEALED - key file only, never the worklist
      size     = [string]$s.size          # SEALED
      ad       = [string]$s.ad            # SEALED
      per_unit = [double]$s.per_unit      # SEALED
      type     = [string]$s.type          # SEALED
    }
    if ($isCrown) { [void]$crownCells.Add($cell) } else { [void]$otherCells.Add($cell) }
  }
}
# @() around a List/ArrayList THROWS ArgumentException in 5.1 - .ToArray() is the safe conversion.
$crownArr = $crownCells.ToArray()
$otherArr = $otherCells.ToArray()
$popCrown = $crownArr.Count
$popOther = $otherArr.Count
$popAll   = $popCrown + $popOther
if ($popAll -eq 0) {
  Say ('verification-sample: BLIND - the board at ' + (Split-Path $CompareFile -Leaf) + ' flattened to ZERO priced cells (stores[]/.per_unit renamed?); a sample of nothing proves nothing.')
  exit 3
}

$alloc = Get-StratumAllocation $N $CrownShare $popCrown $popOther
if ($alloc.drawn -eq 0) { Say 'verification-sample: BLIND - allocation drew 0 cells (check -N).'; exit 3 }

$picked = @()
$picked += @(Select-SampleCells $crownArr $Seed $alloc.crown)
$picked += @(Select-SampleCells $otherArr $Seed $alloc.noncrown)

# INTERLEAVE THE STRATA BEFORE NUMBERING. Drawn stratum by stratum, the worklist arrives as a block of 60
# crown rows followed by a block of 40 non-crown rows, and the 60/40 default is documented at the top of
# this file - so ROW POSITION ALONE tells the verifier which cells the board calls cheapest. That is the
# crown flag, published in the ordering instead of in a column, and a column check cannot see it. Re-sort
# the whole draw by an INDEPENDENT hash of the same key ('order|' + seed, so it cannot correlate with the
# selection score) and the two strata come out shuffled together. This changes only the ORDER of the rows,
# never WHICH cells were drawn, and it is deterministic like everything else here: same board + same seed
# rebuilds the same worklist byte for byte.
$withOrder = @()
foreach ($p in $picked) {
  $withOrder += [pscustomobject]@{ cell = $p.cell; key = $p.key; ord = (Get-SampleScore ('order|' + $Seed) $p.key) }
}
$picked = @($withOrder | Sort-Object @{Expression = 'ord'}, @{Expression = 'key'})

# ---- write the sealed key ------------------------------------------------------------------------------
$keyRows = @()
$wlRows  = @()
$i = 0
foreach ($p in $picked) {
  $i++
  $t = Get-Ticket $Seed $p.key
  $c = $p.cell
  $keyRows += [pscustomobject]@{
    ticket = $t; seq = $i; id = $c.id; label = $c.label; unit = $c.unit; store = $c.store
    stratum = $(if ($c.crown) { 'crown' } else { 'noncrown' })
    board_item = $c.item; board_size = $c.size; board_ad = $c.ad
    board_per_unit = $c.per_unit; board_type = $c.type
  }
  $wlRows += [pscustomobject]@{ ticket = $t; seq = $i; label = $c.label; unit = $c.unit; store = $c.store }
}

$keyObj = [pscustomobject]@{
  schema      = 1
  board_date  = $boardDate
  board_file  = (Split-Path $CompareFile -Leaf)
  drawn_at    = (Get-Date -Format 's')
  seed        = $Seed
  crown_share = $CrownShare
  n_requested = $N
  n_drawn     = $picked.Count
  strata      = [pscustomobject]@{
    crown    = [pscustomobject]@{ population = $popCrown; sampled = $alloc.crown }
    noncrown = [pscustomobject]@{ population = $popOther; sampled = $alloc.noncrown }
  }
  # WHICH POPULATION THIS RUN ESTIMATES (2026-08-02, added with -Store). A store-scoped draw and a
  # whole-board draw are samples of DIFFERENT populations, and pooling them produces a number that
  # describes neither: the first run of an Aldi+Fareway sample pooled straight into the previous
  # whole-board run and reported 14 defects - including Sam's Club, Hy-Vee and Walmart cells - against a
  # 760-cell Aldi+Fareway denominator. record-sample-verdict pools only runs whose scope matches this.
  store_scope = $(if ($Store.Count -gt 0) { (@($Store) | Sort-Object) -join '+' } else { 'whole-board' })
  population  = $popAll
  cells       = $keyRows
}
$keyPath = Join-Path $outDir ('verification-sample-' + $boardDate + '.json')
$wlPath  = Join-Path $outDir ('verification-worklist-' + $boardDate + '.csv')
if ((Test-Path $keyPath) -and -not $Force) {
  Say ('verification-sample: a sample for ' + $boardDate + ' already exists (' + (Split-Path $keyPath -Leaf) + ').')
  Say '  Re-drawing would silently replace a worklist someone may already be verifying, and re-drawing until'
  Say '  the answer is convenient is exactly how a sample stops being a sample. Pass -Force to overwrite.'
  exit 0
}

$enc = New-Object System.Text.UTF8Encoding($false)   # BOM-less, like the rest of the tree
# -Compress: the key file is TRACKED (out\comparison-*.json is gitignored, so the board it describes is gone
# next week and this is the only surviving record of what the board claimed for these cells). Indented it is
# 62 KB a week = 3.2 MB a year of git; compressed it is 27 KB = 1.4 MB. Any JSON reader pretty-prints it.
[IO.File]::WriteAllText($keyPath, ($keyObj | ConvertTo-Json -Depth 6 -Compress), $enc)

# ---- write the BLIND worklist --------------------------------------------------------------------------
function CsvCell([string]$v) { if ($null -eq $v) { $v = '' }; return '"' + ($v -replace '"', '""') + '"' }
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('# BLIND verification worklist for the ' + $boardDate + ' board. Fill in verdict/found_product/found_price.')
[void]$lines.Add('# verdict must be one of: ok | wrong-product | wrong-price | wrong-size | missing | unverifiable')
[void]$lines.Add('#   ok            the board names the cheapest qualifying product at this store and its price is right')
[void]$lines.Add('#   wrong-product the product on the board is not this commodity at all (the cat-food-as-salmon class)')
[void]$lines.Add('#   wrong-price   right product, wrong number')
[void]$lines.Add('#   wrong-size    right product, but the size/pack basis makes the per-unit wrong')
[void]$lines.Add('#   missing       the store does not sell this commodity at all')
[void]$lines.Add('#   unverifiable  bot wall, sign-in wall, or the store site would not answer. NOT a defect and NOT a pass;')
[void]$lines.Add('#                 these are dropped from the denominator and reported separately.')
[void]$lines.Add('# DO NOT open out\verification-sample-' + $boardDate + '.json until every verdict is filled in.')
[void]$lines.Add('ticket,seq,commodity,unit,store,verdict,found_product,found_price,note')
foreach ($w in $wlRows) {
  [void]$lines.Add((CsvCell $w.ticket) + ',' + $w.seq + ',' + (CsvCell $w.label) + ',' + (CsvCell $w.unit) + ',' + (CsvCell $w.store) + ',,,,')
}
[IO.File]::WriteAllText($wlPath, (($lines.ToArray()) -join "`r`n") + "`r`n", $enc)

# ---- report ---------------------------------------------------------------------------------------------
Say ('verification-sample: drew ' + $picked.Count + ' of ' + $popAll + ' priced cells from ' + (Split-Path $CompareFile -Leaf) + ' (seed=' + $Seed + ', deterministic - re-running reproduces this exact worklist)')
Say ('  crown stratum    : ' + $alloc.crown + ' sampled of ' + $popCrown + ' (' + ('{0:N1}' -f (100.0 * $popCrown / $popAll)) + '% of the board)')
Say ('  non-crown stratum: ' + $alloc.noncrown + ' sampled of ' + $popOther + ' (' + ('{0:N1}' -f (100.0 * $popOther / $popAll)) + '% of the board)')
Say '  (the two strata are INTERLEAVED in the worklist on purpose - row position must not reveal the crown)'
if ($alloc.crown -gt 0 -and $CrownShare -gt ([double]$popCrown / [double]$popAll)) {
  Say '  NOTE: crowns are OVER-sampled on purpose. The crown defect rate this produces is NOT the board rate.'
  Say '        record-sample-verdict.ps1 reweights by the populations above; do not quote the crown number alone.'
}
$byStore = @{}
foreach ($w in $wlRows) { if ($byStore.ContainsKey($w.store)) { $byStore[$w.store]++ } else { $byStore[$w.store] = 1 } }
Say '  by store:'
foreach ($kv in ($byStore.GetEnumerator() | Sort-Object Value -Descending)) { Say ('    ' + $kv.Key + ' = ' + $kv.Value) }
Say ('  BLIND worklist -> ' + $wlPath)
Say ('  SEALED key     -> ' + $keyPath + '   (do not open it until the verdicts are in)')
Say '  Verify each row by opening the STORE''s own site and finding the cheapest product that really is that'
Say ('  commodity, in that unit. Then: powershell -File record-sample-verdict.ps1 -VerdictFile "' + $wlPath + '"')

# ---- THE BACKLOG WARNING --------------------------------------------------------------------------------
# The classic way a sampling programme dies is not that it finds nothing; it is that the sample keeps getting
# DRAWN and never verified, and the resulting absence of a defect rate reads, week after week, as a clean
# board. Every sample that was drawn and never adjudicated is named here, on the one job that runs weekly.
# This cannot cry wolf: a prior sample either has a recorded run in the history or it does not.
$histFile = Join-Path $outDir 'verification-history.json'
$done = @{}
if (Test-Path $histFile) {
  $ht = ((Get-Content $histFile -Raw -Encoding UTF8) + '')
  if ($ht.Trim().Length -gt 0) {
    try { $hj = $ht | ConvertFrom-Json } catch { $hj = $null }
    if ($null -ne $hj -and $null -ne $hj.runs) { foreach ($hr in @($hj.runs)) { $done[[string]$hr.board_date] = $true } }
  }
}
$stale = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem (Join-Path $outDir 'verification-sample-*.json') -ErrorAction SilentlyContinue)) {
  $md = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')
  if (-not $md.Success) { continue }
  $d = $md.Groups[1].Value
  if ($d -eq $boardDate) { continue }
  if (-not $done.ContainsKey($d)) { [void]$stale.Add($d) }
}
if ($stale.Count -gt 0) {
  Say ''
  Say ('  *** ' + $stale.Count + ' EARLIER SAMPLE(S) WERE DRAWN AND NEVER VERIFIED: ' + ((@($stale.ToArray()) | Sort-Object) -join ', '))
  Say '      Nothing outside this pipeline has graded the board since then. A drawn-but-unverified sample is'
  Say '      not evidence of anything, and its silence must not be read as a clean board.'
}
exit 0

