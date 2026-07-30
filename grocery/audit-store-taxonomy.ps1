<#
  audit-store-taxonomy.ps1 - THE SECOND OPINION. Read-only. Never writes to the board.

  WHY THIS EXISTS. There is exactly ONE statement in this estate about what commodity a product is: the
  include regex in commodities.json. Every downstream check inherits that premise, which is why 47 of the 99
  wrong numbers that reached shoppers in 22 days were one bug - an include matching a product that is not the
  commodity - and why neither SKU identity nor a name detector fixes it. Identity proves "this price belongs
  to this product"; NOTHING proved "this product belongs to this commodity".

  This audit asks a source that has never been asked: THE STORE'S OWN SHELF. Family Fare's Freshop feed
  already hands us the store's taxonomy on every row and has for weeks - it is sitting inside canonical_url,
  which the puller records for the LINK and nothing ever read as a CLAIM:

      https://www.shopfamilyfare.com/shop/pets_wildlife/dog/dry_dog_food/blue_buffalo_..._5_lb/p/1564405684712559689
                                           ^department  ^category ^subcategory

  Family Fare, in its own catalogue, says that product is dog food. Our brown-rice include says it is brown
  rice. Two independent statements, and only one of them is ours. That disagreement is the whole signal.

  WHAT IT IS AND IS NOT. Measured on the live board 2026-07-30 (2870 Family Fare candidate rows joined to a
  taxonomy): 17 disagreements, all 17 adjudicated WRONG PRODUCT by hand, and ZERO of them were rankable - none
  carried a unit price, so none could have taken a cell that day. Re-run over 2026-07-25 and -26 it flags 3 and
  3, same precision, zero live cells. So this is a REVIEW QUEUE that catches wrong-product matches while they
  are still candidates, NOT a gate: it has not yet been shown to catch a published error, and it must not be
  allowed to hold a publish on that record. -FailOnFlag exists so that decision can be made later from
  evidence, and it is deliberately OFF.

  IT IS NOT A SECOND COPY OF THE MATCHER. It reads out\candidates-<date>.json - compare-deals' own record of
  what its rules matched - so there is one copy of the matching math, exactly as audit-match-soundness does.
  It is also independent of audit-food-category.ps1, which polices the same bug class from NAME tokens
  (category-excludes.json). Names are our words; a department is the store's.

  EXIT CODES  0 = ran and judged (flags are printed and written, they do not fail the run)
              2 = ONLY with -FailOnFlag (off by default), disagreements found
              3 = BLIND: it judged ZERO rows. Zero rows judged is never "clean" - it means no store feed
                  carried a taxonomy, or every department was unknown to taxonomy-map.json.

  COVERAGE HONESTY. A department present in a store's feed but listed in NEITHER food_departments NOR
  nonfood_departments in taxonomy-map.json is reported UNKNOWN and its rows are NOT judged; the count and the
  names are printed so a human can file them. Hy-Vee (row field store_department) and Baker's (store_category)
  are read here too; while their pullers do not yet record those fields, this audit prints "0 product(s) with a
  department - NOT COVERED" for them every run rather than letting an unchecked store read as a clean one.
  When the fields do arrive, their departments will land in the unknown-department list until a human files
  them into taxonomy-map.json - which is the correct order: judge nothing until the vocabulary is real.

  USAGE
    audit-store-taxonomy.ps1                 judge the newest board + candidates
    audit-store-taxonomy.ps1 -SelfTest       frozen must-fire + clean-twin fixtures, no live data
    audit-store-taxonomy.ps1 -FailOnFlag     exit 2 on any disagreement (NOT wired into the publish)
#>
param(
  [string]$Root = "",
  [string]$OutDir = "",
  [string]$ReportDir = "",
  [string]$CompareFile = "",
  [string]$CandidatesFile = "",
  [string]$MapFile = "",
  [int]$MaxTaxonomyAgeDays = 30,
  [switch]$FailOnFlag,
  [switch]$Quiet,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $OutDir) { $OutDir = Join-Path $Root 'out' }
if (-not $ReportDir) { $ReportDir = $OutDir }
if (-not $MapFile) { $MapFile = Join-Path $Root 'taxonomy-map.json' }

