<#
  check-uncommitted-source.ps1 - answers "is there uncommitted SOURCE work?" reliably.

  The daily pipelines regenerate ~90+ tracked files every run (board data, trend HTML, audit reports,
  recipe caches, logs, the served feed), so a bare `git status` is perpetually noisy and a real
  uncommitted fix hides in it - exactly what happened 2026-07-27 (a Walmart pricing fix sat loose among
  103 dirty files). This classifies every dirty tracked file as REGENERATED (the pipeline/cloud owns it -
  ignore) or SOURCE (durable code/config you must commit), and reports only the SOURCE set.

  Exit 0 = no uncommitted source, 2 = uncommitted source found (list printed). Run before ending any
  session that touched the estate, and it is the model for the triage's clean-tree gate.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income' }
Push-Location $root
try {
  $dirty = @(git status --porcelain | Where-Object { $_ })
} finally { Pop-Location }

# REGENERATED - the pipeline/cloud rebuilds or serves these; not a human's source edit.
$regenRx = @(
  'grocery/out/',                       # all pipeline outputs (board, trend, audit, logs, sigs, captures)
  'grocery/ad-cycle-log', 'grocery/alert-log', 'grocery/local-daily-log',
  'grocery/board-price-overrides\.json',# generate-board-overrides regenerates
  'grocery/category-excludes\.json',    # apply-category-excludes rebakes the whole file daily
  'grocery/product-urls\.json',         # link resolvers rewrite daily
  'grocery/price-history\.json', 'grocery/ad-schedule\.json',
  'meal-prep/db/costed\.json', 'meal-prep/db/published-hashes\.json',
  'meal-prep/db/built/',                # rebuilt cards
  'meal-prep/pipeline/v2-perserving', 'meal-prep/pipeline/catalog-digest',
  'meal-prep/ingredient-map\.json', 'meal-prep/dinner-data\.js', 'meal-prep/protein-data',
  'meal-prep/scratch-smpfeed\.json',   # compute-v2's cached download of the public feed
  'meal-prep/recipes-db\.json',         # rotation/index writes (visibility flips)
  'meal-prep/free-rotation\.json',
  'public/',                            # Cloudflare-served, cloud-committed
  '\.sig$', '\.bak', '\.stamp$'
)
$src = New-Object System.Collections.Generic.List[string]
foreach ($line in $dirty) {
  $path = $line.Substring(3).Trim('"')
  $isRegen = $false
  foreach ($rx in $regenRx) { if ($path -match $rx) { $isRegen = $true; break } }
  if (-not $isRegen) { $src.Add($line) }
}
if ($src.Count -eq 0) { Write-Output ("clean: no uncommitted SOURCE ({0} regenerated/output files ignored)" -f $dirty.Count); exit 0 }
Write-Output ("UNCOMMITTED SOURCE: {0} file(s) (of {1} dirty) need review/commit:" -f $src.Count, $dirty.Count)
$src | ForEach-Object { Write-Output ("  " + $_) }
exit 2
