<#
  register-batch.ps1 - safely register a batch of NEW commodities from drafted rule files into the three
  engine files: commodities.json (id/label/unit/include/exclude), categories.json (id -> its category's
  commodity list), commodity-search.json (id -> search term). Nothing agent-drafted is trusted raw. Every rule
  must clear ALL of:
    - id is a clean kebab slug, not already registered, not a dupe within the batch
    - unit in lb|oz|floz|each|dozen|gallon
    - label non-empty
    - category resolves to a real categories.json entry (by the candidate's category label)
    - include is a non-empty array AND every include/exclude pattern COMPILES as a .NET regex (a bad pattern
      would throw inside compare-deals/guards, which run under -ErrorAction Stop, and wedge the daily job)
  A rule that fails ANY check is REJECTED with a printed reason and NOTHING for it is written - partial-but-safe
  beats all-or-nothing. -WhatIf validates and reports without writing. After a real run: apply-category-excludes
  -> compare-deals -> audit-food-category -> build-vet-sheet -Ids <batch ids>.
#>
param([string]$RulesGlob = "out\staples500\rules\rules-*.json", [string]$CandidatesFile = "out\staples500\batch1.json", [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$UNITS = @('lb','oz','floz','each','dozen','gallon')

$cand = @{}
foreach ($x in (Get-Content (Join-Path $root $CandidatesFile) -Raw | ConvertFrom-Json)) { $cand[[string]$x.id] = $x }

# PS 5.1: [ArrayList]@(pipe | ConvertFrom-Json) NESTS the whole parsed array as ONE element (the trap that hit
# merge-candidates too). Add each item via foreach so the ArrayList holds the 328 commodities individually - a
# nested single element made the write keep only the new rows and WIPE the 328 existing (caught by the restore).
$commods = New-Object System.Collections.ArrayList
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { [void]$commods.Add($c) }
$existingIds = @{}; foreach ($c in $commods) { $existingIds[[string]$c.id] = $true }
$catDoc = Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json
$catByLabel = @{}; foreach ($c in $catDoc.categories) { $catByLabel[[string]$c.label] = $c }
$searchDoc = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json

function RxOk([string]$p) { try { [void][regex]::new($p); return $true } catch { return $false } }

$ok = New-Object System.Collections.Generic.List[object]
$rej = New-Object System.Collections.Generic.List[string]
$seen = @{}
foreach ($rf in (Get-ChildItem (Join-Path $root $RulesGlob) -ErrorAction SilentlyContinue | Sort-Object Name)) {
  $parsed = $null
  try { $parsed = Get-Content $rf.FullName -Raw | ConvertFrom-Json } catch { $rej.Add("$($rf.Name): UNPARSEABLE - whole file skipped"); continue }
  foreach ($r in $parsed) {
    $id = ([string]$r.id).Trim()
    $why = $null
    $inc = @($r.include); $exc = @($r.exclude)
    if (-not $id -or ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$')) { $why = "bad id '$id'" }
    elseif ($existingIds.ContainsKey($id)) { $why = 'id already registered' }
    elseif ($seen.ContainsKey($id)) { $why = 'dupe id within batch' }
    elseif (-not $r.label) { $why = 'blank label' }
    elseif ($UNITS -notcontains ([string]$r.unit)) { $why = "bad unit '$($r.unit)'" }
    elseif (-not $cand.ContainsKey($id)) { $why = 'id not in the approved candidate list' }
    elseif (-not $catByLabel.ContainsKey([string]$cand[$id].category)) { $why = "unknown category '$($cand[$id].category)'" }
    elseif ($inc.Count -lt 1) { $why = 'empty include list' }
    else {
      foreach ($p in ($inc + $exc)) { if (-not (RxOk ([string]$p))) { $why = "include/exclude pattern does not compile: '$p'"; break } }
    }
    if ($why) { $rej.Add(("  {0,-26} [{1}] {2}" -f $id, $rf.Name, $why)); continue }
    $seen[$id] = $true
    $ok.Add([pscustomobject]@{ id=$id; label=[string]$r.label; unit=[string]$r.unit; include=$inc; exclude=$exc; category=[string]$cand[$id].category; term=([string]$r.search_term); }) | Out-Null
  }
}

Write-Output ("valid rules to register: " + $ok.Count + "   rejected: " + $rej.Count)
if ($rej.Count) { Write-Output 'REJECTS (reasoned, not silent):'; foreach ($x in $rej) { Write-Output $x } }
if ($WhatIf) { Write-Output ''; Write-Output 'WhatIf: no files written'; return }
if ($ok.Count -eq 0) { Write-Output 'nothing to register'; return }

foreach ($r in $ok) {
  [void]$commods.Add([pscustomobject]@{ id=$r.id; label=$r.label; unit=$r.unit; include=$r.include; exclude=$r.exclude })
  $cat = $catByLabel[$r.category]
  $cat.commodities = @(@($cat.commodities) + $r.id)
  if ($r.term) { $searchDoc.terms | Add-Member -NotePropertyName $r.id -NotePropertyValue $r.term -Force }
  else { $searchDoc.terms | Add-Member -NotePropertyName $r.id -NotePropertyValue ($r.label.ToLower()) -Force }
}
($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'commodities.json') -Encoding UTF8
($catDoc | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root 'categories.json') -Encoding UTF8
($searchDoc | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $root 'commodity-search.json') -Encoding UTF8
# validate all three round-trip as JSON
$null = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$null = Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json
$null = Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json
Write-Output ''
Write-Output ("registered " + $ok.Count + " commodities into commodities.json + categories.json + commodity-search.json (all JSON validated)")
Write-Output "NEXT: apply-category-excludes.ps1 -> compare-deals.ps1 -> audit-food-category.ps1 -> build-vet-sheet.ps1 -Ids <batch ids>"
