<#
  drop-stale-overrides.ps1

  board-price-overrides.json PINS a per-unit for a cell and WINS over whatever compare-deals computes.
  That is correct when the engine's source pull went stale. It is dangerous when the pinned number was
  itself derived from a WRONG match, because then fixing the match changes nothing on the page - the
  stale pin keeps overriding the corrected engine, silently.

  These three were pinned from wrong matches and are removed, each verified against the store's own
  page on 2026-07-14:
    gelatin / Walmart  0.3867  <- "Winky Brand Gelatin Cups" (snack cups, not boxed gelatin)
    gelatin / Hy-Vee   0.41    <- Snack Pack "Juicy Gels" cups (same problem)
    yeast   / Fareway  7.96    <- Red Star 3 x 0.25 oz recorded as 0.25 oz (3x too expensive per oz)
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$f = Join-Path $root 'board-price-overrides.json'
Copy-Item $f (Join-Path $root 'out\board-price-overrides.backup-2026-07-14.json') -Force

$o = Get-Content $f -Raw | ConvertFrom-Json
$drop = @(
  @{ id='gelatin'; store='Walmart' },
  @{ id='gelatin'; store='Hy-Vee'  },
  @{ id='yeast';   store='Fareway' }
)
$keep = New-Object System.Collections.ArrayList
$removed = 0
foreach ($c in $o.cells) {
  $hit = $false
  foreach ($d in $drop) { if (($c.id -eq $d.id) -and ($c.store -eq $d.store)) { $hit = $true } }
  if ($hit) { Write-Output ("  REMOVED pin  {0,-10} {1,-12} per_unit={2}" -f $c.id, $c.store, $c.per_unit); $removed++; continue }
  [void]$keep.Add($c)
}
$o.cells = $keep.ToArray()
($o | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Write-Output ''
Write-Output ("removed $removed stale pins; " + @($o.cells).Count + ' remain')
