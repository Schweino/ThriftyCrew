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
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }

# each store's EVERYDAY source file (the fallback pool when a sale ends)
$everydayGlob = @{
  'Family Fare' = 'regular\family-fare-regular-*.json'
  'Hy-Vee'      = 'regular\hyvee-regular-*.json'
  'Aldi'        = 'regular\aldi-regular-*.json'
  'Walmart'     = 'regular\walmart-regular-*.json'
  "Baker's"     = 'regular\bakers-regular-*.json'
  "Sam's Club"  = 'sams\sams-deals-*.json'
  'Fareway'     = 'regular\fareway-regular-*.json'
}
$browser = @('Hy-Vee','Aldi','Walmart',"Baker's","Sam's Club",'Fareway')  # can't research headless -> weekly agent

# cache each store's everyday product names
$everydayNames = @{}
foreach ($st in $everydayGlob.Keys) {
  $f = Get-ChildItem (Join-Path $OutDir $everydayGlob[$st]) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $names = @()
  if ($f) { try { foreach ($d in (Get-Content $f.FullName -Raw | ConvertFrom-Json).deals) { $names += ("" + $d.item + $d.name) } } catch {} }
  $everydayNames[$st] = $names
}
function HasEveryday([string]$store, $c) {
  if (-not $everydayNames.ContainsKey($store)) { return $true }   # store has no everyday channel we track -> don't flag
  foreach ($nm in $everydayNames[$store]) {
    $inc = $false; foreach ($rx in $c.include) { if ($nm -imatch $rx) { $inc = $true; break } }; if (-not $inc) { continue }
    $ex = $false; foreach ($rx in $c.exclude) { if ($rx -and $nm -imatch $rx) { $ex = $true; break } }
    if (-not $ex) { return $true }
  }
  return $false
}

if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
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
$rep = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); gap_count=$gaps.Count; gaps=$gaps }
$rep | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'sale-fallback-gaps.json') -Encoding UTF8
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); items=$work }) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'research-worklist.json') -Encoding UTF8
if ($gaps.Count) {
  Write-Output ("sale-fallback: $($gaps.Count) on-sale cell(s) have NO everyday fallback (would vanish when the sale ends):")
  foreach ($gp in $gaps) { Write-Output ("  {0,-18} {1}" -f $gp.commodity, $gp.store) }
  exit 2
} else { Write-Output 'sale-fallback: none - every on-sale cell has an everyday item to revert to'; exit 0 }
