<#
  select-fareway-shop.ps1 - turns the RAW Fareway storefront candidate captures (one {id,term,candidates[]}
  per commodity, produced by the browser sweep) into the one-row-per-commodity shop file that
  build-fareway-regular.ps1 consumes: out\fareway\fareway-shop-<date>.json.

  For each commodity it keeps only candidates whose NAME matches >=1 of the commodity's include
  patterns AND 0 of its exclude patterns (commodities.json), then picks the CHEAPEST PLAIN base item
  by a heuristic per-unit (weighted -> $/lb; oz/floz package -> price/oz; else absolute price), so the
  Fareway cell reflects the cheapest matching everyday/sale shelf price. Emits {id,name,price,per,orig,
  unit,size,url}. build-fareway-regular then does the authoritative unit conversion + link emission.

  THE URL SLUG IS READ TOO (2026-09-10, queue 2026-09-10-b91a0a). The storefront names some products by brand
  and flavour and keeps the type noun only in the slug: 'KIND Almond & Coconut' is
  .../20002358-kind-bars-almond-coconut-6-ea. coconut's exclude already carried '\bbars?\b', but it was tested
  against the display name alone, the bar passed, and the cheapest survivor won: $7.98 / 6 = $1.33 each beat the
  real 'Coconut' at $3.99 and took the Whole Coconut crown on 2026-09-10. A candidate whose name passes but whose
  name + slug words trip an exclude is now DEMOTED, never dropped: it can win only when no clean candidate exists.
  Demotion, not deletion, because the slug test has measured false kills: over the 20 rescue files (355 terms,
  16,811 candidates) 71 candidates across 28 commodities pass on the name and trip on the slug, and two of them
  are legitimate ('uncooked' matched by chicken-breast's 'cooked'; 'litter box 20 lb' by cat-litter's box rule).

    .\select-fareway-shop.ps1 -In <capture.jsonl> -Today 2026-09-10
    .\select-fareway-shop.ps1 -SelfTest          frozen coconut fixture + clean twins, no data read
