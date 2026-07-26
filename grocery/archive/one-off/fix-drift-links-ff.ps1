<#
  fix-drift-links-ff.ps1 - re-point Family Fare "See item" links at THE PRODUCT THE BOARD PRICED.

  THE DESIGN FLAW THIS FIXES: resolve-familyfare-urls.ps1 picks the CHEAPEST valid match for a commodity. That
  is the right rule for choosing a PRICE and the wrong rule for choosing a LINK. The board prices whatever the
  engine picked from the store's own feed; the link then went off and found a different, cheaper product. So
  cottage-cheese|Family Fare priced "Our Family Cottage Cheese, Large Curd 24 Oz" while its link opened
  "Daisy Low Fat 2% Cottage Cheese". Price and link disagreed BY CONSTRUCTION.
  A link must open the product whose price we published. Anything else is a lie a shopper discovers at the shelf.

  So: for each drifted Family Fare cell, search Freshop for the BOARD ITEM'S OWN NAME and take the best
  name-match - never the cheapest. If nothing matches well, LEAVE THE LINK ALONE and report it; a wrong link
  replaced by a differently-wrong link is not progress.

  Read-only unless -Apply. Freshop is a plain REST API (no session, no wall), so this needs no browser.
#>
param([switch]$Apply, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$drift = @((Get-Content (Join-Path $OutDir 'name-drift.json') -Raw | ConvertFrom-Json).flags) | Where-Object { $_.store -eq 'Family Fare' }
Write-Output ("Family Fare drifted links: " + $drift.Count)
$puPath = Join-Path $root 'product-urls.json'
$puDoc = Get-Content $puPath -Raw | ConvertFrom-Json

# token overlap between the board item and a candidate name (both normalised); 1.0 = every board word present
function Score([string]$board, [string]$cand) {
  $norm = { param($x) (($x.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s{2,}', ' ').Trim() }
  $b = @((& $norm $board) -split ' ' | Where-Object { $_.Length -gt 2 })
  $c = (& $norm $cand)
  if (-not $b.Count) { return 0 }
  $hit = 0; foreach ($w in $b) { if ($c -match [regex]::Escape($w)) { $hit++ } }
  return [math]::Round($hit / $b.Count, 3)
}

$results = @()
foreach ($f in $drift) {
  $board = [string]$f.board_item
  $q = ($board -replace '[^A-Za-z0-9 ]', ' ') -replace '\s{2,}', ' '
  $q = ($q.Trim() -split ' ' | Select-Object -First 6) -join ' '
  $api = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q=' + [uri]::EscapeDataString($q)
  $best = $null; $bestScore = 0
  try {
    $resp = Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 20 -Headers @{'User-Agent' = 'Mozilla/5.0'; 'Accept' = 'application/json' }
    $items = (ConvertFrom-Json $resp.Content).items
    foreach ($it in $items) {
      $s = Score $board ([string]$it.name)
      if ($s -gt $bestScore) { $bestScore = $s; $best = $it }
    }
  } catch { Write-Output ("  ! " + $f.id + ": search failed - " + $_.Exception.Message); continue }
  $cur = $puDoc.items.($f.id).'Family Fare'
  # TAKE THE URL FROM THE API (canonical_url), NEVER BUILD ONE. Family Fare's real product URL is
  # shopfamilyfare.com/shop/<category-path>/<slug>/p/<id> - I first constructed
  # familyfaresupermarkets.com/product/<id> from the id and it would have replaced 4 wrong links with 4 BROKEN
  # ones. A wrong link at least lands on a real product; a link I invented lands on a 404. If canonical_url is
  # absent, that candidate is unusable - skip it rather than guess a shape.
  $curl = if ($best) { [string]$best.canonical_url } else { '' }
  $ok = ($best -and $bestScore -ge 0.75 -and $curl)
  $results += [pscustomobject]@{ id = $f.id; board = $board; was = [string]$f.link_name; now = $(if ($best) { [string]$best.name } else { '' }); score = $bestScore; take = $ok; url = $curl; price = $(if ($best) { [string]$best.price } else { '' }); size = $(if ($best) { [string]$best.size } else { '' }) }
  Write-Output ('')
  Write-Output ('  ' + $f.id)
  Write-Output ('    BOARD : ' + $board)
  Write-Output ('    was   : ' + $f.link_name)
  Write-Output ('    best  : ' + $(if ($best) { [string]$best.name + '   [score ' + $bestScore + ']' } else { '(no candidate)' }))
  Write-Output ('    -> ' + $(if ($ok) { 'RE-POINT' } else { 'LEAVE ALONE (no confident match; a differently-wrong link is not progress)' }))
  Start-Sleep -Milliseconds 400
}

if ($Apply) {
  $n = 0
  foreach ($r in ($results | Where-Object { $_.take })) {
    $e = $puDoc.items.($r.id).'Family Fare'
    if (-not $e) { continue }
    $e.url = $r.url
    $e.name = $r.now
    if ($r.price) { $e.price = $r.price }
    if ($r.size) { $e.size = $r.size }
    $n++
  }
  if ($n) {
    ($puDoc | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8
    Write-Output ''
    Write-Output ("APPLIED: re-pointed " + $n + " Family Fare link(s)")
  }
} else {
  Write-Output ''
  Write-Output ('DRY RUN. ' + @($results | Where-Object { $_.take }).Count + ' of ' + $results.Count + ' would be re-pointed. Pass -Apply to write.')
}