# ------------------------------------------------------------------ the real code path (self-test runs THIS)
function Get-FreshopTaxonomy([string]$url) {
  <#
    Freshop canonical_url -> the store's own department/category, or $null when the URL carries none.
    THE SHAPE IS /shop/<dept>/<cat>[/<subcat>]/<slug>/p/<id> and it must be anchored on the /p/<id> tail.
    Measured on 2026-07-30: 2972 URLs have 4 segments, 517 have 3, and THREE have exactly ONE -
    ".../shop/kraft_grated_cheese_parmesan_cheese_8_oz/p/1564405684716409165". A naive
    "/shop/([^/]+)/([^/]+)/" reads that product's own SLUG as its department and "p" as its category, i.e. it
    invents a taxonomy for a row that has none. A row with no taxonomy must return nothing, never a guess.
  #>
  if (-not $url) { return $null }
  $m = [regex]::Match([string]$url, '/shop/(?<path>.+)/p/[^/]+$')
  if (-not $m.Success) { return $null }
  $segs = @([string]$m.Groups['path'].Value -split '/' | Where-Object { $_ })
  if ($segs.Count -lt 3) { return $null }
  return (New-Object psobject -Property @{ dept = [string]$segs[0]; sub = [string]$segs[1] })
}

function Get-TaxonomyVerdict {
  <#
    The single decision. Returns one of:
      'no-taxonomy'        the row carried no department at all
      'unknown-store'      taxonomy-map.json has no entry for this store
      'unknown-department' the store used a department this map does not classify - NOT judged, reported
      'ok'                 the commodity and the department agree (or the commodity is itself non-food)
      'allowed'            a reviewed exception in commodity_department_allow
      'FLAG'               a FOOD commodity matched to a product the store shelves as non-edible
  #>
  param(
    [bool]$IsFoodCommodity,
    [string]$CommodityId,
    [string]$Store,
    [string]$Dept,
    $StoreMap,
    $AllowList
  )
  if (-not $Dept) { return 'no-taxonomy' }
  if (-not $StoreMap) { return 'unknown-store' }
  $nf = @($StoreMap.nonfood_departments)
  $fd = @($StoreMap.food_departments)
  if (($nf -notcontains $Dept) -and ($fd -notcontains $Dept)) { return 'unknown-department' }
  if (-not $IsFoodCommodity) { return 'ok' }
  if ($nf -notcontains $Dept) { return 'ok' }
  foreach ($a in @($AllowList)) {
    if ((([string]$a.id) -eq $CommodityId) -and (([string]$a.store) -eq $Store) -and (([string]$a.department) -eq $Dept)) { return 'allowed' }
  }
  return 'FLAG'
}

