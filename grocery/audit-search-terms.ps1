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
#
# A SECOND QUESTION, ADDED 2026-09-25: does a commodity's own term READ AS that commodity? Brad widened
# laundry-detergent to any liquid laundry detergent priced per fl oz (ruling q-2026-09-18-4-laundry-scope) and
# the matching rule followed, but the term stayed "arm and hammer detergent", so every store that rotates
# through commodity-search.json asked for one brand and pull-bakers-ad-list routed Baker's "Tide Laundry
# Detergent" offer to that one-brand search. The engine's own matcher read that term as NO commodity at all.
# So the live run also routes every commodity's first term through the engine matcher (match-lib over
# commodities.json and the global exclude, what compare-deals runs) and lists each term that reads as no
# commodity. A LISTING, NOT A GATE: 38 of 634 first terms read as nothing on the day it landed, and several are
# fine (a store-shelf phrase the rule spells differently). A term that reads as a DIFFERENT commodity is not
# listed: first-match-wins hands "penne pasta" to pasta, which says nothing about the term.
# SCOPE OF A CLEAN REPORT: unsound. A brand-scoped term that also carries the generic words ("tide liquid
# laundry detergent") reads as its commodity and is not listed; the self-test's frozen brand words cover
# laundry-detergent only.
# gate-inputs: grocery\match-lib.ps1, grocery\global-exclude-lib.ps1, grocery\commodities.json, grocery\commodity-search.json, grocery\search-terms-lib.ps1, lib\json-io.ps1, lib\guard-contract.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)

