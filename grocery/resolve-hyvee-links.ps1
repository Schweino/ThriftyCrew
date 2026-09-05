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
param([switch]$WhatIf, [int]$StoreId = 0, [string[]]$Ids = @())   # 0 = ask hyvee-store-lib; see that file
$ErrorActionPreference = 'Stop'
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
  $crDoc = ConvertFrom-Json (Get-Content $crF -Raw)
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
