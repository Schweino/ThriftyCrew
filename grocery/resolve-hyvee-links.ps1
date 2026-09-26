<#
  resolve-hyvee-links.ps1

  pull-regular-hyvee.ps1 can only re-verify a Hy-Vee price if we hold a LINK to that product, because the
  product id lives in the link URL. Rows without one get carried at their last known price and honestly
  flagged `not_reverified` - but "we could not check this" is not the same as "this is right", and 19 of them
  were serving live board cells. So: find those products on Hy-Vee, store the link, and let the daily pull
  verify them from then on.

  Hy-Vee's search is a plain REST endpoint (POST /aisles-online/api/search/products) that takes storeId in the
  BODY, so this runs headless with no session - same as the price pull.

  MATCHING IS BY SIZE FIRST, NAME SECOND. Name similarity on its own has repeatedly picked the wrong SKU on
  this project (a 3 oz spice jar for a 10.5 oz cell, a 12-pack case of hominy, the 1-gallon orange juice for a
  64 oz row). A candidate is only accepted when its quantity MATCHES the size we already hold - otherwise the
  price we later fetch would be a real price attached to the wrong quantity, which is the most dangerous kind
  of wrong: internally consistent and completely false.
#>
# The self-test is pure in-memory fixtures and runs before any library or data file is loaded.
# gate-inputs: grocery\resolve-hyvee-links.ps1
param([switch]$WhatIf, [int]$StoreId = 0, [string[]]$Ids = @(), [switch]$SelfTest)   # 0 = ask hyvee-store-lib; see that file
$ErrorActionPreference = 'Stop'

# ---- THE SIZE-CONFLICT RELINK QUEUE (2026-09-25, triage 2026-09-25-c2a750) ------------------------------
# pull-regular-hyvee.ps1 refuses an answer whose size differs from the worklist variant ("source product size
# conflicts with the worklist variant") and, since 90de7b, parks that product id in out\hyvee-ask-ledger.json
# until the binding moves. Nothing moved it: the three queues below all start from a Hy-Vee cell ON THE BOARD,
# and a refused product has no fresh row, so its cell drops off the board and the resolver never sees it again.
# Measured 2026-09-25: 12 pids refused this way on every run 09-23..09-25; every one is a product-urls.json link,
# and 9 of their 12 commodities had no Hy-Vee cell on the 09-23 board. So a link whose product id the pull last
# refused for size is a DRIFTED LINK, whether or not its cell is on the board, and it goes through the same
# size-first search as every other target: re-pointed only to a product AT THE LINK'S SIZE, never to Hy-Vee's
# other size. Pure; the caller reads the files.
$script:HvSizeConflictReason = 'source product size conflicts with the worklist variant'   # pull-regular-hyvee.ps1's reason text
function Get-HyVeeSizeConflictRelinkTargets {
  param($Ledger, $Items, $Rows, [hashtable]$Units, [hashtable]$Seen, [string[]]$Ids = @())
  $out = New-Object System.Collections.ArrayList
  if ($null -eq $Ledger -or $null -eq $Items) { return ,$out.ToArray() }
  $parked = @{}
  foreach ($pr in @($Ledger.PSObject.Properties)) {
    if ([string]::Equals([string]$pr.Value.last_outcome, $script:HvSizeConflictReason, [StringComparison]::Ordinal)) { $parked[[string]$pr.Name] = $pr.Value }
  }
  if ($parked.Count -eq 0) { return ,$out.ToArray() }
  foreach ($it in @($Items.PSObject.Properties)) {
    $id = [string]$it.Name
    $ln = $it.Value.'Hy-Vee'
    if (-not ($ln -and $ln.url)) { continue }
    if (([string]$ln.url) -notmatch '/p/(\d+)/') { continue }
    $p = $Matches[1]
    if (-not $parked.ContainsKey($p)) { continue }
    if ($Ids.Count -and ($Ids -notcontains $id)) { continue }
    if ($Seen.ContainsKey($id)) { continue }
    $lsize = ([string]$ln.size).Trim()
    # The ledger records the worklist size that conflicted ('' for a link-only product). A link whose size has
    # moved since is no longer the parked binding: the pull unparks it and asks again, so leave it alone.
    $wsize = ([string]$parked[$p].size).Trim()
    if ($wsize -ne '' -and -not [string]::Equals($wsize, $lsize, [StringComparison]::Ordinal)) { continue }
    $nm = ([string]$ln.name).Trim()
    $rowA = @($Rows | Where-Object { ([string]$_.item).Trim() -eq $nm -and ([string]$_.size).Trim() -eq $lsize })
    $row = if ($rowA.Count) { $rowA[0] } else { [pscustomobject]@{ size = $lsize; ad_price = '' } }
    $Seen[$id] = $true
    [void]$out.Add([pscustomobject]@{ id = $id; unit = [string]$Units[$id]; name = $nm; row = $row; relink = $true; parked_pid = [int]$p; theirs = [string]$parked[$p].theirs })
  }
  return ,$out.ToArray()
}
# A search that still names the parked product id at our size makes no progress: say so, and write nothing.
function Test-HyVeeRelinkNoProgress($Target, [string]$BestId) {
  return [bool]($Target.PSObject.Properties['parked_pid'] -and ([string][int]$Target.parked_pid -eq $BestId))
}

