<#
  audit-store-coverage.ps1 - INVARIANT guard: every staple commodity on the board must show a tile for ALL 7
  stores - a price, or a muted "Doesn't carry / No price yet - See it? Let us know!" card. A store is NEVER
  silently dropped from a commodity (the bug Brad caught when Hy-Vee + Fareway vanished from blueberries because
  they had no comparable per-ounce price and so were simply omitted).

  build-deals-page renders this BY CONSTRUCTION (MissingCells iterates $storeOrder) and THROWS if a priced store
  isn't a known store, so a violation here should be impossible. This is the belt-and-suspenders check on the
  ACTUAL built HTML, so a future render regression can't ship a board with a store missing from a commodity.

  Only commodities.json STAPLES are held to all-7 (they're the tracked items on the main board). Recipe-ingredient
  rows are intentionally exempt (niche items; showing 7 cards each, mostly empty, would be noise).

  Output: out\store-coverage-report.json { generated, stores, checked, ok, absent[], violations[] } + one line.
  Exit 2 if any staple row that IS on the board is missing a store tile (or shows a store twice). A staple that
  is entirely absent (0 prices -> skipped) is reported as a warning but is a separate/louder alarm, not a hard
  fail here (it would take the whole board down over one bad commodity).
#>
param([string]$OutDir = "", [string]$Embed = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $Embed)  { $Embed  = Join-Path $OutDir 'deals-page-embed.html' }
# the 7 stores that MUST appear on every staple row - keep in lockstep with $storeOrder in build-deals-page.ps1
$stores = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')

if (-not (Test-Path $Embed)) { Write-Output "store-coverage: SKIP (no built board at $Embed)"; exit 0 }
$html = Get-Content $Embed -Raw
$ids = @((Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json) | ForEach-Object { [string]$_.id })
# CHIPS MOVED TO THE FEED (2026-07-16): the embed still carries every row (so row PRESENCE is still checked
# against it) but .pg-stores is filled client-side from public/board.json, so the row html has no chips. Read
# the chip html from the feed - it is byte-identical to what the browser injects. Without this the audit would
# see zero chips per row and report every staple as missing all 7 stores.
$boardFeed = Join-Path (Split-Path $root -Parent) 'public\board.json'
$bf = $null
if (Test-Path $boardFeed) { $bf = Get-Content $boardFeed -Raw | ConvertFrom-Json }

$violations = New-Object System.Collections.Generic.List[object]
$absent = New-Object System.Collections.Generic.List[string]
$ok = 0
foreach ($id in $ids) {
  # first occurrence of this id = the STAPLE row (staples render before any recipe-ingredient row of the same id)
  $m = [regex]::Match($html, "data-id='" + [regex]::Escape($id) + "'.*?</article>", 'Singleline')
  if (-not $m.Success) { $absent.Add($id); continue }
  # every store chip on the row - priced (has data-pu) AND muted none-cards (no data-pu). Both start pg-chip.
  # Feed key: '<id>' is the staple row; '<id>::r' is the recipe row (a staple priced only as an ingredient).
  $chipHtml = $m.Value
  if ($bf) {
    $pv = $bf.PSObject.Properties[$id]
    if (-not $pv) { $pv = $bf.PSObject.Properties[$id + '::r'] }
    $chipHtml = if ($pv) { [string]$pv.Value } else { '' }
  }
  $chips = @([regex]::Matches($chipHtml, "class='pg-chip[^']*' data-store=`"([^`"]+)`"") | ForEach-Object { $_.Groups[1].Value -replace '&#39;', "'" })
  $set = @($chips | Select-Object -Unique)
  $missing = @($stores | Where-Object { $set -notcontains $_ })
  $dupes = @($chips | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  if ($missing.Count -or $dupes.Count) {
    $violations.Add([pscustomobject]@{ commodity = $id; missing = ($missing -join ','); dupes = ($dupes -join ',') })
  } else { $ok++ }
}

# ZERO-ROWS-IS-NOT-A-PASS. Every staple is located by a regex against the rendered embed:
#   [regex]::Match($html, "data-id='<id>'.*?</article>")
# Anything it misses is pushed to $absent and `continue`d, and $absent is only a parenthetical WARN below. So if
# build-deals-page ever emits data-id="..." with double quotes, renames the wrapper element, or the embed is
# truncated, ALL of the staples land in $absent: $ok = 0, $violations = 0, and this HARD publish gate prints
# "store-coverage: OK  all 0 on-board staples show every one of the 7 stores" and exits 0. The audit exists to
# catch a render regression, and a render regression is precisely what empties its set.
# Routed through $violations rather than a bare `exit 2` on purpose: that way it lands in
# store-coverage-report.json, the existing FAIL branch prints and exits 2, and check-ad-cycles builds a stable
# NON-EMPTY alert signature from it - a bare exit 2 with an empty violations list is swallowed by that
# signature de-dup and emails nobody. Requiring $violations.Count -eq 0 keeps the message truthful when every
# row is present but failing. Cannot cry wolf: $ok is 469 on a healthy run.
if ($ok -eq 0 -and $violations.Count -eq 0 -and $ids.Count -gt 0) {
  $violations.Add([pscustomobject]@{ commodity = '*ALL-ROWS-ABSENT*'; missing = ('row matcher found 0 of ' + $ids.Count + ' staples in the embed - the data-id row markup changed or the build is truncated; zero rows examined is not a pass'); dupes = '' })
}

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); stores = $stores.Count; checked = $ids.Count; ok = $ok; absent = $absent; violations = $violations }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'store-coverage-report.json') -Encoding UTF8
$warn = if ($absent.Count) { "  (WARN " + $absent.Count + " staple not on board: " + ($absent -join ', ') + ")" } else { "" }
if ($violations.Count) {
  Write-Output ("store-coverage: FAIL  " + $violations.Count + " staple commodity(ies) with a store missing from the row:" )
  foreach ($v in $violations) { Write-Output ("  {0,-20} missing=[{1}] dupes=[{2}]" -f $v.commodity, $v.missing, $v.dupes) }
  exit 2
} else {
  Write-Output ("store-coverage: OK  all " + $ok + " on-board staples show every one of the " + $stores.Count + " stores" + $warn)
  exit 0
}
