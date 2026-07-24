<#
  refresh-bakers-links.ps1 - refresh Baker's "See item" link snapshots (price/size/name in product-urls.json)
  from the SAME Kroger-API capture that just refreshed the board prices. Built 2026-07-24.

  WHY (the Hy-Vee lesson, board-data-integrity): after a store's board prices refresh, its link snapshots
  still hold the OLD prices. Guard 4 then reads board-vs-link disagreement on every moved price, and either
  blocks the publish or prune-bad-links strips real links down to search fallbacks. Refreshing the snapshots
  from the same pull makes board and link agree by construction, because they ARE the same reading.

  MATCHING IS BY UPC, NEVER BY NAME. Every Baker's entry URL ends in the 13-digit UPC
  ("/p/<slug>/0001111089202") and Kroger's productId IS that UPC, so the match is identity-strong. Names are
  deliberately not trusted (a store renames without changing the product - the rename class in memory).

  What it updates on a UPC hit: price (current charged price), size (the RESOLVED canonical size, so pu-lib
  derives the same per-unit the board math used), name (cleaned catalog title). The url itself is only
  swapped if the capture carries a link_url for that UPC (slugs move; UPC is the identity).
  Entries whose UPC is NOT in the capture are LEFT ALONE and counted - the API missed them this run, and a
  link that was verified yesterday is still a better snapshot than a deleted one. prune-bad-links remains
  the judge of whether any surviving snapshot still agrees with the board.

  Run AFTER pull-regular-bakers-api.ps1, BEFORE compare/guards.
#>
param([string]$CaptureFile = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$today = (Get-Date).ToString('yyyy-MM-dd')

if (-not $CaptureFile) {
  $cf = Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') |
    Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } |
    Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cf) { throw 'no bakers-regular capture found' }
  $CaptureFile = $cf.FullName
}
$cap = Get-Content $CaptureFile -Raw | ConvertFrom-Json
if ([string]$cap.source -ne 'kroger-public-api') {
  Write-Output ("refresh-bakers-links: newest capture is not a kroger-api pull (source='" + [string]$cap.source + "') - nothing to refresh from. Skipping (browser-era snapshots stay as they are).")
  exit 0
}

# index the capture by UPC
$byUpc = @{}
foreach ($d in @($cap.deals)) {
  $u = [string]$d.product_id
  if ($u -and -not $byUpc.ContainsKey($u)) { $byUpc[$u] = $d }
}
Write-Output ("refresh-bakers-links: capture " + (Split-Path $CaptureFile -Leaf) + " holds " + $byUpc.Count + " UPC(s)")

$puFile = Join-Path $root 'product-urls.json'
Copy-Item $puFile (Join-Path $root ('out\product-urls.backup-bakersrefresh-' + $today + '.json')) -Force
$pu = Get-Content $puFile -Raw | ConvertFrom-Json

$hit = 0; $miss = 0; $priceMoved = 0
foreach ($ip in $pu.items.PSObject.Properties) {
  $ep = $ip.Value.PSObject.Properties["Baker's"]
  if (-not $ep -or -not $ep.Value -or -not $ep.Value.url) { continue }
  $e = $ep.Value
  $m = [regex]::Match([string]$e.url, '/(\d{13})(\?|$)')
  if (-not $m.Success) { $miss++; continue }
  $upc = $m.Groups[1].Value
  if (-not $byUpc.ContainsKey($upc)) { $miss++; continue }
  $d = $byUpc[$upc]
  $newPrice = [double]$d.current_price
  $oldPrice = 0.0; [void][double]::TryParse(([string]$e.price -replace '[^0-9.]',''), [ref]$oldPrice)
  if ([math]::Abs($newPrice - $oldPrice) -gt 0.005) { $priceMoved++ }
  $e.price = $newPrice
  $e.size  = [string]$d.size
  $e.name  = [string]$d.item
  if ($d.PSObject.Properties['link_url'] -and $d.link_url) { $e.url = [string]$d.link_url }
  if ($e.PSObject.Properties['verified']) { $e.verified = $today } else { $e | Add-Member -NotePropertyName verified -NotePropertyValue $today }
  $hit++
}

$pu | ConvertTo-Json -Depth 8 | Set-Content $puFile -Encoding UTF8
Write-Output ("refresh-bakers-links: refreshed $hit snapshot(s) by UPC ($priceMoved price move(s)); $miss entr(ies) not in this capture - left alone for prune to judge")