#>
param(
  [string]$In = "",
  [string]$Out = "",
  [string]$Today = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$asof = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
$scratch = 'C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\32c86fd5-620b-4a8f-a670-285987b7c2fb\scratchpad'
if (-not $In)  { $In  = Join-Path $scratch "fareway-shop-$asof.jsonl" }
if (-not $Out) { $Out = Join-Path $root "out\fareway\fareway-shop-$asof.json" }

# ---------------------------------------------------------------- PER-UNIT (2026-08-20)
# This scored EVERY packaged Fareway row at its ABSOLUTE price, so "cheapest per unit" really
# meant "smallest package" - the worst $/oz on the shelf. Two causes, both fixed here:
#
#   1. CASE. [regex]::Match is case-SENSITIVE, and the Fareway storefront always capitalises the
#      size ("52 Oz", "15 Oz"). The oz branch therefore never fired even once. Measured on the
#      2026-08-20 capture: orange-juice took a 52 oz at $0.077/floz over a 64 oz at $0.062, and
#      canned-pasta a 15 oz at $0.100/oz over a 60 oz at $0.083 - each ~20% too expensive.
#
#   2. NO COUNT. A count-unit commodity ("each") has its size in a pack count, not in ounces, and
#      nothing here read one: microwave-popcorn took a 3-pack at $1.00/bag over a 12-pack at $0.50.
#
# NORMALISE IN THE COMMODITY'S OWN FAMILY, NEVER ACROSS FAMILIES. Scoring one candidate in $/oz
# and its rival in $/ct puts two different quantities in one sort and the smaller NUMBER wins,
# which is not the cheaper item. So the declared unit picks the family and only that family scores.
#
# UNSCORABLE SORTS LAST, IT DOES NOT SORT AS ZERO. A row we cannot normalise is ranked behind every
# row we can, then ordered among its peers by absolute price. That keeps the old behaviour where a
# commodity has no scorable candidate at all (plain "Cucumber Each"), without letting an unscored
# row's raw price masquerade as a per-unit and beat a genuinely cheaper one.
#
# AND IT DELIBERATELY DOES NOT CONVERT LITRES. "Fareway Avocado Oil 1 L" is the best $/floz on the
# shelf, and picking it would LOSE THE CELL: build-fareway-regular lists l/ml as non-adoptable, so
# it emits the row size-less and the engine (correctly) refuses to per-unit a size-less row. A
# candidate the builder cannot price is not a cheaper candidate, it is a missing one - so an
# un-adoptable size stays unscorable on purpose. Do not "fix" this without fixing the builder first.
function AbsPrice($c) {
  $price = 0.0; [void][double]::TryParse((([string]$c.price) -replace '[^0-9.]',''), [ref]$price)
  return $price
}

# THE COMMODITY'S DECLARED UNIT PICKS THE FAMILY, AND ONLY THAT FAMILY SCORES.
#   count  -> $ per item      weight -> $ per oz       volume -> $ per fl oz
# Scoring one candidate in $/lb and its rival in $/oz is a 16x error wearing the same
# shape as a price, and the SMALLER NUMBER WINS a sort, so the mismatch does not look
# wrong - it looks cheap. Measured 2026-08-20: plain "Asparagus" at $4.99/lb lost its
# own cell to a $3.99 potato-and-onion side dish scored at $0.38/oz.
function UnitFamily([string]$u) {
  $u = ([string]$u).ToLower().Trim()
  if ($u -match '^(each|ct|count|dozen)$')      { return 'count'  }
  if ($u -match '^(fl_?oz|floz|ml|l|gal|qt)$')  { return 'volume' }
  return 'weight'    # lb / oz / g and anything unrecognised: weight is the safe default
}

# One size parser for every family. Handles the multipack form the storefront writes as
# "8 x 20 fl oz" - reading only the 20 there understates a pack by 8x, which is the same
# pack-price-as-unit-size bug the estate has now hit at three separate stores.
# Returns $null when the size cannot be read IN THIS FAMILY. Litres and millilitres are
# deliberately unreadable: build-fareway-regular lists them as non-adoptable, so a row
# picked on a litre size is emitted size-less and the engine refuses it - a candidate the
# builder cannot price is not a cheaper candidate, it is a missing cell.
function SizeIn($sz, [string]$fam) {
  $s = ([string]$sz).ToLower().Trim() -replace '^about\s+', ''
  if (-not $s) { return $null }
  # "N x M <unit>" means N items of M <unit> each, and the two families want opposite
  # halves of that. Weight/volume want the TOTAL (8 x 20 fl oz = 160 fl oz). Count wants
  # the ITEM COUNT, which is N alone - multiplying there turns 68 bags of 13 gal into 884
  # and prices a box of bin liners at a tenth of a cent apiece.
  $n = 1.0
  $m = [regex]::Match($s, '^(\d+(?:\.\d+)?)\s*x\s*(.+)$')
  if ($m.Success) {
    if ($fam -eq 'count') { return [double]$m.Groups[1].Value }
    $n = [double]$m.Groups[1].Value; $s = $m.Groups[2].Value.Trim()
  }
  $u = [regex]::Match($s, '^(\d+(?:\.\d+)?)\s*([a-z ]+)')
  if (-not $u.Success) { return $null }
  $v = [double]$u.Groups[1].Value * $n
  $unit = ($u.Groups[2].Value -replace '\s+', ' ').Trim()
  if ($v -le 0) { return $null }
  switch -Regex ($unit) {
    '^(ct|count|each|ea|pk|pack)$' { if ($fam -eq 'count')  { return $v      } else { return $null } }
    '^fl oz$'                      { if ($fam -eq 'volume') { return $v      } else { return $null } }
    '^gal(lon)?s?$'                { if ($fam -eq 'volume') { return $v*128  } else { return $null } }
    '^(qt|quarts?)$'               { if ($fam -eq 'volume') { return $v*32   } else { return $null } }
    '^oz$'                         { if ($fam -eq 'weight') { return $v      } elseif ($fam -eq 'volume') { return $v } else { return $null } }
    '^(lb|lbs|pounds?)$'           { if ($fam -eq 'weight') { return $v*16   } else { return $null } }
    default { return $null }
  }
}

# A pack count can also hide in the NAME or the SLUG when the size line omits it
# ("...-24-ct"). Only ever used to DIVIDE a pack price, never to invent a size.
function CountOf($c) {
  foreach ($src in @([string]$c.name, [string]$c.url)) {
    if (-not $src) { continue }
    $m = [regex]::Match($src, '(?i)(\d+)\s*-?\s*(?:ct|count|pack|pk)\b')
    if ($m.Success) { $n = [double]$m.Groups[1].Value; if ($n -gt 0) { return $n } }
  }
  return 0.0
}

# $null = could not be normalised in this commodity's family (NOT "free").
function PerUnit($c, [string]$fam) {
  $price = AbsPrice $c
  if ($price -le 0) { return $null }
  # The storefront's own per-unit line, e.g. "$4.99 / lb", is the store's arithmetic, so
  # prefer it - but only after converting it into the family's canonical unit.
  $um = [regex]::Match([string]$c.unit, '(?i)\$?\s*([\d.]+)\s*/\s*(lb|pound|oz|fl\s*oz|ea|each|ct)')
  if ($um.Success) {
    $v = [double]$um.Groups[1].Value
    switch -Regex ($um.Groups[2].Value.ToLower()) {
      '^(lb|pound)$'   { if ($fam -eq 'weight') { return $v / 16 } }
      '^oz$'           { if ($fam -eq 'weight') { return $v      } }
      '^fl\s*oz$'      { if ($fam -eq 'volume') { return $v      } }
      '^(ea|each|ct)$' { if ($fam -eq 'count')  { return $v      } }
    }
  }
  if (([string]$c.per).ToLower() -eq 'pound' -and $fam -eq 'weight') { return $price / 16 }
  $sz = SizeIn ([string]$c.size) $fam
  if ($null -ne $sz) { return $price / $sz }
  if ($fam -eq 'count') { $n = CountOf $c; if ($n -gt 0) { return $price / $n } }
  return $null
}

# The words of a product URL's last path segment, without its numeric id:
# .../products/20002358-kind-bars-almond-coconut-6-ea  ->  'kind bars almond coconut 6 ea'
function Get-SlugWords([string]$url) {
  if (-not $url) { return '' }
  $tail = @((($url -replace '[?#].*$', '') -replace '/+$', '') -split '/')[-1]
  return ((($tail -replace '^\d+-', '') -replace '-', ' ').Trim())
}

# ONE COMMODITY'S CHOICE, as a pure function so -SelfTest drives the code the main loop runs.
# Returns @{ best = <the chosen candidate, or $null when none passes the name test>; demoted = <log lines> }.
# RANK, lowest wins:
#   0  clean, scored in the commodity's own family
#   1  clean, unscorable (ordered among its peers by absolute price, exactly as before)
#   2  SLUG-DEMOTED: the name passes but name + slug words trip an exclude. Behind every clean candidate,
#      scored or not, because a per-unit score and an absolute price must never meet in one sort; inside
#      this rank a scored row still beats an unscored one (Sub).
#   3  no usable price at all
# For candidates the slug does not demote, the order is identical to the pre-2026-09-10 ranking.
function Select-ShopCandidate {
  param($Candidates, $Include, $Exclude, [string]$Unit)
  $hits = New-Object System.Collections.ArrayList
  $demoted = New-Object System.Collections.ArrayList
  foreach ($c in @($Candidates)) {
    if ($null -eq $c) { continue }
    $name = [string]$c.name; if (-not $name) { continue }
    $okInc = $false; foreach ($p in $Include) { if ($name -imatch $p) { $okInc = $true; break } }
    if (-not $okInc) { continue }
    $bad = $false; foreach ($p in $Exclude) { if ($p -and $name -imatch $p) { $bad = $true; break } }
    if ($bad) { continue }
    $slugWord = ''
    $slug = Get-SlugWords ([string]$c.url)
    if ($slug) {
      $both = $name + ' ' + $slug
      foreach ($p in $Exclude) {
        if (-not $p) { continue }
        $sm = [regex]::Match($both, [string]$p, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($sm.Success) { $slugWord = $sm.Value; break }
      }
    }
    if ($slugWord) { [void]$demoted.Add(("demoted '" + $name + "': slug '" + $slug + "' says '" + $slugWord + "'")) }
    [void]$hits.Add([pscustomobject]@{ C = $c; SlugKilled = [bool]$slugWord })
  }
  if (-not $hits.Count) { return @{ best = $null; demoted = $demoted } }
  $fam = UnitFamily $Unit
  $scored = foreach ($h in $hits) {
    $sc = PerUnit $h.C $fam
    $abs = AbsPrice $h.C
    [pscustomobject]@{
      C     = $h.C
      Rank  = $(if ($abs -le 0) { 3 } elseif ($h.SlugKilled) { 2 } elseif ($null -eq $sc) { 1 } else { 0 })
      Sub   = $(if ($null -eq $sc) { 1 } else { 0 })
      Score = $(if ($null -eq $sc) { $abs } else { $sc })
      Len   = ([string]$h.C.name).Length      # tie-break: the shorter name is the plainer base item
    }
  }
  $best = ($scored | Sort-Object Rank, Sub, Score, Len | Select-Object -First 1).C
  return @{ best = $best; demoted = $demoted }
}

if ($SelfTest) {
  $script:stFail = 0
  function T($label, $cond, $got) { if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '  got: ' + $got); $script:stFail++ } }
  # FROZEN, never regenerated from a live capture: out\fareway\fareway-shop-2026-09-10.jsonl, term 'whole
  # coconut' (commodity coconut, unit each) - the two candidates that decided the 2026-09-10 cell. The exclude
  # slice carries the word that matters, '\bbars?\b', beside neighbours from commodities.json index 479.
  $cocoInc = @('whole\s+coconuts?\b', 'young\s+coconuts?\b', 'coconuts?\b')
  $cocoExc = @('\bmilk\b', '\bwater\b', '\boil\b', 'granola', '\bbars?\b', 'cookies?')
  $kindBar = [pscustomobject]@{ id = '20002358'; term = 'whole coconut'; name = 'KIND Almond & Coconut'; price = '7.98'; per = ''; orig = '8.97'; unit = ''; size = '6 x 1.4 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/20002358-kind-bars-almond-coconut-6-ea' }
  $coconut = [pscustomobject]@{ id = '3402271'; term = 'whole coconut'; name = 'Coconut'; price = '3.99'; per = ''; orig = ''; unit = ''; size = '1 each'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/3402271-coconut-each' }
  $s1 = Select-ShopCandidate -Candidates @($kindBar, $coconut) -Include $cocoInc -Exclude $cocoExc -Unit 'each'
  T 'MUST FIRE  whole coconut selects the real Coconut at 3.99, not the KIND bar whose display name hid the word bars' ([string]$s1.best.name -eq 'Coconut') ([string]$s1.best.name)
  T 'MUST FIRE  ...and the demotion is logged with the word the slug said' ((@($s1.demoted).Count -eq 1) -and ([string]@($s1.demoted)[0] -match 'bars')) (@($s1.demoted) -join ' | ')
  # THE FOUNDING BUG IS STILL REACHABLE on the same frozen rows: the name alone passes coconut's excludes and the
  # bar is the cheaper per-unit score (7.98 / 6 = 1.33 against 3.99), which is exactly what the old ranking crowned.
  T 'MUST FIRE  the name alone passes the excludes and the bar scores cheaper per each (the pre-fix choice)' `
    (((PerUnit $kindBar 'count') -lt (PerUnit $coconut 'count')) -and -not ('KIND Almond & Coconut' -imatch '\bbars?\b')) ('' + (PerUnit $kindBar 'count') + ' vs ' + (PerUnit $coconut 'count'))
  # DEMOTE, NEVER DELETE. Real row from fareway-shop-2026-09-06.jsonl: 'uncooked' in the slug trips chicken-breast's
  # exclude 'cooked' - one of the two measured false kills - and as the only candidate it must still be selected.
  $tyson = [pscustomobject]@{ id = '1523117'; term = 'boneless skinless chicken breast'; name = 'Tyson Boneless Skinless Chicken Breasts, 2.5 lb. (Frozen)'; price = '9.99'; per = ''; orig = ''; unit = ''; size = '1.13 kg'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/1523117-tyson-chicken-breast-boneless-skinless-thin-sliced-uncooked-2-5-lb' }
  $s2 = Select-ShopCandidate -Candidates @($tyson) -Include @('\bchicken\s+breasts?\b') -Exclude @('cooked', 'breaded') -Unit 'lb'
  T 'CLEAN TWIN  a slug-demoted row that is the ONLY name-matching candidate is still selected' ([string]$s2.best.name -eq [string]$tyson.name) ([string]$s2.best.name)
  # Two clean candidates: the cheaper per unit still wins, exactly as before this change.
  $young = [pscustomobject]@{ id = '999'; term = 'whole coconut'; name = 'Young Coconut'; price = '2.99'; per = ''; orig = ''; unit = ''; size = '1 each'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/999-young-coconut-each' }
  $s3 = Select-ShopCandidate -Candidates @($coconut, $young) -Include $cocoInc -Exclude $cocoExc -Unit 'each'
  T 'CLEAN TWIN  with two clean candidates the cheaper per unit still wins (Young Coconut 2.99 over Coconut 3.99)' ([string]$s3.best.name -eq 'Young Coconut') ([string]$s3.best.name)
  T 'MUST NOT FIRE  ...and a clean slug demotes neither of them' (@($s3.demoted).Count -eq 0) (@($s3.demoted) -join ' | ')
  $noUrl = [pscustomobject]@{ id = '1'; name = 'Coconut'; price = '3.99'; size = '1 each'; url = '' }
  $s4 = Select-ShopCandidate -Candidates @($noUrl) -Include $cocoInc -Exclude $cocoExc -Unit 'each'
  T 'MUST NOT FIRE  a candidate with no url is scored on its name alone and never demoted' (([string]$s4.best.name -eq 'Coconut') -and (@($s4.demoted).Count -eq 0)) ('' + @($s4.demoted).Count)
  T 'CLEAN TWIN  the slug words are the last path segment, query dropped, id stripped' ((Get-SlugWords 'https://shop.fareway.com/store/fareway-meat-grocery/products/20002358-kind-bars-almond-coconut-6-ea?x=1') -eq 'kind bars almond coconut 6 ea') (Get-SlugWords 'https://shop.fareway.com/store/fareway-meat-grocery/products/20002358-kind-bars-almond-coconut-6-ea?x=1')
  if ($script:stFail) { Write-Output ('select-fareway-shop SELF-TEST FAIL (' + $script:stFail + ' of 8)'); exit 1 }
  Write-Output 'select-fareway-shop SELF-TEST PASS (8 of 8: slug demotion, demotion logged, founding bug reachable, demote-not-delete, cheapest wins, clean slugs demote nothing, no-url, slug parse)'
  exit 0
}

$commod = Read-JsonFile (Join-Path $root 'commodities.json')
$incMap = @{}; $excMap = @{}; $unitMap = @{}
foreach ($c in $commod) {
  $incMap[[string]$c.id] = @($c.include)
  $excMap[[string]$c.id] = @($c.exclude)
  $unitMap[[string]$c.id] = [string]$c.unit
}

# read JSONL: each line = {id, term, candidates:[{name,price,per,orig,unit,size,url}]}
$rows = @()
if (-not (Test-Path $In)) { throw "input not found: $In" }
foreach ($line in (Get-Content $In)) {
  $line = $line.Trim(); if (-not $line) { continue }
  try { $rows += (ConvertFrom-Json $line) } catch { Write-Warning "bad JSONL line skipped" }
}
# dedupe by id: last capture wins
$byIdRaw = [ordered]@{}
foreach ($r in $rows) { $byIdRaw[[string]$r.id] = $r }

$outRows = New-Object System.Collections.ArrayList
$dropped = @()
$demotedTotal = 0
foreach ($id in $byIdRaw.Keys) {
  if (-not $incMap.ContainsKey($id)) { continue }
  $sel = Select-ShopCandidate -Candidates $byIdRaw[$id].candidates -Include $incMap[$id] -Exclude $excMap[$id] -Unit $unitMap[$id]
  foreach ($dl in @($sel.demoted)) { Write-Output ('  [' + $id + '] ' + $dl); $demotedTotal++ }
  if ($null -eq $sel.best) { $dropped += $id; continue }
  $best = $sel.best
  [void]$outRows.Add([ordered]@{
    id=$id; name=[string]$best.name; price=[string]$best.price; per=[string]$best.per;
    orig=[string]$best.orig; unit=[string]$best.unit; size=[string]$best.size; url=[string]$best.url;
    term=[string]$byIdRaw[$id].term; taxonomy_path=[string]$best.taxonomy_path
  })
}
$outDir = Split-Path $Out -Parent; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
($outRows | ConvertTo-Json -Depth 5) | Set-Content $Out -Encoding UTF8
Write-Output ("fareway-shop-$asof.json: $($outRows.Count) commodities selected (from $($byIdRaw.Count) captured); $($dropped.Count) had no include-match; $demotedTotal candidate(s) slug-demoted")
if ($dropped.Count) { Write-Output ("  no-match ids: " + ($dropped -join ', ')) }
