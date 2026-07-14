<#
  fix-product-urls-open3.ps1

  THE REAL ROOT CAUSE of the gelatin/yeast numbers surviving every fix:

    product-urls.json (the durable "See item" link store)
        -> generate-board-overrides.ps1 derives a PINNED per-unit from it
        -> publish-deals-page.ps1 runs that generator on EVERY publish
        -> build-deals-page.ps1 applies the pin, which WINS over compare-deals

  So while product-urls.json still linked Walmart's gelatin cell to "Winky Brand Gelatin Cups",
  every publish silently re-pinned $0.39 over the corrected $1.62 box. Fixing commodities.json and
  the regular files was necessary but NOT sufficient - the link store had to be corrected too.

  Verified against the stores' own pages on 2026-07-14:
    yeast / Fareway - "Red Star Active Dry Yeast, All-Natural 3 x 0.25 oz" = 0.75 oz, not 0.25 oz
    yeast / Hy-Vee  - "Fleischmann's ActiveDry Yeast 3 Pack" - the 0.25 oz is PER PACKET = 0.75 oz
    gelatin / Walmart + Hy-Vee - linked to snack CUPS, which are not boxed gelatin at all. The link
      is dropped rather than re-pointed at a guess; resolve-worklist.ps1 will queue it for a proper
      re-resolve, and the board keeps the correct engine price in the meantime.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$f = Join-Path $root 'product-urls.json'
Copy-Item $f (Join-Path $root 'out\product-urls.backup-open3.json') -Force

$doc = Get-Content $f -Raw | ConvertFrom-Json

# 1. yeast: correct the sizes (the products and links are right, only the size was wrong)
foreach ($pair in @(@('Fareway','0.75 oz'), @('Hy-Vee','0.75 oz'))) {
  $store = $pair[0]; $size = $pair[1]
  $e = $doc.items.yeast.$store
  if ($e) {
    $old = $e.size
    $e.size = $size
    if ($e.PSObject.Properties['board_pu']) { $e.board_pu = $null }   # force a re-stamp
    Write-Output ("  yeast   / {0,-8} size '{1}' -> '{2}'" -f $store, $old, $size)
  }
}

# 2. gelatin: the Walmart/Hy-Vee links point at snack cups, not boxed gelatin. Drop them.
foreach ($store in @('Walmart','Hy-Vee')) {
  if ($doc.items.gelatin.PSObject.Properties[$store]) {
    $bad = $doc.items.gelatin.$store.name
    $doc.items.gelatin.PSObject.Properties.Remove($store)
    Write-Output ("  gelatin / {0,-8} link REMOVED (was '{1}')" -f $store, $bad)
  }
}

($doc | ConvertTo-Json -Depth 8) | Set-Content $f -Encoding UTF8
Write-Output ''
Write-Output 'product-urls.json updated (backup: out\product-urls.backup-open3.json)'
