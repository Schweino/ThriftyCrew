<#
  audit-sale-fallback.ps1 - guards the "when a sale ends, fall back to the next-cheapest item" behavior.
  compare-deals already ranks the cheapest of {sale, everyday} per store, so a sale ending reverts to the
  store's everyday item AUTOMATICALLY - BUT only if an everyday candidate for that commodity+store exists in
  the source files. If a commodity+store is on SALE with NO everyday entry to fall back to, that store will
  VANISH from the board the day the sale ends. This flags exactly those cells BEFORE that happens.

  For each on-sale cell it checks the store's EVERYDAY source file for a product matching the commodity
  (include, not exclude). Missing -> a fallback gap. Family Fare is refreshed daily (research-familyfare-
  everyday.ps1), so its gaps self-heal; browser-store gaps (Baker's/Hy-Vee/Aldi/Walmart/Sam's/Fareway) are
  written to research-worklist.json for the weekly agent to research the next-cheapest everyday item, and the
  daily job alerts. Output: out\sale-fallback-gaps.json + out\research-worklist.json; exit 2 if any gaps.
#>
param([string]$OutDir = "", [string]$CompareFile = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'regular-fileset-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }

# THE BOARD FIRST, BECAUSE ITS NAME IS THE AS-OF. Resolved up here (it used to sit below the everyday pool)
# so the fileset window is anchored to the board being audited rather than to the wall clock - the same
# reason Resolve-BoardAsOf exists in regular-fileset-lib. A triage rebuild audits yesterday's board this
# morning, and an as-of one day wide is how guard 5 lost a 711-row Walmart capture on 2026-07-30.
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$asof = Resolve-BoardAsOf @(Get-Item $CompareFile) (Get-Date)

# THE ENGINE'S OWN FILESET, NOT THIS AUDITOR'S PRIVATE ONE (2026-09-02, queue 2026-09-02-5df03f).
# This used to be one Get-ChildItem per store, newest by name, Select-Object -First 1. For six of the seven
# stores that is also what the engine does. For WALMART it is false EVERY DAY: Walmart is the only
# everyday-only store, so compare-deals unions every capture inside the 90-day carry window, while a
# Walmart capture is a 7-to-25-term rotation slice by policy (602 terms on a quarterly rotation). The
# auditor was therefore asking "is there an everyday twin in today's 12-term slice", which is a question
# about the capture cursor, not about the board.
# MEASURED 2026-09-02: 23 of 28 flagged cells were false. Every one of them had 5 to 331 matching everyday
# rows in the 24-file union and ZERO in the newest slice - ground-beef-8020's twin, '80% Lean / 20% Fat
# Ground Beef Chuck, 10 lb Roll, Fresh, All Natural' at $49.43, sat in walmart-regular-2026-08-31. The
# collateral was worse than the noise: 23 "research the next-cheapest everyday item" rows went to the
# weekly browser agent for products the union already holds.
# It stayed quiet only because the newest Walmart file used to be a 700-row era capture. Class:
# reporter-reads-a-narrower-fileset-than-the-repairer, the same shape as generate-board-overrides' private
# Sam's map on 2026-08-30 - which is why Sam's goes through Select-EngineSamsFiles here rather than through
# an out\regular glob: Sam's has no out\regular file at all, and two orphan sams-regular-*.json from
# July/August still sit there ready to answer the wrong question.
# DO NOT re-introduce a private fileset here. If the window or the depth rule moves, it moves in
# regular-fileset-lib / capture-policy-lib and this auditor follows it for free.
$regPrefixToStore = @{
  'family-fare' = 'Family Fare'
  'hyvee'       = 'Hy-Vee'
  'aldi'        = 'Aldi'
  'walmart'     = 'Walmart'
  'bakers'      = "Baker's"
  'fareway'     = 'Fareway'
}
$browser = @('Hy-Vee','Aldi','Walmart',"Baker's","Sam's Club",'Fareway')  # can't research headless -> weekly agent

# cache each store's everyday product names, over the SAME files the engine priced from
$everydayNames = @{}
foreach ($st in @($regPrefixToStore.Values)) { $everydayNames[$st] = New-Object System.Collections.Generic.HashSet[string] }
$everydayNames["Sam's Club"] = New-Object System.Collections.Generic.HashSet[string]
$everydayFileCount = @{}
function Add-EverydayFile([string]$store, $fileObj) {
  if (-not $everydayNames.ContainsKey($store)) { return }
  try { $doc = Get-Content $fileObj.FullName -Raw | ConvertFrom-Json } catch { return }
  foreach ($d in @($doc.deals)) { [void]$everydayNames[$store].Add("" + $d.item + $d.name) }
  $everydayFileCount[$store] = 1 + [int]$everydayFileCount[$store]
}
$regFiles = @(Select-RegularFileSet (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue) $asof (Get-RegularUnionDays))
foreach ($f in $regFiles) {
  $prefix = ($f.BaseName -replace '-regular-.*$','')
  $st = $regPrefixToStore[$prefix]
  if ($st) { Add-EverydayFile $st $f }
}
foreach ($f in @(Select-EngineSamsFiles $OutDir (Get-Date))) { Add-EverydayFile "Sam's Club" $f }
function HasEveryday([string]$store, $c) {
  if (-not $everydayNames.ContainsKey($store)) { return $true }   # store has no everyday channel we track -> don't flag
  foreach ($nm in $everydayNames[$store]) {
    $inc = $false; foreach ($rx in $c.include) { if ($nm -imatch $rx) { $inc = $true; break } }; if (-not $inc) { continue }
    $ex = $false; foreach ($rx in $c.exclude) { if ($rx -and $nm -imatch $rx) { $ex = $true; break } }
    if (-not $ex) { return $true }
  }
  return $false
}

$all = (Get-Content $CompareFile -Raw | ConvertFrom-Json).comparison
$gaps = New-Object System.Collections.Generic.List[object]
$work = New-Object System.Collections.Generic.List[object]
foreach ($it in $all) {
  $c = $byId[[string]$it.id]; if (-not $c) { continue }
  foreach ($s in $it.stores) {
    if ([string]$s.type -ne 'sale') { continue }
    if (HasEveryday ([string]$s.store) $c) { continue }
    $gaps.Add([pscustomobject]@{ commodity=[string]$it.id; store=[string]$s.store; sale_per_unit=[double]$s.per_unit })
    if ($browser -contains [string]$s.store) { $work.Add([pscustomobject]@{ commodity=[string]$it.id; store=[string]$s.store; reason='on sale now with no everyday fallback - research the next-cheapest EVERYDAY item so it does not vanish when the sale ends' }) }
  }
}
# SAY WHAT WAS READ. A fallback pool built from zero files answers "no everyday twin" for every cell in
# the store, which looks exactly like a real gap - the failure mode this item was written about. Printing
# the per-store file count makes an empty pool visible on the run that produces it instead of three days
# later in a worklist.
$pool = (@($everydayNames.Keys) | Sort-Object | ForEach-Object { "{0}={1}f/{2}n" -f $_, ([int]$everydayFileCount[$_]), $everydayNames[$_].Count }) -join ' '
Write-Output ("sale-fallback: everyday pool from the engine fileset (as-of {0:yyyy-MM-dd}, union {1}d): {2}" -f $asof, (Get-RegularUnionDays), $pool)
$rep = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); as_of=$asof.ToString('yyyy-MM-dd'); everyday_pool=$pool; gap_count=$gaps.Count; gaps=$gaps }
$rep | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'sale-fallback-gaps.json') -Encoding UTF8
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); items=$work }) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'research-worklist.json') -Encoding UTF8
if ($gaps.Count) {
  Write-Output ("sale-fallback: $($gaps.Count) on-sale cell(s) have NO everyday fallback (would vanish when the sale ends):")
  foreach ($gp in $gaps) { Write-Output ("  {0,-18} {1}" -f $gp.commodity, $gp.store) }
  Write-GuardComplete -Name 'sale-fallback'; exit 2
} else { Write-Output 'sale-fallback: none - every on-sale cell has an everyday item to revert to'; Write-GuardComplete -Name 'sale-fallback'; exit 0 }