if ($SelfTest) {
  $fail = 0; $n = 0
  function _RT([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok   ' + $label) } else { $script:fail++; Write-Output ('FAIL ' + $label + '  got=' + $got) } }
  try {
    $rsn = $script:HvSizeConflictReason
    $led = [pscustomobject]@{
      '11342'   = [pscustomobject]@{ last_asked = '2026-09-25'; last_outcome = $rsn; streak = 3; size = '38 oz'; theirs = '20 oz' }
      '2950925' = [pscustomobject]@{ last_asked = '2026-09-25'; last_outcome = $rsn; streak = 3; size = '' }
      '47144'   = [pscustomobject]@{ last_asked = '2026-09-25'; last_outcome = $rsn; streak = 3; size = '20 oz' }
      '444508'  = [pscustomobject]@{ last_asked = '2026-09-25'; last_outcome = 'success'; streak = 0; size = '15 oz' }
    }
    $items = [pscustomobject]@{
      'beef-stew'        = [pscustomobject]@{ 'Hy-Vee' = [pscustomobject]@{ url = 'https://www.hy-vee.com/aisles-online/p/11342/dinty-moore-beef-stew'; name = 'Dinty Moore Beef Stew'; size = '38 oz' } }
      'ground-cinnamon'  = [pscustomobject]@{ 'Hy-Vee' = [pscustomobject]@{ url = 'https://www.hy-vee.com/aisles-online/p/2950925/thats-smart-ground-cinnamon'; name = "That's Smart Ground Cinnamon"; size = '2.5 oz' } }
      'corned-beef-hash' = [pscustomobject]@{ 'Hy-Vee' = [pscustomobject]@{ url = 'https://www.hy-vee.com/aisles-online/p/47144/hormel-hash'; name = 'Hormel Mary Kitchen Homestyle Corned Beef Hash'; size = '25 oz' } }
      'sloppy-joe-sauce' = [pscustomobject]@{ 'Hy-Vee' = [pscustomobject]@{ url = 'https://www.hy-vee.com/aisles-online/p/444508/hy-vee-sloppy-joe-sauce'; name = 'Hy-Vee Sloppy Joe Sauce'; size = '15 oz' } }
    }
    $rowsF = @([pscustomobject]@{ item = 'Dinty Moore Beef Stew'; size = '38 oz'; ad_price = '$6.49'; as_of = '2026-08-21'; store_id = '1465' })
    $unitsF = @{ 'beef-stew' = 'oz'; 'ground-cinnamon' = 'oz'; 'corned-beef-hash' = 'oz'; 'sloppy-joe-sauce' = 'oz' }

    # MUST FIRE: the founding shape, a link whose product id the pull refused for size and whose cell is off the board.
    $t1 = Get-HyVeeSizeConflictRelinkTargets -Ledger $led -Items $items -Rows $rowsF -Units $unitsF -Seen @{}
    $t1a = @($t1)
    $bs = @($t1a | Where-Object { $_.id -eq 'beef-stew' })
    _RT 'MUST FIRE: size-conflict pid 11342 (beef-stew, no board cell) becomes a relink target at the LINK size 38 oz' (($bs.Count -eq 1) -and ([bool]$bs[0].relink) -and ($bs[0].row.size -eq '38 oz') -and ($bs[0].parked_pid -eq 11342)) ("$($bs.Count)")
    _RT 'MUST FIRE: the target carries the row the link names, so gate 4 has a price to corroborate ($6.49)' (($bs.Count -eq 1) -and ($bs[0].row.ad_price -eq '$6.49')) ("$($bs[0].row.ad_price)")
    $gc = @($t1a | Where-Object { $_.id -eq 'ground-cinnamon' })
    _RT 'MUST FIRE: a link-only size conflict (ledger size empty) is queued at the link size 2.5 oz' (($gc.Count -eq 1) -and ($gc[0].row.size -eq '2.5 oz')) ("$($gc.Count)")
    # MUST NOT FIRE: a success pid, and a link whose size moved since the conflict (the pull unparks that one itself).
    _RT 'MUST NOT FIRE: a pid whose last ask succeeded (444508) is not queued' (@($t1a | Where-Object { $_.id -eq 'sloppy-joe-sauce' }).Count -eq 0) ''
    _RT 'MUST NOT FIRE: a link whose size moved off the conflicted size (47144, 20 oz -> 25 oz) is not queued' (@($t1a | Where-Object { $_.id -eq 'corned-beef-hash' }).Count -eq 0) ''
    _RT 'exactly 2 targets from the 4-link fixture' ($t1a.Count -eq 2) ("$($t1a.Count)")
    # MUST NOT FIRE: an id the board queues already hold is not queued twice.
    $seen = @{ 'beef-stew' = $true }
    $t2 = Get-HyVeeSizeConflictRelinkTargets -Ledger $led -Items $items -Rows $rowsF -Units $unitsF -Seen $seen
    $t2a = @($t2)
    _RT 'MUST NOT FIRE: a commodity already targeted from the board is not added twice' (@($t2a | Where-Object { $_.id -eq 'beef-stew' }).Count -eq 0) ("$($t2a.Count)")
    # MUST NOT FIRE: no ledger yet (the day before the first ledger run) leaves the queues exactly as they were.
    $t3 = Get-HyVeeSizeConflictRelinkTargets -Ledger $null -Items $items -Rows $rowsF -Units $unitsF -Seen @{}
    $t3a = @($t3)
    _RT 'MUST NOT FIRE: a missing ledger adds no target' ($t3a.Count -eq 0) ("$($t3a.Count)")
    # CLEAN TWIN: -Ids still scopes the run to the named commodities.
    $t4 = Get-HyVeeSizeConflictRelinkTargets -Ledger $led -Items $items -Rows $rowsF -Units $unitsF -Seen @{} -Ids @('ground-cinnamon')
    $t4a = @($t4)
    _RT 'CLEAN TWIN: -Ids ground-cinnamon targets exactly ground-cinnamon' (($t4a.Count -eq 1) -and ($t4a[0].id -eq 'ground-cinnamon')) ("$($t4a.Count)")
    # MUST FIRE / CLEAN TWIN of the no-progress guard.
    _RT 'MUST FIRE: a search whose best match is the parked pid 11342 again is no progress' (Test-HyVeeRelinkNoProgress $bs[0] '11342') ''
    _RT 'MUST NOT FIRE: a search that finds another product id (11999) at our size is progress' (-not (Test-HyVeeRelinkNoProgress $bs[0] '11999')) ''
    $plainT = [pscustomobject]@{ id = 'x'; relink = $true }
    _RT 'MUST NOT FIRE: a board-queue target with no parked pid is never blocked by the guard' (-not (Test-HyVeeRelinkNoProgress $plainT '11342')) ''
  } catch { $fail++; Write-Output ('FAIL self-test threw: ' + $_.Exception.Message) }
  if ($n -ne 12) { $fail++; Write-Output ("FAIL expected 12 cases, ran $n") }
  if ($fail -eq 0) { Write-Output "resolve-hyvee-links self-test pass ($n cases)"; exit 0 }
  Write-Output "resolve-hyvee-links self-test FAIL ($fail of $n)"; exit 1
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
# 0 means 'take the store the board speaks for'. One home for the identity - see hyvee-store-lib.ps1.
. (Join-Path $root 'hyvee-store-lib.ps1')
if ($StoreId -le 0) { $StoreId = [int](Get-HyVeeStore -Root $root).store_id }

. (Join-Path $root 'pu-lib.ps1')

$EP = 'https://www.hy-vee.com/aisles-online/api/search/products'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'

function Search-HyVee([string]$term) {
  $h = @{ 'content-type'='application/json'; 'User-Agent'=$UA; 'x-hy-vee-correlation-id'=[guid]::NewGuid().ToString() }
  $b = @{ pageNumber=1; pageSize=40; searchFilters=@(); searchTerm=$term; sortDirection='RELEVANCE'; storeId=$StoreId; pageViewId=[guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
  for ($a=1; $a -le 2; $a++) {
    try { return @((Invoke-RestMethod -Uri $EP -Method Post -Headers $h -Body $b -TimeoutSec 25).results) }
    catch { Start-Sleep -Milliseconds 600 }
  }
  return @()
}
function Norm([string]$s) { return (([string]$s).ToLower() -replace '[^a-z0-9 ]',' ' -replace '\s+',' ').Trim() }
function Qty([string]$size, [string]$unit, [string]$name) {
  $pu = Get-LinkPerUnit -size $size -unit $unit -price 1 -name $name
  if ($null -eq $pu -or [double]$pu -le 0) { return 0 }
  return (1.0 / [double]$pu)
}

$units = @{}
foreach ($c in (Read-JsonFile (Join-Path $root 'commodities.json'))) { $units[[string]$c.id] = [string]$c.unit }

$regF = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$rows = @((Read-JsonFile $regF.FullName).deals)
$unver = @{}; $rowByName = @{}
foreach ($r in $rows) { $rowByName[([string]$r.item).Trim()] = $r; if ($r.not_reverified) { $unver[([string]$r.item).Trim()] = $r } }

# BOTH BOARDS (2026-08-01). This read only the main comparison, so a Hy-Vee cell that exists ONLY on the
# recipe board could never be reached by the headless resolver - it was structurally unhealable. That is
# the root cause of the consistency mismatch backlog (F5), not bad luck: four of its seven rows were
# recipe-board Hy-Vee cells (apple, parmesan-cheese, swiss-cheese, boneless-skinless-chicken-thigh), and
# withdrawing their drifted links did NOT bring them back, because withdrawal only re-enters a cell into a
# worklist this resolver never consulted. resolve-worklist.ps1 already reads recipe-board.json; this did
# not, so the two halves of the same heal loop disagreed about which cells exist.
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Read-JsonFile $cmpF).comparison)
$rbF = Join-Path $root 'out\recipe-board.json'
if (Test-Path $rbF) {
  $seenRow = @{}
  foreach ($b in $board) { $seenRow[[string]$b.id] = $true }
  foreach ($b in @((Read-JsonFile $rbF).comparison)) {
    if (-not $seenRow.ContainsKey([string]$b.id)) { $board += $b }
  }
  Write-Output ("board rows to resolve against: {0} (main + recipe-board)" -f $board.Count)
}

$puF = Join-Path $root 'product-urls.json'
$doc = Read-JsonFile $puF

# A NO-LINK chip (from the consistency report) needs the SAME board-match resolution as a not_reverified row:
# it has no product id to fetch a price with, exactly like a carried-forward row. The two lists only partly
# overlap - a row can be linked-but-suppressed by the identity gate, or unlinked-but-never-flagged - so we
# resolve the UNION. Resolving only not_reverified left the no-link gaps open forever, which is why the board
# sat at 25 linkless Hy-Vee chips.
$noLinkIds = @{}
$crF = Join-Path $root 'out\consistency-report.json'
$driftIds = @{}
if (Test-Path $crF) {
  $crDoc = Read-JsonFile $crF
  foreach ($nl in @($crDoc.no_link)) { if (([string]$nl.store) -eq 'Hy-Vee') { $noLinkIds[[string]$nl.id] = $true } }
  # THE DRIFTED-LINK QUEUE (2026-08-01, F5). The two sources above cannot reach a cell whose link is
  # PRESENT but WRONG: $unver is keyed by name off the Hy-Vee feed, and no_link only lists cells rendering
  # NO link at all. So a cell whose stored link merely drifted onto a different product sat unhealable
  # forever - that is the entire consistency mismatch backlog, and every one of its rows is a RECIPE-BOARD
  # cell. Withdrawing those links by hand did not help either: withdrawal re-enters a cell into a worklist
  # this resolver never consulted. The consistency report's `mismatch` list DOES see both boards, so it is
  # the queue the backlog was always supposed to drain into.
  foreach ($mm in @($crDoc.mismatch)) { if (([string]$mm.store) -eq 'Hy-Vee') { $driftIds[[string]$mm.id] = $true } }
  if ($driftIds.Count) { Write-Output ("drifted-link queue: {0} Hy-Vee cell(s) whose stored link no longer matches the board" -f $driftIds.Count) }
}

# every Hy-Vee board cell that is unverified OR renders no link, resolved once (by id)
$targets = New-Object System.Collections.ArrayList
$seenT = @{}
foreach ($it in $board) {
  $cell = $it.stores | Where-Object { $_.store -eq 'Hy-Vee' } | Select-Object -First 1
  if (-not $cell) { continue }
  $nm = ([string]$cell.item).Trim()
  # -Ids scopes the run to named commodities. A caller repairing the cells IT just changed must not rewrite
  # every Hy-Vee link on the board as a side effect: apply-coverage-batch's repair chain called this in bulk,
  # and that is how a one-commodity exclude re-introduced the poultry-seasoning divergence and failed the
  # publish on a row it had never touched. A repair should reach exactly as far as the thing it repairs.
  if ($Ids.Count -and ($Ids -notcontains [string]$it.id)) { continue }
  if (-not ($unver.ContainsKey($nm) -or $noLinkIds.ContainsKey([string]$it.id) -or $driftIds.ContainsKey([string]$it.id))) { continue }
  if ($seenT.ContainsKey([string]$it.id)) { continue }; $seenT[[string]$it.id] = $true
  # read our size/price from the regular row THE BOARD ACTUALLY PRICED.
  # $rowByName/$unver are keyed by NAME, and Hy-Vee sells the same name in more than one size - "Spice World
  # Minced Garlic" is both 32 oz/$8.99 and 4.5 oz/$3.49; "Hy-Vee Sloppy Joe Sauce" is both 15 oz/$0.99 and
  # 24 oz/$2.39. A name-keyed hashtable keeps only the LAST such row, so the resolver sized itself against a
  # product the board never priced and linked the wrong jar: the board published 32 oz at $0.2809/oz while the
  # link opened the 4.5 oz at $0.7756/oz. The factor guard caught both. Same family as the board-match
  # collisions already documented - a name-keyed lookup silently collapsing distinct products.
  # So: among the rows sharing this name, take the one whose SIZE matches the board cell. The board is what we
  # publish, so the board is what the link has to agree with.
  $cands = @($rows | Where-Object { ([string]$_.item).Trim() -eq $nm })
  $row = $null
  if ($cands.Count) {
    $row = $cands | Where-Object { ([string]$_.size).Trim() -eq ([string]$cell.size).Trim() } | Select-Object -First 1
    # no size-exact row: only safe to proceed if the name is unambiguous (one row). Otherwise we cannot tell
    # WHICH product the board meant, and guessing is how the wrong jar got linked in the first place.
    if (-not $row -and $cands.Count -eq 1) { $row = $cands[0] }
  }
  if (-not $row) { $row = [pscustomobject]@{ size = [string]$cell.size; ad_price = '' } }
  $ex = $doc.items.($it.id).'Hy-Vee'
  $had = [bool]($ex -and $ex.url)
  [void]$targets.Add([pscustomobject]@{ id=[string]$it.id; unit=[string]$it.unit; name=$nm; row=$row; relink=$had })
}
Write-Output ("unverified Hy-Vee rows serving a live board cell: " + $targets.Count + " (" + @($targets | Where-Object { $_.relink }).Count + " have a link pointing at the WRONG SIZE and need re-pointing)")
# The size-conflict relink queue (header above): links whose product id the pull last refused for size.
$ledF = Join-Path $root 'out\hyvee-ask-ledger.json'
$scLedger = $null
if (Test-Path -LiteralPath $ledF) {
  try { $scLedger = Read-JsonFile $ledF } catch { Write-Warning ('Hy-Vee ask ledger unreadable (' + $_.Exception.Message + ') - the size-conflict relink queue is skipped this run') }
}
$scT = Get-HyVeeSizeConflictRelinkTargets -Ledger $scLedger -Items $doc.items -Rows $rows -Units $units -Seen $seenT -Ids $Ids
$scTa = @($scT)
foreach ($x in $scTa) { [void]$targets.Add($x) }
Write-Output ("size-conflict relink queue: " + $scTa.Count + " link(s) whose product id Hy-Vee last answered at another size" + $(if ($null -eq $scLedger) { ' (no ask ledger yet)' } else { '' }))
Write-Output ''

$resolved = 0; $unresolved = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets) {
  $ourSize = [string]$t.row.size
  $ourQty  = Qty $ourSize $t.unit $t.name
  # search on the product name minus any trailing size text (Hy-Vee's descriptions rarely carry it)
  $term = ($t.name -replace '(?i)[, ]+\d+(\.\d+)?\s*(fl\s*oz|oz|lb|lbs|ct|count|pk|pack|gal|qt|pt)\.?\s*$','').Trim()
  $res = Search-HyVee $term
  Start-Sleep -Milliseconds 250

  # THE MATCH HAS TO CLEAR FOUR GATES, NOT ONE.
  # A first cut ranked purely on how many of OUR words appeared in the candidate. That is one-directional, so
  # extra words in the CANDIDATE cost nothing - and it happily matched "Hy-Vee Ranch Dressing" ($4.99) to
  # "HIDDEN VALLEY Light Ranch Salad Dressing" ($6.99), and our SCENTED cat litter to the UNSCENTED one. Both
  # would have pinned a real price from the wrong product onto the board.
  #   1. SIZE     - the quantity must equal ours, or a true price lands on a false amount.
  #   2. BRAND    - the leading token must agree. Hy-Vee is not Hidden Valley.
  #   3. NEGATION - "scented" and "unscented" are different products, however similar they look.
  #   4. PRICE or a STRONG name overlap - our stored price is independent corroboration that it is the same
  #      item; a merely-plausible name is not enough on its own.
  $ourPrice = 0.0; [void][double]::TryParse((([string]$t.row.ad_price) -replace '[^0-9.]',''), [ref]$ourPrice)
  $SIZEWORDS = @('oz','ounce','ounces','lb','lbs','pound','pounds','fl','ct','count','pk','pack','gal','gallon','qt','pint','pt','each','ea','dozen','size')
  $ourWords = @((Norm ($t.name -replace '(?i)[, ]+\d+(\.\d+)?\s*(fl\s*oz|oz|lb|lbs|ct|count|pk|pack|gal|qt|pt)\.?\s*$','')) -split ' ' | Where-Object { $_.Length -ge 3 -and ($SIZEWORDS -notcontains $_) -and ($_ -notmatch '^\d') })

  $best = $null; $bestScore = -1
  foreach ($x in $res) {
    if (-not $x.id) { continue }
    $desc = [string]$x.description
    $theirSize = [string]$x.unitOfMeasure
    $theirQty = Qty $theirSize $t.unit $desc

    # 1. SIZE
    $sizeOk = $false
    if ($ourQty -gt 0 -and $theirQty -gt 0) { $sizeOk = ([math]::Abs($theirQty - $ourQty) -le ($ourQty * 0.02)) }
    if (-not $sizeOk) { continue }

    $theirWords = @((Norm $desc) -split ' ' | Where-Object { $_.Length -ge 3 -and ($SIZEWORDS -notcontains $_) -and ($_ -notmatch '^\d') })
    if ($ourWords.Count -eq 0 -or $theirWords.Count -eq 0) { continue }

    # 2. BRAND: the leading token must agree ("hy" for Hy-Vee, "drano", "raid", "colgate"...)
    if ($ourWords[0] -ne $theirWords[0]) { continue }

    # 3. NEGATION: a word on one side whose "un-" form is on the other is a DIFFERENT product
    $neg = $false
    foreach ($w in $ourWords)   { if ($theirWords -contains ('un' + $w)) { $neg = $true } }
    foreach ($w in $theirWords) { if ($ourWords   -contains ('un' + $w)) { $neg = $true } }
    if ($neg) { continue }

    # symmetric overlap (Jaccard) - extra words in the candidate now cost something
    # WHICH JACCARD PROPERTY (2026-09-08, backlog I57): PRESENCE OVER FREQUENCY, over SETS, which
    # is what makes it symmetric and is the whole reason a long candidate is penalised for its
    # extra words. The other half of the metric is the hazard: every pair sharing NO token scores
    # identically, so Jaccard has no gradient across non-overlapping candidates and cannot rank
    # them. That is survivable here because this is a scored shortlist and not the retriever;
    # a candidate with zero overlap is not one this loop is trying to order.
    $inter = 0
    foreach ($w in $ourWords) { if ($theirWords -contains $w) { $inter++ } }
    $union = $ourWords.Count + $theirWords.Count - $inter
    $jac = 0.0
    if ($union -gt 0) { $jac = [double]$inter / [double]$union }

    # 4. PRICE agreement, or an overwhelming name match
    $priceOk = ($ourPrice -gt 0) -and ([math]::Abs([double]$x.pricing.tagPriceValue - $ourPrice) -le ($ourPrice * 0.02))
    if (-not ($priceOk -or ($jac -ge 0.8))) { continue }

    $score = $jac
    if ($priceOk) { $score += 0.25 }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $x }
  }

  if ((-not $best) -or ($bestScore -lt 0.55)) {
    # say WHAT sizes Hy-Vee actually has, so an unresolvable row is a decision we can make rather than a
    # silent gap. If none of them is our size, it is our SIZE that is suspect, not the link.
    $sizes = @($res | Where-Object { $_.description } | Select-Object -First 6 | ForEach-Object { ([string]$_.unitOfMeasure) }) -join ', '
    $unresolved.Add(('  {0,-22} no size match  (ours: {1} / {2})   Hy-Vee has: {3}' -f $t.id, $t.name, $ourSize, $sizes))
    continue
  }
  if (Test-HyVeeRelinkNoProgress $t ([string]$best.id)) {
    $unresolved.Add(('  {0,-22} size conflict stands: search names the parked product {1} at our size {2}, the product page answers {3}' -f $t.id, [string]$best.id, $ourSize, [string]$t.theirs))
    continue
  }

  $slug = ((Norm $best.description) -replace ' ','-')
  if ($slug.Length -gt 80) { $slug = $slug.Substring(0,80).TrimEnd('-') }
  $url = 'https://www.hy-vee.com/aisles-online/p/' + [string]$best.id + '/' + $slug

  # THE STORED PRICE MUST BE THE ONE THE BOARD PRICED, NOT A SECOND FETCH (2026-08-01).
  # This used to store the SEARCH endpoint's pricing.tagPriceValue, and that is the same trap
  # pull-regular-hyvee.ps1's header is written about: Hy-Vee publishes several different prices for one
  # product and only Omaha #01's storeProducts.price is the one it charges. Measured on poultry-seasoning -
  # the row that re-introduced the consistency divergence three separate times and was written off as an
  # unexplained "quality problem": the resolver found the RIGHT product (Morton & Bassett, 2.1 oz, the same
  # name and size the board holds) and stamped $9.99 beside it, while the feed the board priced says $5.81.
  # 5.81/2.1 = $2.7667/oz against 9.99/2.1 = $4.7571/oz, and guard 1's factor check hard-failed the publish
  # at 1.72x. Nothing was wrong with the MATCH; the price came from the wrong endpoint.
  # It survived because gate 4 accepts a candidate on price agreement OR an overwhelming name match, so an
  # identical name lets a disagreeing price straight through unchecked.
  # A link and its price are ONE record (derive-links-from-prices.ps1 is built on exactly this), so store
  # the price of the row the board actually published. Fall back to the search price only when we hold none
  # - and say so in `verified`, because that number is then unverified by construction.
  $price = if ($ourPrice -gt 0) { $ourPrice } else { [double]$best.pricing.tagPriceValue }
  $priceSrc = if ($ourPrice -gt 0) { 'price from the row the board priced' } else { 'price from the search API - WE HOLD NONE, so it is unverified' }

  Write-Output ('  + {0,-22} id={1,-9} ${2,-8} {3,-12} {4}  (name match {5}%)' -f $t.id, [string]$best.id, $price, ([string]$best.unitOfMeasure), [string]$best.description, [math]::Round($bestScore*100))

  if (-not $WhatIf) {
    if (-not $doc.items.($t.id)) { continue }
    $entry = [pscustomobject]@{
      url      = $url
      price    = $price
      size     = $ourSize                       # keep OUR validated size, not Hy-Vee's
      name     = $t.name                        # keep the board's product name so matching stays stable
      verified = ((Get-Date -Format 'yyyy-MM-dd') + ' Hy-Vee search API (storeId ' + $StoreId + '), ' + $priceSrc)
    }
    $doc.items.($t.id) | Add-Member -NotePropertyName 'Hy-Vee' -NotePropertyValue $entry -Force
  }
  $resolved++
}

Write-Output ''
Write-Output ("resolved  : $resolved")
Write-Output ("unresolved: " + $unresolved.Count)
foreach ($u in $unresolved) { Write-Output $u }

if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: product-urls.json not written'; return }
if ($resolved -gt 0) {
  ($doc | ConvertTo-Json -Depth 8) | Set-Content $puF -Encoding UTF8
  Write-Output ''
  Write-Output 'product-urls.json updated - re-run pull-regular-hyvee.ps1 and these will be verified daily from now on.'
}
