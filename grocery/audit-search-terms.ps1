# audit-search-terms.ps1 - "did we ever actually ask the right question?"
#
# WHY (2026-08-22). A NOT-CARRIED verdict is only worth the search behind it, and this estate's one
# confirmed "absence" was a wrong term, not an empty shelf. commodity-search.json searches doubanjiang as
# "chili bean sauce". That returns 237 rows across three stores - every one of them a chili BEAN product
# (Bush's, Mrs. Grimes) or "Kroger Hot Dog Chili Sauce". Not one row in the entire capture corpus contains
# the string "doubanjiang". The search looked healthy from every angle the estate could see: rows came
# back, stores answered, nothing errored. Three paid recipes shipped behind it.
#
# THE TEST: for each commodity, do the rows its own search term returns EVER contain the commodity's own
# distinguishing word? Zero-out-of-N is the tell. It does not prove the term is wrong - clementines
# legitimately return mandarins - but it is the shortlist a human should read before anyone promotes a
# NOT-CARRIED verdict on the strength of silence.
#
# WHAT THIS DOES NOT CATCH, deliberately stated: the rice-cakes failure. That commodity searches
# "rice cakes", returns 650 Quaker snack rows, and every one of them contains "rice" - so this check
# passes it. A generic name matching the WRONG FOOD is a mapping defect, not a search defect, and it
# belongs to the commodity-registrar. This check catches the doubanjiang class: a distinctive name that
# never appears in what the search brings back. Claiming more would make it another gate that looks green
# over the thing it cannot see.

