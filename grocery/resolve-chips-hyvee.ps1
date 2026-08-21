<#
  resolve-chips-hyvee.ps1 - close Hy-Vee NO-LINK board chips headlessly.

  Input : out\url-inputs\chips-hyvee.json (from build-chips-from-tileintegrity.ps1:
          {id, q:'<generic search term>', match:'<board product name>', size, pu, unit})
  Output: out\url-inputs\store-hyvee-nolink-urls.json for merge-product-urls.ps1

  Same discipline as resolve-hyvee-links.ps1 (the REST search + SIZE-FIRST matching that has repeatedly
  kept wrong SKUs off the board), plus STORE-WHAT-YOU-AUDIT: every emitted row re-prices through
  Get-LinkPerUnit exactly as the pruner will, and rows whose per-unit disagrees with the BOARD per-unit
  by more than the one tolerance (0.32, half-cent floor) are refused here, not deleted tomorrow.
  A chip we cannot match is SKIPPED and named - never guessed.
#>
param([switch]$Apply, [int]$StoreId = 0)   # 0 = ask hyvee-store-lib; see that file
$ErrorActionPreference = 'Stop'
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
    catch { Start-Sleep -Milliseconds 700 }
  }
  return @()
}
function Norm([string]$s) { return (([string]$s).ToLower() -replace "['’!]", '' -replace '[^a-z0-9 ]',' ' -replace '\s+',' ').Trim() }
function WordOverlap([string]$a, [string]$b) {
  $wa = @((Norm $a) -split ' ' | Where-Object { $_.Length -ge 3 })
  if (-not $wa.Count) { return 0.0 }
  $nb = ' ' + (Norm $b) + ' '
  $hit = 0; foreach ($w in $wa) { if ($nb.Contains(' ' + $w + ' ')) { $hit++ } }
  return $hit / $wa.Count
}

$chipsDoc = Get-Content (Join-Path $root 'out\url-inputs\chips-hyvee.json') -Raw | ConvertFrom-Json; $chips = @($chipsDoc)
Write-Output ("chips to resolve: " + $chips.Count)

# cell TYPE decides which write-gate applies. EVERYDAY cells: the stored price must re-derive the board
# per-unit (prune enforces it daily). SALE cells: the board shows an AD price the shelf price will not equal -
# prune skips them and SeeLink validates identity + a sanity band at build - so demanding shelf==ad here would
# refuse every correct link. Identity (size-first + name) is still required for both.
$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cellType = @{}
foreach ($row in ((Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison)) {
  foreach ($s in $row.stores) { if ([string]$s.store -eq 'Hy-Vee') { $cellType[[string]$row.id] = [string]$s.type } }
}

$out = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
foreach ($c in $chips) {
  $cands = Search-HyVee ([string]$c.q)
  Start-Sleep -Milliseconds 500
  $best = $null; $bestScore = 0.0
  foreach ($p in $cands) {
    # response shape (probed 2026-07-17): id, description (the NAME), pricing.tagPriceValue/basePriceValue,
    # unitOfMeasure (the SIZE), isWeighted, isSponsored
    $prodId = [string]$p.id
    if ($prodId -notmatch '^\d+$') { continue }
    $nm = [string]$p.description
    if (-not $nm) { continue }
    $priceV = 0.0
    if ($p.pricing) {
      if ($p.pricing.tagPriceValue) { $priceV = [double]$p.pricing.tagPriceValue }
      elseif ($p.pricing.basePriceValue) { $priceV = [double]$p.pricing.basePriceValue }
    }
    $sz = [string]$p.unitOfMeasure
    # SIZE-FIRST: candidate quantity must match the chip's size when both are computable
    $cQty = 0.0; $pQty = 0.0
    $cpu = Get-LinkPerUnit -size ([string]$c.size) -unit ([string]$c.unit) -price 1 -name ([string]$c.match)
    $ppu = Get-LinkPerUnit -size $sz -unit ([string]$c.unit) -price 1 -name $nm
    if ($null -eq $cpu -or $null -eq $ppu -or [double]$cpu -le 0 -or [double]$ppu -le 0) { continue }   # UNKNOWN IS NOT A PASS: an uncomputable size cannot prove identity; the 144ct-vs-280ct tissues bug shipped through this exact gap
if ($true) {
      $cQty = 1.0 / [double]$cpu; $pQty = 1.0 / [double]$ppu
      if ([math]::Abs($cQty - $pQty) / [math]::Max($cQty, 0.0001) -gt 0.06) { continue }
    }
    $s = WordOverlap $c.match $nm
    if ($s -gt $bestScore) { $bestScore = $s; $best = [pscustomobject]@{ id=$prodId; name=$nm; price=$priceV; size=$sz } }
  }
  if (-not $best -or $bestScore -lt 0.6) { $skipped.Add(('  {0,-22} {1,-40} no confident match (best {2:P0})' -f $c.id, $c.match, $bestScore)); continue }
  if ($best.price -le 0) { $skipped.Add(('  {0,-22} {1,-40} matched but no price on candidate' -f $c.id, $c.match)); continue }

  # STORE WHAT YOU AUDIT - but audit as the pruner will. EVERYDAY: stored record must re-price to within
  # 0.32/half-cent of the BOARD per-unit. SALE: prune skips the price test (ad price != shelf price by
  # definition); identity was enforced above and SeeLink re-checks name + band at every build.
  $ct = [string]$cellType[[string]$c.id]
  if ($ct -eq 'everyday' -or -not $ct) {
    $storedPU = Get-LinkPerUnit -size ([string]$best.size) -unit ([string]$c.unit) -price ([double]$best.price) -name ([string]$best.name)
    $bpu = [double]$c.pu
    if ($null -eq $storedPU) { $skipped.Add(('  {0,-22} {1,-40} unpriceable stored form' -f $c.id, $c.match)); continue }
    if ($bpu -gt 0 -and ([math]::Abs([double]$storedPU - $bpu) / $bpu -gt 0.32) -and ([math]::Abs([double]$storedPU - $bpu) -gt 0.005)) {
      $skipped.Add(('  {0,-22} {1,-40} price disagrees with board ({2} vs {3})' -f $c.id, $c.match, [math]::Round([double]$storedPU,4), $bpu)); continue
    }
  }

  $slug = ((([string]$best.name).ToLower() -replace '[^a-z0-9]+','-').Trim('-'))
  if ($slug.Length -gt 80) { $slug = $slug.Substring(0,80).TrimEnd('-') }
  $out.Add([pscustomobject]@{
    id = [string]$c.id
    url = ('https://www.hy-vee.com/aisles-online/p/' + $best.id + '/' + $slug)
    name = [string]$best.name
    price = ('$' + $best.price)
    size = [string]$best.size
  })
  Write-Output ('  RESOLVED {0,-20} -> {1}  ({2}, {3})' -f $c.id, $best.name, ('$' + $best.price), $best.size)
}

Write-Output ''
Write-Output ("resolved: " + $out.Count + "   skipped: " + $skipped.Count)
foreach ($s in $skipped) { Write-Output $s }
if ($Apply -and $out.Count) {
  $p = Join-Path $root 'out\url-inputs\store-hyvee-nolink-urls.json'
  ($out | ConvertTo-Json -Depth 4) | Set-Content $p -Encoding UTF8
  Write-Output ("written: " + $p)
}