# ------------------------------------------------------------------ self-test: frozen, synthetic, real path
if ($SelfTest) {
  $fail = 0
  function T([string]$label, $got, [string]$want) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    if ($g -eq $want) { Write-Output ('ok    ' + $label + '  -> ' + $g) }
    else { Write-Output ('FAIL  ' + $label + '  got [' + $g + '] want [' + $want + ']'); $script:fail++ }
  }
  # Frozen store map. NEVER read from taxonomy-map.json here: a fixture that loads live config stops testing
  # the code the day someone edits the config.
  $fxMap = New-Object psobject -Property @{
    food_departments    = @('pantry','beverages','dairy','meat','freezer','fresh_fruits_vegetables','deli','bakery','seasonal_special_occasion','beer_wine_spirits')
    nonfood_departments = @('health_beauty','household','pets_wildlife')
  }
  $fxAllow = @( (New-Object psobject -Property @{ id='protein-bars'; store='Family Fare'; department='health_beauty' }) )

  # --- MUST-FIRE 1: the founding bug. Real row, Family Fare, 2026-07-30: our brown-rice include matched
  # "Blue Buffalo Natural Puppy Chicken And Brown Rice Recipe Food For Puppies 5 Lb" $25.99 / 5 lb. Family
  # Fare's own catalogue files that product under pets_wildlife/dog/dry_dog_food. 47 of the 99 wrong numbers
  # that reached shoppers were this class, and no name rule, band, or SKU check saw any of them.
  $bbUrl = 'https://www.shopfamilyfare.com/shop/pets_wildlife/dog/dry_dog_food/blue_buffalo_natural_puppy_chicken_and_brown_rice_recipe_food_for_puppies_5_lb/p/1564405684712559689'
  $bb = Get-FreshopTaxonomy $bbUrl
  T 'MUST-FIRE parse: Blue Buffalo url -> pets_wildlife' $bb.dept 'pets_wildlife'
  T 'MUST-FIRE verdict: brown-rice (food) x pets_wildlife' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'brown-rice' -Store 'Family Fare' -Dept $bb.dept -StoreMap $fxMap -AllowList $fxAllow) 'FLAG'

  # --- MUST-FIRE 2: the parser trap found while writing this audit. THREE live Family Fare rows carry a
  # canonical_url with no taxonomy at all, just the slug. Reading the slug as a department invents a claim
  # about a row that made none - the same class of error this whole audit exists to catch.
  T 'MUST-FIRE parse: taxonomy-less url yields NOTHING' (Get-FreshopTaxonomy 'https://www.shopfamilyfare.com/shop/kraft_grated_cheese_parmesan_cheese_8_oz/p/1564405684716409165') '<null>'
  T 'MUST-FIRE verdict: a row with no taxonomy is not judged' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'shredded-cheese' -Store 'Family Fare' -Dept '' -StoreMap $fxMap -AllowList $fxAllow) 'no-taxonomy'

  # --- MUST-FIRE 3: an unfamiliar department must say so, never pass as food. "ok from zero knowledge" is the
  # same failure as "ok from zero rows".
  T 'MUST-FIRE: unmapped department is UNKNOWN, not ok' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'bananas' -Store 'Family Fare' -Dept 'garden_center' -StoreMap $fxMap -AllowList $fxAllow) 'unknown-department'
  T 'MUST-FIRE: unmapped STORE is UNKNOWN, not ok'      (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'bananas' -Store 'Aldi' -Dept 'pantry' -StoreMap $null -AllowList $fxAllow) 'unknown-store'

  # --- CLEAN TWIN 1: the same dog food on the commodity it actually belongs to must stay silent.
  T 'CLEAN: dog-food (non-food commodity) x pets_wildlife' (Get-TaxonomyVerdict -IsFoodCommodity $false -CommodityId 'dog-food' -Store 'Family Fare' -Dept 'pets_wildlife' -StoreMap $fxMap -AllowList $fxAllow) 'ok'

  # --- CLEAN TWIN 2: the one measured legitimate crossing. Family Fare shelves protein bars in
  # health_beauty/adult_nutrition. Without the allowlist this audit flags 34 rows at 50% precision; with it,
  # 17 rows at 17/17. A detector with a reviewed exception valve is the difference.
  $pbUrl = 'https://www.shopfamilyfare.com/shop/health_beauty/adult_nutrition/protein_energy_meal_bars/builders_chocolatey_peanut_butter_protein_bars_6_ea/p/525550'
  $pb = Get-FreshopTaxonomy $pbUrl
  T 'CLEAN parse: protein bar url -> health_beauty' $pb.dept 'health_beauty'
  T 'CLEAN: allowlisted protein-bars x health_beauty' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'protein-bars' -Store 'Family Fare' -Dept $pb.dept -StoreMap $fxMap -AllowList $fxAllow) 'allowed'
  # ...and the allowlist must be SCOPED: the same department on a different commodity still fires. "cookies"
  # matched five protein bars on 2026-07-30 and every one of them was wrong.
  T 'CLEAN-TWIN scope: cookies x health_beauty still FLAGS' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'cookies' -Store 'Family Fare' -Dept 'health_beauty' -StoreMap $fxMap -AllowList $fxAllow) 'FLAG'

  # --- CLEAN TWIN 3: the measured false positive this rule deliberately does NOT make. Family Fare files
  # "Pampa Rice, White, Long Grain 16 Oz" under seasonal_special_occasion/trial_sizes_store. It is real rice,
  # and seasonal_special_occasion is declared a FOOD department, so the audit must stay silent.
  $riceUrl = 'https://www.shopfamilyfare.com/shop/seasonal_special_occasion/trial_sizes_store/pampa_rice_white_long_grain_16_oz/p/7017358'
  $rc = Get-FreshopTaxonomy $riceUrl
  T 'CLEAN parse: 3-segment url -> seasonal_special_occasion' $rc.dept 'seasonal_special_occasion'
  T 'CLEAN: rice x seasonal_special_occasion is silent' (Get-TaxonomyVerdict -IsFoodCommodity $true -CommodityId 'rice' -Store 'Family Fare' -Dept $rc.dept -StoreMap $fxMap -AllowList $fxAllow) 'ok'
  T 'CLEAN parse: 4-segment url subcategory' $rc.sub 'trial_sizes_store'

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 }
  Write-Output ('SELF-TEST FAIL: ' + $fail + ' case(s)'); exit 1
}

