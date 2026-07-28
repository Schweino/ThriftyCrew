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
# ...and the ENGINE's own global exclusions (pet food, baby food, cleaning supplies, personal care), which
# live in compare-deals.ps1 and were never read here. Without them this audit reports candidates the engine
# deliberately refuses and can never accept - a Happy Tot baby-food pouch was filed as "Baker's is missing
# from spinach" every day (2026-07-28). An auditor that disagrees with the engine is a permanent false alarm,
# so read the real list (same parse audit-match-contested.ps1 uses) instead of keeping a second opinion.
$ENGINE_GLOBAL = @()
try {
  $cdtxt = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
  $mg = [regex]::Match($cdtxt, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
  if ($mg.Success) { $ENGINE_GLOBAL = @(Invoke-Expression ('@(' + $mg.Groups['b'].Value + ')')) }
} catch { Write-Output ('WARN could not read the engine GLOBAL_EXCLUDE (' + $_.Exception.Message + ') - gaps may include engine-excluded products') }

# ---- gather each store's RAW pulled product names (same inputs compare-deals uses) ----
$prod = @{}
function AddP([string]$store,[string]$name) { if (-not $store -or -not $name) { return }; if (-not $prod.ContainsKey($store)) { $prod[$store] = New-Object System.Collections.Generic.List[string] }; $prod[$store].Add($name) }
# weekly ads (flat .deals with {store,item})
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { foreach ($d in (Get-Content $adsF.FullName -Raw | ConvertFrom-Json).deals) { AddP ([string]$d.store) ([string]$d.item) } }
# Everyday shelf files (per store; store on the doc or the deal). NEWEST PER STORE ONLY, and only
# within the same 14-day window the engine itself honours (2026-07-27). Reading EVERY regular file
# ever written - which this did - manufactures false gaps two ways: a product the store has since
# DELISTED still counts as carried (Baker's does a complete daily API pull, so absence from the
# newest file is real), and a file past the freshness cliff counts at all (a Family Fare row from
# 21 days ago). Both then read as "the store carries it but a too-strict regex dropped it", which
# is the opposite of what happened. Every other source below already takes -First 1.
$regNewest = @{}
foreach ($rf in (Get-ChildItem (Join-Path $OutDir 'regular\*.json') -ErrorAction SilentlyContinue)) {
  $m = [regex]::Match($rf.BaseName, '^(.+)-regular-(\d{4}-\d{2}-\d{2})$')
  if (-not $m.Success) { continue }                     # stray file: guard 12 owns that failure
  $pfx = $m.Groups[1].Value; $stamp = $m.Groups[2].Value
  if (-not $regNewest.ContainsKey($pfx) -or $stamp -gt $regNewest[$pfx].stamp) {
    $regNewest[$pfx] = [pscustomobject]@{ stamp = $stamp; file = $rf }
  }
}
$freshFloor = (Get-Date).AddDays(-14).ToString('yyyy-MM-dd')
foreach ($k in $regNewest.Keys) {
  $entry = $regNewest[$k]
  if ($entry.stamp -lt $freshFloor) { continue }        # past the cliff: the engine would not price it either
  try { $doc = Get-Content $entry.file.FullName -Raw | ConvertFrom-Json } catch { continue }
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
    # Collect up to MAXCAND matching candidates, not just the first. Reporting ONE candidate and stopping
    # led reviewers to write allowlist entries asserting "the only thing at this store matching the include
    # regex is X" - a claim this audit's output could never support. On 2026-07-27 that produced at least
    # five false entries; the worst, tater-tots @ Baker's, was stamped on the strength of a corn-tot match
    # while the store carried SIX real Ore-Ida tater tot products, one of them fully priceable at
    # $5.49/32 oz. A one-day-old entry was hiding the estate's largest store from a commodity it carries.
    # An allowlist decision is only as good as the evidence put in front of the reviewer.
    $MAXCAND = 5
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($nm in ($prod[$st] | Select-Object -Unique)) {
      $hit = $false; foreach ($p in $probes) { if ($nm -imatch $p) { $hit = $true; break } }
      if (-not $hit) { continue }
      $bad = $false
      foreach ($x in $excl)   { if ($x -and $nm -imatch $x) { $bad = $true; break } }
      # honor the commodity's relax_global waivers (pasta-sauce IS a sauce etc.) so those commodities still
      # get coverage-gap protection instead of every candidate being silently global-excluded
      if (-not $bad) { $relax = @($c.relax_global | Where-Object { $_ }); foreach ($x in $GLOBAL) { if ($relax -notcontains $x -and $nm -imatch $x) { $bad = $true; break } } }
      if (-not $bad) { $relax = @($c.relax_global | Where-Object { $_ }); foreach ($x in $ENGINE_GLOBAL) { if ($relax -notcontains $x -and $nm -imatch $x) { $bad = $true; break } } }
      if ($bad) { continue }
      $found.Add($nm)
      if ($found.Count -ge $MAXCAND) { break }
    }
    if ($found.Count -gt 0) {
      $gaps.Add([pscustomobject]@{ commodity = $id; store = $st; candidate = $found[0]
                                   candidates = @($found); candidate_count = $found.Count
                                   truncated = ($found.Count -ge $MAXCAND) })
    }
  }
}

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); gap_count = $gaps.Count; gaps = $gaps }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'coverage-gaps.json') -Encoding UTF8
if ($gaps.Count) {
  Write-Output ("coverage-gaps: $($gaps.Count) store(s) DROPPED despite having a matching product:")
  # print EVERY candidate, not just the first - a reviewer allowlisting this pair is about to make a
  # factual claim about what the store carries, so put the whole evidence set in front of them.
  foreach ($gp in $gaps) {
    Write-Output ("  {0,-18} {1,-13} <- '{2}'" -f $gp.commodity, $gp.store, $gp.candidate)
    if ($gp.candidate_count -gt 1) {
      foreach ($extra in @($gp.candidates)[1..($gp.candidate_count-1)]) { Write-Output ("  {0,-18} {1,-13}    also: '{2}'" -f '', '', $extra) }
      if ($gp.truncated) { Write-Output ("  {0,-18} {1,-13}    (list truncated - there may be more)" -f '', '') }
    }
  }
  exit 2
} else { Write-Output 'coverage-gaps: none - every store that carries a tracked item is on the board'; exit 0 }