param([string]$OutDir = '', [int]$MinRows = 3, [switch]$Json, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
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
# 'self' when the term, read as a product name by the engine matcher, lands in its own commodity; 'none' when it
# lands nowhere (the laundry founding case); 'other' when first-match-wins hands it to another commodity.
function Get-TermScope {
  param([string]$CommodityId, [string]$ResolvedId)
  if (-not $ResolvedId) { return 'none' }
  if ([string]::Equals($ResolvedId, $CommodityId, [StringComparison]::Ordinal)) { return 'self' }
  return 'other'
}
# The engine's matcher, loaded at SCRIPT scope (a dot-source inside a function would leave its functions behind
# when the function returns). Called by the self-test and by the live run.
function Get-EngineCommodityId {
  param($Matcher, [string]$Name)
  $r = Resolve-Commodity -Matcher $Matcher -Name $Name
  if ($r) { return [string]$r.id }
  return ''
}

if ($SelfTest) {
  $script:__b = 0
  $script:__n = 0
  function T([string]$n, [bool]$ok, [string]$got) { $script:__n++; if ($ok) { Write-Output "  ok  $n" } else { Write-Output "  X   $n  ($got)"; $script:__b++ } }

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

  # ---- does a commodity's own term READ AS that commodity (2026-09-25, the laundry-detergent widening)
  T 'MUST FIRE  a term the engine reads as no commodity is scoped none' ((Get-TermScope 'laundry-detergent' '') -eq 'none') (Get-TermScope 'laundry-detergent' '')
  T 'a term handed to another commodity by first-match-wins is scoped other, not none' ((Get-TermScope 'penne-pasta' 'pasta') -eq 'other') (Get-TermScope 'penne-pasta' 'pasta')
  T 'CLEAN TWIN  a term that lands in its own commodity is scoped self' ((Get-TermScope 'laundry-detergent' 'laundry-detergent') -eq 'self') (Get-TermScope 'laundry-detergent' 'laundry-detergent')
  # The rest reads the TRACKED rule and term files through the engine's own matcher, so a later edit to either
  # that re-narrows the term or lets a pod into the liquid cell goes red here.
  . (Join-Path $root 'match-lib.ps1')
  . (Join-Path $root 'global-exclude-lib.ps1')
  . (Join-Path $root 'search-terms-lib.ps1')
  # LIVE-TWIN (2026-09-25, queue 2026-09-25-110a8f): the live rule file on purpose. A red below reads "the tracked laundry rule or terms changed", never "this watcher went blind"; the frozen cases above carry the must-fires.
  $stDoc = Read-JsonFile (Join-Path $root 'commodities.json')
  $stCl = if ($stDoc.PSObject.Properties['commodities']) { $stDoc.commodities } else { $stDoc }
  $stGex = Get-TcGlobalExclude
  $stM = New-CommodityMatcher -Commodities $stCl -GlobalExclude $stGex
  # The founding term, FROZEN: under the widened rule it reads as nothing, which is how it hid.
  $fd = Get-EngineCommodityId $stM 'arm and hammer detergent'
  T 'MUST FIRE  the founding term "arm and hammer detergent" is scoped none under the widened laundry rule' ((Get-TermScope 'laundry-detergent' $fd) -eq 'none') "resolved=$fd"
  $stTerms = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms
  $ldPairs0 = Get-SearchTermPairs $stTerms
  $ldPairs = @($ldPairs0 | Where-Object { $_.id -eq 'laundry-detergent' })
  $ldGot = @($ldPairs | ForEach-Object { $_.term + '=' + (Get-EngineCommodityId $stM $_.term) })
  $ldSelf = @($ldPairs | Where-Object { (Get-TermScope 'laundry-detergent' (Get-EngineCommodityId $stM $_.term)) -eq 'self' })
  T 'CLEAN TWIN  every live laundry-detergent term reads as laundry-detergent' (($ldPairs.Count -gt 0) -and ($ldSelf.Count -eq $ldPairs.Count)) ($ldGot -join '; ')
  # Brands the widened cell must not be limited to: its current and recent crowns and the brands Omaha shelves.
  $ldBrand = @($ldPairs | Where-Object { $_.term -match '(?i)\barm\s*(?:&|and)\s*hammer\b|\btide\b|\bgain\b|\bpersil\b|\bxtra\b|\bpurex\b|\btandil\b' })
  T 'MUST NOT FIRE  no live laundry-detergent term names a brand (the rule is any brand)' ($ldBrand.Count -eq 0) (@($ldBrand | ForEach-Object { $_.term }) -join '; ')
  # Liquids of three brands, named the way the stores name them (Baker's 2026-09-25, Family Fare 2026-09-25).
  foreach ($liq in @('Tide Original Scent Liquid Laundry Detergent', 'ARM & HAMMER Liquid Laundry Detergent Clean Burst Scent', 'Our Family Free & Clear Laundry Detergent 50 Fl Oz')) {
    $g1 = Get-EngineCommodityId $stM $liq
    T ('CLEAN TWIN  a liquid laundry detergent of any brand lands in laundry-detergent: ' + $liq) ($g1 -eq 'laundry-detergent') "resolved=$g1"
  }
  # Pods, sheets and powder are refused by the MATCHER, never by the term. Gain Flings are pods whose name can
  # omit the word (Family Fare 2026-09-25: 'Gain Laundry Detergent Flings Bl Pl', 18 ct).
  foreach ($notLiq in @('Gain Laundry Detergent Flings Bl Pl', 'Tide Pods Spring Meadow Laundry Detergent Pods', 'ARM & HAMMER Power Sheets Laundry Detergent Fresh Breeze', 'ARM & HAMMER Plus OxiClean Fresh Scent Powder Laundry Detergent')) {
    $g2 = Get-EngineCommodityId $stM $notLiq
    T ('MUST FIRE  the laundry-detergent excludes refuse a non-liquid: ' + $notLiq) ($g2 -ne 'laundry-detergent') "resolved=$g2"
  }
  $g3 = Get-EngineCommodityId $stM 'Gain Laundry Detergent Flings Bl Pl'
  T 'CLEAN TWIN  a Gain Flings name with no "pods" word lands in laundry-pods' ($g3 -eq 'laundry-pods') "resolved=$g3"

  # ---- Q-laundry-rule-gaps (Brad, 2026-09-25, "Yes, through the rule-change gate"): the five liquids the widened rule
  # could not read, frozen as the stores name them. Walmart and Baker's were refused by the board-wide '\bsoda\b' and
  # 'sparkling' excludes, which laundry-detergent now relaxes; the two Aldi names say neither laundry nor liquid and are
  # read by a 'detergent' plus fluid-ounce size include and the one Tide Simply line.
  foreach ($j in @('ARM & HAMMER Baking Soda Fresh Liquid Laundry Detergent, Sparkling Fresh, 110 Fl Oz', 'ARM & HAMMER Baking Soda Fresh Liquid Laundry Detergent Sparkling Fresh Scent', 'ARM & HAMMER Baking Soda Fresh Sparkling Fresh Scent Liquid Laundry Detergent', 'Gain Original Detergent 132 FL OZ', 'Tide Simply Detergent')) {
    $gj = Get-EngineCommodityId $stM $j
    T ('MUST FIRE  a liquid the widened rule could not read now lands in laundry-detergent: ' + $j) ($gj -eq 'laundry-detergent') "resolved=$gj"
  }
  # The relax is laundry-detergent's alone: a soda or sparkling DRINK, and a Baking Soda box, still reach no laundry cell.
  foreach ($dr in @('Coca-Cola Classic Soda 12 pk 12 fl oz', 'LaCroix Sparkling Water Lime 12 pk 12 fl oz', 'ARM & HAMMER Pure Baking Soda 1 lb')) {
    $gd = Get-EngineCommodityId $stM $dr
    T ('MUST NOT FIRE  the soda and sparkling relax admits no drink or baking soda to laundry-detergent: ' + $dr) ($gd -ne 'laundry-detergent') "resolved=$gd"
  }
  # Each name below HITS an include under the new rules (the detergent-plus-size include, or the old include once the soda
  # relax lets it through), so it is the laundry excludes that refuse the pod, the sheet, the powder and the dish detergent.
  foreach ($np in @('Tide Pods Original Detergent 42 ct 34 fl oz', 'ARM & HAMMER Baking Soda Fresh Laundry Detergent Sheets 50 ct', 'ARM & HAMMER Baking Soda Fresh Powder Laundry Detergent 45 oz', 'Power Force Original Blue Dishwashing Detergent 24 FL OZ')) {
    $gn = Get-EngineCommodityId $stM $np
    T ('MUST FIRE  the laundry-detergent excludes still refuse what the new rules let reach them: ' + $np) ($gn -ne 'laundry-detergent') "resolved=$gn"
  }

  # A LITERAL LIST KNOWS ITS OWN NUMBER: 9 original cases, 3 scope cases, 3 live-term cases, 3 liquids, 4 non-liquids, 1 Flings,
  # and for Q-laundry-rule-gaps 5 joins, 3 drinks and a baking soda box, 4 non-liquids under the new include.
  $expect = 35
  if ($script:__n -ne $expect) { Write-Output ("  X   the suite ran {0} case(s), expected {1}" -f $script:__n, $expect); $script:__b++ }
  Write-Output ("audit-search-terms SELF-TEST " + $(if ($script:__b -eq 0) { 'PASS' } else { "FAILED ($($script:__b))" }))
  exit $(if ($script:__b -eq 0) { 0 } else { 1 })
}

# ---- live run ----
$terms = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms
$byTerm = @{}
foreach ($f in (Get-ChildItem (Join-Path $OutDir '*-regular-*.json') -File -ErrorAction SilentlyContinue)) {
  try { $d = Read-JsonFile $f.FullName } catch { continue }
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
  try { $d = Read-JsonFile $f.FullName } catch { continue }
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

# Does each commodity's FIRST term read as that commodity? (2026-09-25; see the header.)
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'search-terms-lib.ps1')
$scDoc = Read-JsonFile (Join-Path $root 'commodities.json')
$scCl = if ($scDoc.PSObject.Properties['commodities']) { $scDoc.commodities } else { $scDoc }
$scGex = Get-TcGlobalExclude
$scM = New-CommodityMatcher -Commodities $scCl -GlobalExclude $scGex
$scPairs = Get-SearchTermPairs $terms
$scRead = 0
$scNone = New-Object System.Collections.Generic.List[object]
foreach ($sp in @($scPairs | Where-Object { $_.primary })) {
  $scRead++
  $rid = Get-EngineCommodityId $scM $sp.term
  if ((Get-TermScope $sp.id $rid) -eq 'none') { [void]$scNone.Add([pscustomobject]@{ commodity = $sp.id; term = $sp.term }) }
}

if ($Json) { ([pscustomobject]@{ checked = $checked; untestable = $untestable; suspect = $suspect; term_drift = $drift; scope_read = $scRead; scope_none = $scNone.ToArray() } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("SEARCHTERMS: {0} commodity term(s) testable against >= {1} captured rows ({2} ids too generic to test)" -f $checked, $MinRows, $untestable)
Write-Output ("SEARCHTERMS-SCOPE: {0} of {1} first term(s) read as NO commodity through the engine matcher - a term that cannot read as its own food may be asking a narrower question than the rule answers:" -f $scNone.Count, $scRead)
foreach ($s in $scNone) { Write-Output ("  - {0,-26} term '{1}'" -f $s.commodity, $s.term) }
if ($drift.Count) {
  Write-Output ("SEARCHTERMS: {0} term(s) never return the food, but the food IS in the corpus under another key - a term/matcher bug, NOT a carriage question:" -f $drift.Count)
  foreach ($s in $drift) { Write-Output ("  ~ {0,-26} term '{1}' -> {2} rows, e.g. '{3}'" -f $s.commodity, $s.term, $s.rows, $s.example) }
}
if (-not $suspect.Count) {
  Write-Output '  ok  no term returns rows while its food is absent from the whole corpus'
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
  Exit-Guard -Name 'search-terms' -Summary ("0 suspect, {0} drift, {1} untestable, scope none {2} of {3}" -f @($drift).Count, $untestable, $scNone.Count, $scRead) -Code 0
}
Write-Output ("SEARCHTERMS: {0} term(s) return rows but the food they name appears NOWHERE in the corpus:" -f $suspect.Count)
foreach ($s in $suspect) { Write-Output ("  ? {0,-26} term '{1}' -> {2} rows, e.g. '{3}'" -f $s.commodity, $s.term, $s.rows, $s.example) }
Write-Output '     A term on this list cannot support a NOT-CARRIED verdict: the silence may be the term, not the shelf.'
Write-Output '     Fix the term in commodity-search.json and re-capture BEFORE promoting any absence to grocery\carriage.json.'
# COMPLETION, NOT VERDICT (2026-08-23). This exits 0 whether or not it found anything - the finding
# lives in its SEARCHTERMS lines - so the exit code alone cannot distinguish "no suspect terms" from
# "died before it looked". That is precisely the shape lib\guard-contract.ps1 exists to close, and it
# matters more here than most: this is a fan-out lane now, and a lane that dies quietly in a pool is
# harder to notice than one that dies in a serial chain.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
Exit-Guard -Name 'search-terms' -Summary ("{0} suspect, {1} drift, {2} untestable, scope none {3} of {4}" -f @($suspect).Count, @($drift).Count, $untestable, $scNone.Count, $scRead) -Code 0