# ------------------------------------------------------------------ live run
function Log($m) { if (-not $Quiet) { Write-Output $m } }
$today = (Get-Date).ToString('yyyy-MM-dd')

if (-not (Test-Path $MapFile)) { Write-Output ('taxonomy BLIND: no map file at ' + $MapFile + ' - nothing can be judged'); exit 3 }
$map = ((Get-Content $MapFile -Raw) + '') | ConvertFrom-Json
if (-not $map) { Write-Output ('taxonomy BLIND: ' + $MapFile + ' parsed to nothing'); exit 3 }
$allow = @()
if ($map.PSObject.Properties['commodity_department_allow']) { $allow = @($map.commodity_department_allow) }

# our own category per commodity. audit-food-category.ps1 uses exactly these four labels for "not edible".
$NONFOOD_LABELS = @('Household','Personal Care','Baby','Pet')
$isFood = @{}
foreach ($c in (((Get-Content (Join-Path $Root 'categories.json') -Raw) + '') | ConvertFrom-Json).categories) {
  $lab = [string]$c.label
  foreach ($id in ([string]$c.commodities -split '\s+')) {
    if ($id) { $isFood[$id] = ($NONFOOD_LABELS -notcontains $lab) }
  }
}

function Newest-Dated([string]$glob, [string]$pattern) {
  $best = $null; $bestD = $null
  foreach ($f in (Get-ChildItem $glob -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.BaseName, $pattern)
    if (-not $m.Success) { continue }
    $d = $null
    try { $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null) } catch { continue }
    if (($null -eq $bestD) -or ($d -gt $bestD)) { $bestD = $d; $best = $f }
  }
  if (-not $best) { return $null }
  return (New-Object psobject -Property @{ file = $best.FullName; name = $best.Name; date = $bestD })
}

# ---- build name -> taxonomy, per store. Newest file wins; older files inside the window fill the gaps.
# WHY A WINDOW AND NOT ONE FILE: a product's AISLE is stable metadata, but the file that carries it is not.
# Family Fare's pull was throttled on 2026-07-27/28/29 and wrote no regular file at all, so a same-day-only
# lookup would have reported "0 rows judged" on three consecutive days and called it clean.
$tax = @{}          # "store|lowername" -> @{dept;sub;src}
$srcNote = New-Object System.Collections.Generic.List[string]