param([string]$OutDir = '', [int]$MinRows = 3, [switch]$Json, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out\regular' }

# Words that describe a package or a form rather than the food. Matching on these would make every term
# look healthy: "ground sumac" would pass because a search returned ground BEEF.
$script:GENERIC = @('ground','fresh','frozen','dried','canned','whole','blend','style','shreds','spice',
  'cooking','base','uncooked','cooked','mixed','seasoning','sauce','paste','oil','powder','boneless',
  'skinless','low','fat','reduced','sodium','free','organic','large','small','sliced','shredded','baby',
  'pack','bag','the','and','for','with')

# Compare on a collapsed form so "Ginger Snaps" matches gingersnaps and a trailing plural does not read as
# a different food. Without this the check drowns in artichokes-vs-Artichoke noise and nobody reads it.
function Get-Collapsed { param([string]$S) return (($S -replace '[^a-zA-Z]', '').ToLower()) }
function Get-CommodityTokens {
  param([string]$CommodityId)
  $out = @()
  foreach ($t in ($CommodityId -split '[-_ ]+')) {
    $t = $t.ToLower()
    if (-not $t -or $t.Length -le 2) { continue }
    if ($script:GENERIC -contains $t) { continue }
    $out += (Get-Collapsed $t).TrimEnd('s')
  }
  return @($out | Where-Object { $_ } | Sort-Object -Unique)
}
function Test-TermReturnsItsFood {
  param([string]$CommodityId, [string[]]$Items)
  $tk = Get-CommodityTokens $CommodityId
  if (-not $tk.Count) { return @{ testable = $false; hits = 0 } }
  $hits = 0
  foreach ($i in $Items) {
    $c = (Get-Collapsed $i)
    foreach ($t in $tk) { if ($c.Contains($t)) { $hits++; break } }
  }
  return @{ testable = $true; hits = $hits; tokens = $tk }
}

if ($SelfTest) {
  $script:__b = 0
  function T([string]$n, [bool]$ok, [string]$got) { if ($ok) { Write-Output "  ok  $n" } else { Write-Output "  X   $n  ($got)"; $script:__b++ } }

  $r = Test-TermReturnsItsFood -CommodityId 'doubanjiang' -Items @('Bush''s Best Chili Beans', 'Kroger Hot Dog Chili Sauce')
  T 'MUST FIRE  the doubanjiang case: rows returned, none are the food' ($r.testable -and $r.hits -eq 0) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'gingersnaps' -Items @('Ginger Snaps Cookies 1 Lb')
  T 'a space in the product name still matches (gingersnaps / Ginger Snaps)' ($r.hits -eq 1) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'artichokes' -Items @('Artichoke')
  T 'a trailing plural is not a different food' ($r.hits -eq 1) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'frozen-mixed-peppers' -Items @('Kroger Frozen 3 Pepper & Onion Blend')
  T 'generic words are ignored; the real noun still matches' ($r.hits -eq 1) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'ground-sumac' -Items @('80/20 Ground Beef', 'Ground Turkey')
  T 'MUST FIRE  matching on a GENERIC word alone does not count as healthy' ($r.hits -eq 0) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'ground-sumac' -Items @('Morton & Bassett All Natural Sumac')
  T 'CLEAN TWIN  the real product matches' ($r.hits -eq 1) "hits=$($r.hits)"

  # the documented blind spot, asserted so nobody later mistakes it for coverage
  $r = Test-TermReturnsItsFood -CommodityId 'rice-cakes' -Items @('Quaker Lightly Salted Rice Cakes')
  T 'KNOWN BLIND SPOT  a generic name matching the wrong food reads healthy here (registrar owns it)' ($r.hits -eq 1) "hits=$($r.hits)"

  $r = Test-TermReturnsItsFood -CommodityId 'eggs' -Items @('Large Eggs')
  T 'a short but real id is testable, and its plural matches' ($r.testable -and $r.hits -eq 1) "testable=$($r.testable) hits=$($r.hits)"

  # An id made only of package/form words has nothing distinguishing to look for. Reporting it as CLEAN
  # would be the same lie as a green gate over an unasked question, so it is reported untestable instead.
  $r = Test-TermReturnsItsFood -CommodityId 'cooking-oil' -Items @('Crisco Vegetable Oil')
  T 'an id made only of generic words is reported untestable, not clean' (-not $r.testable) 'claimed testable'

  Write-Output ("audit-search-terms SELF-TEST " + $(if ($script:__b -eq 0) { 'PASS' } else { "FAILED ($($script:__b))" }))
  exit $(if ($script:__b -eq 0) { 0 } else { 1 })
}

# ---- live run ----
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$byTerm = @{}
foreach ($f in (Get-ChildItem (Join-Path $OutDir '*-regular-*.json') -File -ErrorAction SilentlyContinue)) {
  try { $d = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
  foreach ($r in @($d.deals)) {
    $t = [string]$r.found_by_term
    if (-not $t) { continue }
    if (-not $byTerm.ContainsKey($t)) { $byTerm[$t] = New-Object System.Collections.Generic.List[string] }
    [void]$byTerm[$t].Add([string]$r.item)
  }
}

# EVERY captured item name, regardless of which term (if any) found it. Some rows carry
# found_by_term = null - the Walmart berbere rows do - so a term-keyed view alone cannot tell "this food
# is nowhere in Omaha" from "this food is here but arrived under a different key". Conflating those would
# make this check cry wolf on foods the estate demonstrably found, and a noisy shortlist is an unread one.
$allItems = New-Object System.Collections.Generic.List[string]
foreach ($k in $byTerm.Keys) { $allItems.AddRange($byTerm[$k]) }
foreach ($f in (Get-ChildItem (Join-Path $OutDir '*-regular-*.json') -File -ErrorAction SilentlyContinue)) {
  try { $d = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
  foreach ($r in @($d.deals)) { if (-not $r.found_by_term) { [void]$allItems.Add([string]$r.item) } }
}
$allBlob = @($allItems | ForEach-Object { Get-Collapsed $_ })

$suspect = @(); $drift = @(); $untestable = 0; $checked = 0
foreach ($p in $terms.PSObject.Properties) {
  $cid = [string]$p.Name
  # BOTH conventions: Baker's (kroger-api) writes the commodity id into found_by_term, every other store
  # writes the search string. Matching only one produced a FALSE ZERO on ground-sumac in the 2026-08-22
  # audit - the row existed at Baker's and the check could not see it.
  $keys = @($cid)
  if ($p.Value -is [string]) { $keys += [string]$p.Value } else { foreach ($v in @($p.Value)) { $keys += [string]$v } }
  $items = New-Object System.Collections.Generic.List[string]
  foreach ($k in ($keys | Sort-Object -Unique)) { if ($byTerm.ContainsKey($k)) { $items.AddRange($byTerm[$k]) } }
  if ($items.Count -lt $MinRows) { continue }
  $r = Test-TermReturnsItsFood -CommodityId $cid -Items $items.ToArray()
  if (-not $r.testable) { $untestable++; continue }
  $checked++
  if ($r.hits -eq 0) {
    # Does the food exist ANYWHERE in the corpus, under any key or none? That is what separates a term
    # that cannot support a NOT-CARRIED verdict from one that is merely mis-keyed.
    $foundElsewhere = $false
    foreach ($b in $allBlob) {
      foreach ($t in $r.tokens) { if ($b.Contains($t)) { $foundElsewhere = $true; break } }
      if ($foundElsewhere) { break }
    }
    $row = [pscustomobject]@{ commodity = $cid
                              term = $(if ($p.Value -is [string]) { [string]$p.Value } else { (@($p.Value) -join ', ') })
                              rows = $items.Count; example = $items[0] }
    if ($foundElsewhere) { $drift += $row } else { $suspect += $row }
  }
}
$suspect = @($suspect | Sort-Object { -$_.rows })
$drift   = @($drift   | Sort-Object { -$_.rows })

if ($Json) { ([pscustomobject]@{ checked = $checked; untestable = $untestable; suspect = $suspect; term_drift = $drift } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("SEARCHTERMS: {0} commodity term(s) testable against >= {1} captured rows ({2} ids too generic to test)" -f $checked, $MinRows, $untestable)
if ($drift.Count) {
  Write-Output ("SEARCHTERMS: {0} term(s) never return the food, but the food IS in the corpus under another key - a term/matcher bug, NOT a carriage question:" -f $drift.Count)
  foreach ($s in $drift) { Write-Output ("  ~ {0,-26} term '{1}' -> {2} rows, e.g. '{3}'" -f $s.commodity, $s.term, $s.rows, $s.example) }
}
if (-not $suspect.Count) { Write-Output '  ok  no term returns rows while its food is absent from the whole corpus'; exit 0 }
Write-Output ("SEARCHTERMS: {0} term(s) return rows but the food they name appears NOWHERE in the corpus:" -f $suspect.Count)
foreach ($s in $suspect) { Write-Output ("  ? {0,-26} term '{1}' -> {2} rows, e.g. '{3}'" -f $s.commodity, $s.term, $s.rows, $s.example) }
Write-Output '     A term on this list cannot support a NOT-CARRIED verdict: the silence may be the term, not the shelf.'
Write-Output '     Fix the term in commodity-search.json and re-capture BEFORE promoting any absence to grocery\carriage.json.'
exit 0
