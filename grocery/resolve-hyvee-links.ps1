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
param([switch]$WhatIf, [int]$StoreId = 1465)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
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
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $units[[string]$c.id] = [string]$c.unit }

$regF = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
$rows = @((Get-Content $regF.FullName -Raw | ConvertFrom-Json).deals)
$unver = @{}
foreach ($r in $rows) { if ($r.not_reverified) { $unver[([string]$r.item).Trim()] = $r } }

$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$board = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)

$puF = Join-Path $root 'product-urls.json'
$doc = Get-Content $puF -Raw | ConvertFrom-Json

# only bother with unverified rows that are actually SERVING a board cell
$targets = New-Object System.Collections.ArrayList
foreach ($it in $board) {
  $cell = $it.stores | Where-Object { $_.store -eq 'Hy-Vee' } | Select-Object -First 1
  if (-not $cell) { continue }
  $nm = ([string]$cell.item).Trim()
  if (-not $unver.ContainsKey($nm)) { continue }
  # Take EVERY unverified row, linked or not. A row can be unverified for two different reasons and both need
  # the same repair:
  #   * no link at all - there is no product id to fetch a price with;
  #   * a link whose product id is a DIFFERENT SIZE than our row (the pull refuses those: Hy-Vee reuses names
  #     across sizes, so "Hy-Vee 100% Orange Juice" resolved to the 1 gallon jug while our row is the 64 oz).
  # In both cases the answer is to find the product that actually matches our size and point the link at it.
  $ex = $doc.items.($it.id).'Hy-Vee'
  $had = [bool]($ex -and $ex.url)
  [void]$targets.Add([pscustomobject]@{ id=[string]$it.id; unit=[string]$it.unit; name=$nm; row=$unver[$nm]; relink=$had })
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
  $price = [double]$best.pricing.tagPriceValue

  Write-Output ('  + {0,-22} id={1,-9} ${2,-8} {3,-12} {4}  (name match {5}%)' -f $t.id, [string]$best.id, $price, ([string]$best.unitOfMeasure), [string]$best.description, [math]::Round($bestScore*100))

  if (-not $WhatIf) {
    if (-not $doc.items.($t.id)) { continue }
    $entry = [pscustomobject]@{
      url      = $url
      price    = $price
      size     = $ourSize                       # keep OUR validated size, not Hy-Vee's
      name     = $t.name                        # keep the board's product name so matching stays stable
      verified = ((Get-Date -Format 'yyyy-MM-dd') + ' Hy-Vee search API (storeId ' + $StoreId + ')')
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
