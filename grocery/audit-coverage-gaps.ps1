<#
  audit-coverage-gaps.ps1 - HOLISTIC guard against a store being SILENTLY dropped from a commodity because its
  real product name doesn't fit a too-strict include regex (the Hy-Vee "Pork Loin TOP Loin Chops" bug: the
  matcher wanted "pork chop" contiguous, so a store that clearly sells the item vanished with no signal).

  For every commodity x store where the store is NOT on the board, we scan that store's RAW pulled products
  (the same source files compare-deals reads) for a name that matches a LOOSENED version of the commodity's
  own include patterns (\s+ -> ".{0,25}", so intervening words like "top" no longer break the match) and is not
  an excluded/prepared form. A hit = the store HAS the product but the strict matcher dropped it => a coverage
  gap to fix (usually by widening that commodity's include, exactly as we just did for pork-chops).

  Output: out\coverage-gaps-<date>.json { generated, gaps:[{commodity,store,candidate}] } + a one-line summary.
  Exit 2 if any gaps (so publish/daily can surface + alert). This is what makes "a store that carries an item
  never silently disappears" a checkable invariant for ALL stores, not a thing we notice by eyeballing.
#>
param([string]$OutDir = "", [string]$CompareFile = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$stores = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
# prepared/different-form words that legitimately are NOT the plain commodity (so a match on them is not a gap)
$GLOBAL = @('seasoning','marinade','\bsauce\b','\brub\b','\bkit\b','bundle','\bmeal\b','wrapped','breaded','\bnugget','\bjerky\b','flavored','\bdip\b','helper','lunchable','\bsoup\b','gravy','stuffing')

# ---- gather each store's RAW pulled product names (same inputs compare-deals uses) ----
$prod = @{}
function AddP([string]$store,[string]$name) { if (-not $store -or -not $name) { return }; if (-not $prod.ContainsKey($store)) { $prod[$store] = New-Object System.Collections.Generic.List[string] }; $prod[$store].Add($name) }
# weekly ads (flat .deals with {store,item})
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { foreach ($d in (Get-Content $adsF.FullName -Raw | ConvertFrom-Json).deals) { AddP ([string]$d.store) ([string]$d.item) } }
# everyday shelf files (per store; store on the doc or the deal)
foreach ($rf in (Get-ChildItem (Join-Path $OutDir 'regular\*.json') -ErrorAction SilentlyContinue)) {
  try { $doc = Get-Content $rf.FullName -Raw | ConvertFrom-Json } catch { continue }
  foreach ($d in $doc.deals) { $s = if ($doc.store) { [string]$doc.store } else { [string]$d.store }; AddP $s ([string]$d.item); if ($d.name) { AddP $s ([string]$d.name) } }
}
# browser-store deal files
foreach ($glob in @('bakers\bakers-deals-*.json','sams\sams-deals-*.json','fareway\fareway-deals-*.json')) {
  $f = Get-ChildItem (Join-Path $OutDir $glob) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($f) { foreach ($d in (Get-Content $f.FullName -Raw | ConvertFrom-Json).deals) { AddP ([string]$d.store) ([string]$d.item) } }
}

# reviewed, legitimate exceptions (a store carries the item but it genuinely can't be priced like-for-like:
# a combined "A or B or C" ad line, or a by-volume pack with no comparable weight). Keyed commodity|store so
# the detector only alerts on NEW / unreviewed gaps, never re-cries a known one.
$allow = @{}
$allowF = Join-Path $root 'coverage-gap-allowlist.json'
if (Test-Path $allowF) { try { foreach ($a in (Get-Content $allowF -Raw | ConvertFrom-Json).allow) { $allow[([string]$a.commodity + '|' + [string]$a.store)] = $true } } catch {} }

# ---- which stores are already on the board per commodity ----
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$present = @{}
foreach ($r in (Get-Content $CompareFile -Raw | ConvertFrom-Json).comparison) { foreach ($s in $r.stores) { $present[([string]$r.id + '|' + [string]$s.store)] = $true } }

# ---- for each missing store, look for a loosened-include match in its raw products ----
$gaps = New-Object System.Collections.Generic.List[object]
foreach ($c in $commods) {
  $id = [string]$c.id
  # loosen the include: allow up to 25 chars where it required whitespace. Handle \s* and \s+ BEFORE bare \s,
  # or "\s*" becomes ".{0,25}*" (a nested quantifier that throws). Order matters.
  $probes = @($c.include | ForEach-Object { ((($_ -replace '\\s\*', '.{0,25}') -replace '\\s\+', '.{0,25}') -replace '\\s', '.{0,25}') })
  $excl = @($c.exclude)
  foreach ($st in $stores) {
    if ($present.ContainsKey($id + '|' + $st)) { continue }
    if ($allow.ContainsKey($id + '|' + $st)) { continue }
    if (-not $prod.ContainsKey($st)) { continue }
    foreach ($nm in ($prod[$st] | Select-Object -Unique)) {
      $hit = $false; foreach ($p in $probes) { if ($nm -imatch $p) { $hit = $true; break } }
      if (-not $hit) { continue }
      $bad = $false
      foreach ($x in $excl)   { if ($x -and $nm -imatch $x) { $bad = $true; break } }
      if (-not $bad) { foreach ($x in $GLOBAL) { if ($nm -imatch $x) { $bad = $true; break } } }
      if ($bad) { continue }
      $gaps.Add([pscustomobject]@{ commodity = $id; store = $st; candidate = $nm }); break
    }
  }
}

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); gap_count = $gaps.Count; gaps = $gaps }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'coverage-gaps.json') -Encoding UTF8
if ($gaps.Count) {
  Write-Output ("coverage-gaps: $($gaps.Count) store(s) DROPPED despite having a matching product:")
  foreach ($gp in $gaps) { Write-Output ("  {0,-18} {1,-13} <- '{2}'" -f $gp.commodity, $gp.store, $gp.candidate) }
  exit 2
} else { Write-Output 'coverage-gaps: none - every store that carries a tracked item is on the board'; exit 0 }