$ffFiles = @(Get-ChildItem (Join-Path $OutDir 'regular\family-fare-regular-*.json') -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match '^family-fare-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
$ffUsed = 0; $ffRows = 0
foreach ($f in $ffFiles) {
  $mm = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')
  $fd = $null; try { $fd = [datetime]::ParseExact($mm.Groups[1].Value, 'yyyy-MM-dd', $null) } catch { continue }
  if (((Get-Date).Date - $fd).TotalDays -gt $MaxTaxonomyAgeDays) { continue }
  $doc = $null
  try { $doc = ((Get-Content $f.FullName -Raw) + '') | ConvertFrom-Json } catch { continue }
  if (-not $doc) { continue }
  $ffUsed++
  foreach ($r in @($doc.deals)) {
    if (-not $r.canonical_url) { continue }
    $k = 'Family Fare|' + ([string]$r.item).ToLower().Trim()
    if ($tax.ContainsKey($k)) { continue }
    $t = Get-FreshopTaxonomy ([string]$r.canonical_url)
    if (-not $t) { continue }
    $tax[$k] = (New-Object psobject -Property @{ dept = $t.dept; sub = $t.sub; src = $f.Name })
    $ffRows++
  }
}
$srcNote.Add(('Family Fare: canonical_url from ' + $ffUsed + ' file(s) within ' + $MaxTaxonomyAgeDays + 'd -> ' + $ffRows + ' product(s) with a department' + $(if ($ffFiles.Count) { ' (newest ' + $ffFiles[0].Name + ')' } else { '' })))

# Hy-Vee and Baker's: their pullers do not record a taxonomy field YET. Read the field anyway so this audit
# starts working the moment they do, and SAY the count out loud so 0 is never mistaken for checked.
foreach ($sp in @(
  (New-Object psobject -Property @{ store = 'Hy-Vee';   glob = 'regular\hyvee-regular-*.json';  pat = '^hyvee-regular-\d{4}-\d{2}-\d{2}$';  field = 'store_department' }),
  (New-Object psobject -Property @{ store = "Baker's";  glob = 'regular\bakers-regular-*.json'; pat = '^bakers-regular-\d{4}-\d{2}-\d{2}$'; field = 'store_category'   })
)) {
  $n = Newest-Dated (Join-Path $OutDir $sp.glob) '(\d{4}-\d{2}-\d{2})$'
  if (-not $n) { $srcNote.Add(($sp.store + ': no dated regular file found - 0 product(s) with a department')); continue }
  $doc = $null
  try { $doc = ((Get-Content $n.file -Raw) + '') | ConvertFrom-Json } catch { $doc = $null }
  $cnt = 0
  foreach ($r in @($doc.deals)) {
    $v = [string]$r.($sp.field)
    if (-not $v) { continue }
    $k = $sp.store + '|' + ([string]$r.item).ToLower().Trim()
    if ($tax.ContainsKey($k)) { continue }
    $tax[$k] = (New-Object psobject -Property @{ dept = $v; sub = ''; src = $n.name })
    $cnt++
  }
  $srcNote.Add(($sp.store + ': row field ' + $sp.field + ' in ' + $n.name + ' -> ' + $cnt + ' product(s) with a department' + $(if ($cnt -eq 0) { ' (NOT COVERED - either the puller does not record this field yet, or the feed returned none. Zero is not clean.)' } else { '' })))
}

# ---- the two surfaces
if (-not $CompareFile) {
  $n = Newest-Dated (Join-Path $OutDir 'comparison-*.json') '(\d{4}-\d{2}-\d{2})$'
  if ($n) { $CompareFile = $n.file }
}
if (-not $CandidatesFile) {
  $n = Newest-Dated (Join-Path $OutDir 'candidates-*.json') '(\d{4}-\d{2}-\d{2})$'
  if ($n) { $CandidatesFile = $n.file }
}

$judged = 0; $unknownDept = @{}; $noTax = 0; $unknownStore = @{}
$cellFlags = New-Object System.Collections.Generic.List[object]
$candFlags = New-Object System.Collections.Generic.List[object]

function Judge($store, $name, $cid) {
  $k = [string]$store + '|' + ([string]$name).ToLower().Trim()
  if (-not $tax.ContainsKey($k)) { return $null }
  $t = $tax[$k]
  $sm = $null
  if ($map.stores -and $map.stores.PSObject.Properties[[string]$store]) { $sm = $map.stores.([string]$store) }
  $food = $true
  if ($isFood.ContainsKey([string]$cid)) { $food = [bool]$isFood[[string]$cid] }
  $v = Get-TaxonomyVerdict -IsFoodCommodity $food -CommodityId ([string]$cid) -Store ([string]$store) -Dept ([string]$t.dept) -StoreMap $sm -AllowList $allow
  return (New-Object psobject -Property @{ verdict = $v; dept = $t.dept; sub = $t.sub; src = $t.src })
}

if ($CompareFile -and (Test-Path $CompareFile)) {
  foreach ($row in (((Get-Content $CompareFile -Raw) + '') | ConvertFrom-Json).comparison) {
    foreach ($s in @($row.stores)) {
      $j = Judge $s.store $s.item $row.id
      if (-not $j) { continue }
      switch ($j.verdict) {
        'unknown-department' { $unknownDept[([string]$s.store + '/' + [string]$j.dept)] = 1 + [int]$unknownDept[([string]$s.store + '/' + [string]$j.dept)] }
        'unknown-store'      { $unknownStore[[string]$s.store] = 1 + [int]$unknownStore[[string]$s.store] }
        'no-taxonomy'        { $script:noTax++ }
        default {
          $script:judged++
          if ($j.verdict -eq 'FLAG') {
            $cellFlags.Add((New-Object psobject -Property @{
              id = [string]$row.id; store = [string]$s.store; item = [string]$s.item; unit = [string]$row.unit
              per_unit = $s.per_unit; department = [string]$j.dept; subcategory = [string]$j.sub
              crown = ([string]$row.cheapest_store -eq [string]$s.store); taxonomy_src = [string]$j.src }))
          }
        }
      }
    }
  }
}

if ($CandidatesFile -and (Test-Path $CandidatesFile)) {
  foreach ($cm in (((Get-Content $CandidatesFile -Raw) + '') | ConvertFrom-Json).commodities) {
    foreach ($d in @($cm.candidates)) {
      $j = Judge $d.store $d.name $cm.id
      if (-not $j) { continue }
      switch ($j.verdict) {
        'unknown-department' { $unknownDept[([string]$d.store + '/' + [string]$j.dept)] = 1 + [int]$unknownDept[([string]$d.store + '/' + [string]$j.dept)] }
        'unknown-store'      { $unknownStore[[string]$d.store] = 1 + [int]$unknownStore[[string]$d.store] }
        'no-taxonomy'        { $script:noTax++ }
        default {
          $script:judged++
          if ($j.verdict -eq 'FLAG') {
            $candFlags.Add((New-Object psobject -Property @{
              id = [string]$cm.id; store = [string]$d.store; item = [string]$d.name
              department = [string]$j.dept; subcategory = [string]$j.sub
              unit_price = $d.unit_price; rankable = [bool]$d.unit_price; taxonomy_src = [string]$j.src }))
          }
        }
      }
    }
  }
}

foreach ($s in $srcNote) { Log ('taxonomy source: ' + $s) }
Log ('taxonomy: judged ' + $judged + ' row(s) across board cells + candidates; ' + $cellFlags.Count + ' LIVE CELL disagreement(s), ' + $candFlags.Count + ' candidate disagreement(s)')
if ($unknownDept.Count) {
  Log ('taxonomy: ' + (@($unknownDept.Values | Measure-Object -Sum).Sum) + ' row(s) sit in ' + $unknownDept.Count + ' department(s) NOT classified in taxonomy-map.json - they were NOT judged:')
  foreach ($kv in ($unknownDept.GetEnumerator() | Sort-Object Value -Descending)) { Log ('    ' + $kv.Value + 'x  ' + $kv.Key) }
}
if ($unknownStore.Count) {
  foreach ($kv in ($unknownStore.GetEnumerator() | Sort-Object Value -Descending)) { Log ('taxonomy: ' + $kv.Value + ' row(s) from ' + $kv.Key + ' carried a department but that store has no entry in taxonomy-map.json - NOT judged') }
}

foreach ($x in $cellFlags) { Log ('  LIVE CELL  ' + $x.id + ' @ ' + $x.store + $(if ($x.crown) { ' [CROWN]' } else { '' }) + ' -> ' + $x.department + '/' + $x.subcategory + '  ' + $x.item) }
foreach ($x in ($candFlags | Sort-Object id)) { Log ('  candidate  ' + $x.id + ' @ ' + $x.store + $(if ($x.rankable) { ' [RANKABLE]' } else { '' }) + ' -> ' + $x.department + '/' + $x.subcategory + '  ' + $x.item) }

# Build the unknown-department list by hand. In PS 5.1 an @(...) wrapper around a piped GetEnumerator() of an
# EMPTY hashtable throws ArgumentException - i.e. this audit would crash on exactly the clean day it is meant
# to report nothing on. Same family as "@() around a List[object] throws".
$unkList = New-Object System.Collections.Generic.List[object]
foreach ($k in @($unknownDept.Keys)) { $unkList.Add((New-Object psobject -Property @{ key = [string]$k; rows = [int]$unknownDept[$k] })) }
$report = New-Object psobject -Property @{
  date = $today
  judged = $judged
  no_taxonomy_rows = $noTax
  sources = $srcNote.ToArray()
  unknown_departments = $unkList.ToArray()
  live_cell_disagreements = $cellFlags.ToArray()
  candidate_disagreements = $candFlags.ToArray()
  note = 'The store said one thing about this product and our include regex said another. A LIVE CELL entry is on the board right now. A candidate entry has not won a cell but proves the rule matches the wrong product. This is a REVIEW QUEUE, not a gate - see the header.'
}
$rf = Join-Path $ReportDir ('taxonomy-disagreements-' + $today + '.json')
($report | ConvertTo-Json -Depth 6) | Set-Content $rf -Encoding UTF8
Log ('taxonomy: report -> ' + $rf)

if ($judged -eq 0) {
  Write-Output 'taxonomy BLIND: judged ZERO rows. No store feed carried a department this audit could classify, so its silence proves nothing about the board.'
  exit 3
}
if ($FailOnFlag -and (($cellFlags.Count + $candFlags.Count) -gt 0)) { exit 2 }
exit 0

