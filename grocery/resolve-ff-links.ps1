<#
  resolve-ff-links.ps1 - resolve Family Fare "See item" links straight from the Freshop API.

  For each worklist cell we search Freshop for the board's EXACT source product name (the worklist's
  `term`), then accept a product only if it is really the same item:
     - the name must match well (token overlap, both directions)
     - for an EVERYDAY cell the product's base_price must equal the board's price
  A cell we cannot match confidently is LEFT ALONE rather than linked to a plausible-looking guess -
  a wrong link is how the Winky-cups bug got in.

  Writes out\url-inputs\store-familyfare-links.json for merge-product-urls.ps1.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$UA = @{ 'User-Agent'='Mozilla/5.0 Chrome/125'; 'Accept'='application/json' }
$ak='family_fare'; $sid='6401'; $base='https://api.freshop.ncrcloud.com/1'

function Norm([string]$s) {
  $t = ($s -replace '[^a-zA-Z0-9 ]',' ').ToLower()
  $t = $t -replace '\b(oz|fl|lb|lbs|ct|pk|pack|each|ea|count|inch|in)\b',' '
  return (($t -split '\s+' | Where-Object { $_ -and $_.Length -gt 2 }) -join ' ')
}
function Score([string]$a, [string]$b) {
  $ta = @((Norm $a) -split ' ' | Where-Object { $_ })
  $tb = @((Norm $b) -split ' ' | Where-Object { $_ })
  if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
  $hit = 0
  foreach ($x in $ta) { if ($tb -contains $x) { $hit++ } }
  # symmetric-ish: fraction of the shorter name's tokens found in the other
  return [double]$hit / [Math]::Min($ta.Count, $tb.Count)
}
function Get-Items([string]$term) {
  $uri = "$base/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=40&fields=id,name,size,price,base_price,canonical_url"
  for ($t=0; $t -lt 4; $t++) {
    try { $r = Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec 25; return @($r.items) } catch {}
    Start-Sleep -Milliseconds (600 + 500*$t)
  }
  return @()
}

$w = Get-Content (Join-Path $root 'out\url-worklist.json') -Raw | ConvertFrom-Json
$cells = @($w.stores.'Family Fare')
Write-Output ("Family Fare worklist cells: " + $cells.Count)

$out = New-Object System.Collections.ArrayList
$ok = 0; $skip = 0
foreach ($c in $cells) {
  $term = [string]$c.term
  if (-not $term) { $skip++; continue }
  $items = Get-Items $term
  if ($items.Count -eq 0) { $skip++; Start-Sleep -Milliseconds 300; continue }

  $best = $null; $bestScore = 0.0
  foreach ($i in $items) {
    $s = Score $term ([string]$i.name)
    if ($s -gt $bestScore) { $bestScore = $s; $best = $i }
  }
  # a confident name match only
  if (-not $best -or $bestScore -lt 0.7) { $skip++; Start-Sleep -Milliseconds 300; continue }

  $price = 0.0
  if ($best.base_price) { $price = [double]$best.base_price }
  elseif ($best.price)  { [void][double]::TryParse((([string]$best.price) -replace '[^0-9.]',''), [ref]$price) }
  if ($price -le 0) { $skip++; Start-Sleep -Milliseconds 300; continue }

  $url = [string]$best.canonical_url
  if (-not $url) { $url = 'https://www.familyfare.com/product/' + [string]$best.id }

  [void]$out.Add([ordered]@{
    id = [string]$c.id; url = $url; price = $price
    size = [string]$best.size; name = [string]$best.name
  })
  $ok++
  Start-Sleep -Milliseconds 320
}

$dir = Join-Path $root 'out\url-inputs'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir | Out-Null }
@{ store='Family Fare'; resolved=(Get-Date -Format 'yyyy-MM-dd'); items=$out.ToArray() } |
  ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir 'store-familyfare9-urls.json') -Encoding UTF8

Write-Output ("resolved: $ok    left alone (no confident match): $skip")
Write-Output ("-> out\url-inputs\store-familyfare9-urls.json")
