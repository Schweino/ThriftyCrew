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

  THE STORE EVERY CANDIDATE WAS READ AT IS RULED ON HERE (2026-09-18, backlog I124). Fareway's store is Instacart
  SESSION state and a fresh session sits plausibly on Des Moines. farewayShopExtract stamps each candidate with the
  retailerLocation its page's cache named (`loc`), and this is the one place that stamp is judged, BEFORE a row is
  selected. The capture is REFUSED, and no shop file is written, when it has: no stamp at all (it predates the stamp;
  -WaiveMissingStoreStamp re-reads such a capture and records the store as UNRECORDED), a candidate with no stamp
  beside stamped ones, loc="UNRECORDED", two stores, or any store but stores.json -> Fareway -> store_identity. The
  store IS pinned, unlike Aldi's and Sam's: pull-fareway-instore.js has refused anything but 531573 since before this
  file existed. Every selected row carries `store_loc`, which build-fareway-regular writes as `store_location`.

    .\select-fareway-shop.ps1 -In <capture.jsonl> -Today 2026-09-10
    .\select-fareway-shop.ps1 -SelfTest          frozen coconut fixture + clean twins, no data read
#>
# The self-test reads stores.json and (as text) the instore driver, and runs this script over a temp capture, which reads commodities.json and stores.json:
# gate-inputs: lib\json-io.ps1, grocery\native-lib.ps1, grocery\commodities.json, grocery\stores.json
# gate-inputs-text: grocery\pull-fareway-instore.js
param(
  [string]$In = "",
  [string]$Out = "",
  [string]$Today = "",
  # For RE-SELECTING a capture written before farewayShopExtract stamped `loc` (2026-09-18), and nothing else. It
  # waives the no-stamp refusal only, when NO candidate carries a stamp: a stamp that is present and wrong (another
  # store, UNRECORDED, two stores, a stamped/unstamped mix) is refused exactly as without it. Its rows say
  # store_loc "UNRECORDED", never a store. capture-run never passes it.
  [switch]$WaiveMissingStoreStamp,
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

# ---- A SIZE ITS OWN LINK CONTRADICTS IS REFUSED (2026-09-19, design\PLAN-board-accuracy-2026-09-19.md 4f) ---------
# FOUNDING BUG: 'Softsoap Liquid Hand Soap Pump, Fresh Breeze' at $1.99 carried size "221 fl oz" in four captures
# (2026-08-25 to 09-01) while its own link says .../17105464-softsoap-hand-soap-fresh-breeze-7-5-oz. Scored at
# $0.009/fl oz it won hand-soap outright, the engine refused it as out of band, and a stale Dial row took the cell
# on the 2026-09-17 board. The storefront's size line was wrong and the slug was right.
# THE SLUG IS NOISY TOO, so the test is built to fire only on a contradiction no honest reading explains:
#   * slug readings: the trailing "<a>-<b>-<unit>" reads a.b AND b ("7-5-oz" is 7.5; "no-87-1-lb" is a pasta cut
#     number then 1 lb); a bare "<a>-<unit>" reads a, a/10 and a/100, because slugs drop the decimal point
#     ("108-fl-oz" is 10.8, "823-oz" is 8.23). Only oz / fl oz / fz / lb, in ounces; counts are never compared.
#   * size readings: the total, and the per-item size of an "N x M" pack.
#   * AGREE when any pair is within SLUG_SIZE_TOLERANCE of each other, or when the PRIMARY slug reading (a.b, or a)
#     and a size reading are a whole multiple k of each other (2..64, within 1%): a slug that names one cup of a
#     4-cup pack ("snack-pack-... -3-25-oz" beside "13 oz") is describing the item, not contradicting the pack.
#     The multiple test is on the primary reading only: with the loose readings too, 221 / 5 = 44.2 read as a pack
#     and the founding row passed, which is how the first cut of this rule was caught (measured, not guessed).
# SLUG_SIZE_TOLERANCE = 1.5, and what else was tried, over every distinct candidate in grocery\out\fareway\
# fareway-shop-*.jsonl on 2026-09-19 that carries both a weight/volume size and a slug quantity (5,231):
#   1.25 -> 30 refused,  1.5 -> 18 refused,  2.0 -> 13 refused.  The founding row is refused at all three.
# 1.5 because the legitimate disagreements the measurement listed are reformulations the slug never caught up with,
# and they reach exactly 1.5 (Fareway Gouda slices 8 oz against a 12-oz slug; Fareway bratwurst 12 against 18),
# while above it the list is dominated by rows whose size or link is plainly wrong (402 oz of buffalo sauce whose
# link says 13.6 oz; a cocoa mix whose link is a lip colour). A refused candidate costs that candidate only: the
# next qualifying one is considered, and only a commodity whose EVERY candidate is refused loses its cell - which
# is a gap, never a wrong number.
$script:SLUG_SIZE_TOLERANCE = 1.5

function Get-SlugSizeReadings([string]$url) {
  if (-not $url) { return @() }
  $tail = (@((($url -replace '[?#].*$', '') -replace '/+$', '') -split '/')[-1]).ToLower()
  $m = [regex]::Match($tail, '(?:^|-)(\d+)(?:-(\d+))?-(fl-oz|fz|floz|oz|lb|lbs)$')
  if (-not $m.Success) { return @() }
  $a = $m.Groups[1].Value; $b = $m.Groups[2].Value
  $mult = 1.0; if ($m.Groups[3].Value -match '^lbs?$') { $mult = 16.0 }
  $out = @()
  if ($b) { $out += ([double]("$a.$b") * $mult); $out += ([double]$b * $mult) }   # primary first
  else {
    $out += ([double]$a * $mult)
    if ($a.Length -ge 2) { $out += (([double]$a / 10) * $mult); $out += (([double]$a / 100) * $mult) }
  }
  return @($out | Where-Object { $_ -gt 0 })
}

function Get-ShopSizeReadings([string]$sz) {
  $s = ([string]$sz).ToLower().Trim() -replace '^about\s+', ''
  $m = [regex]::Match($s, '^(?:(\d+(?:\.\d+)?)\s*x\s*)?(\d+(?:\.\d+)?)\s*(fl oz|oz|lb|lbs|pounds?)$')
  if (-not $m.Success) { return @() }
  $n = 1.0; if ($m.Groups[1].Value) { $n = [double]$m.Groups[1].Value }
  $each = [double]$m.Groups[2].Value
  if ($m.Groups[3].Value -match '^(lb|lbs|pounds?)$') { $each = $each * 16 }
  if ($each -le 0 -or $n -le 0) { return @() }
  # Parenthesised: in @($n * $each, $each) the comma binds first and multiplies an array (ops-and-gates.md).
  if ($n -ne 1) { return @(($n * $each), $each) }
  return @($each)
}

# Returns @{ contradicts = [bool]; detail = text }. No reading on either side is never a contradiction.
function Test-SlugSizeContradiction($c) {
  $S = @(Get-SlugSizeReadings ([string]$c.url))
  $Z = @(Get-ShopSizeReadings ([string]$c.size))
  if (-not $S.Count -or -not $Z.Count) { return @{ contradicts = $false; detail = '' } }
  for ($i = 0; $i -lt $S.Count; $i++) {
    foreach ($z in $Z) {
      $hi = [math]::Max($z, $S[$i]); $lo = [math]::Min($z, $S[$i])
      if ($lo -le 0) { continue }
      $r = $hi / $lo
      if ($r -le $script:SLUG_SIZE_TOLERANCE) { return @{ contradicts = $false; detail = '' } }
      $k = [math]::Round($r)
      if ($i -eq 0 -and $k -ge 2 -and $k -le 64 -and ([math]::Abs($r - $k) / $k) -le 0.01) { return @{ contradicts = $false; detail = '' } }
    }
  }
  return @{ contradicts = $true
            detail = ("size '" + [string]$c.size + "' contradicts its own link, which states " + $S[0] + ' oz (' + (Get-SlugWords ([string]$c.url)) + ')') }
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
  $refused = New-Object System.Collections.ArrayList
  foreach ($c in @($Candidates)) {
    if ($null -eq $c) { continue }
    $name = [string]$c.name; if (-not $name) { continue }
    $okInc = $false; foreach ($p in $Include) { if ($name -imatch $p) { $okInc = $true; break } }
    if (-not $okInc) { continue }
    $bad = $false; foreach ($p in $Exclude) { if ($p -and $name -imatch $p) { $bad = $true; break } }
    if ($bad) { continue }
    # REFUSED, not demoted: a size the link contradicts would be scored on a wrong quantity, so it may not win even
    # as the last candidate. The next name-matching candidate is considered instead (see the block above).
    $sc0 = Test-SlugSizeContradiction $c
    if ($sc0.contradicts) { [void]$refused.Add(("refused '" + $name + "': " + $sc0.detail)); continue }
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
  if (-not $hits.Count) { return @{ best = $null; demoted = $demoted; refused = $refused } }
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
  return @{ best = $best; demoted = $demoted; refused = $refused }
}

# ---- THE STORE A CAPTURE WAS READ AT (2026-09-18, backlog I124) - see the header ----------------------------------
# The sanctioned retailerLocation, from the registry. '' when stores.json names none, which Get-FarewayCaptureStore
# refuses: a store we cannot rule on is not a store we may assume.
function Get-FarewaySanctionedLocation([string]$Root) {
  $f = Join-Path $Root 'stores.json'
  if (-not (Test-Path -LiteralPath $f)) { return '' }
  $doc = Read-JsonFile $f
  foreach ($s in @($doc.stores)) {
    if ([string]::Equals([string]$s.name, 'Fareway', [StringComparison]::Ordinal) -and $s.store_identity) {
      return [string]$s.store_identity.retailer_location
    }
  }
  return ''
}

# Rules on every candidate's `loc` across a whole capture. $Lines are the parsed {id,term,candidates[]} objects.
# Returns @{ loc; total; refuse; nostamp } and prints nothing. ORDINAL throughout: this text came off a web page
# (ops-and-gates.md, -ne ignores NUL). The refusal text 'carries no store stamp' is what -WaiveMissingStoreStamp keys
# on, and the self-test pins it.
function Get-FarewayCaptureStore {
  param($Lines, [string]$Sanctioned)
  $total = 0; $unstamped = 0; $unrec = 0
  $distinct = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($ln in @($Lines)) {
    if ($null -eq $ln) { continue }
    foreach ($c in @($ln.candidates)) {
      if ($null -eq $c) { continue }
      $total++
      $l = if ($c.PSObject.Properties['loc']) { ([string]$c.loc).Trim() } else { '' }
      if (-not $l) { $unstamped++; continue }
      if ([string]::Equals($l, 'UNRECORDED', [StringComparison]::Ordinal)) { $unrec++; continue }
      [void]$distinct.Add($l)
    }
  }
  $why = ''
  $stamped = $total - $unstamped
  if ($total -eq 0) {
    $why = ''
  } elseif ($stamped -eq 0) {
    $why = ('the capture carries no store stamp on any of its ' + $total + ' candidate(s), so it cannot say which Fareway it read. Re-capture through farewayShopExtract in pull-fareway-shop.js, which stamps every row with loc; never strip it or hand-assemble the file.')
  } elseif ($unstamped -gt 0) {
    $why = ('{0} of {1} candidate(s) carry no store stamp beside stamped ones - rows from another capture were merged in, and they cannot be attributed to any store.' -f $unstamped, $total)
  } elseif ($unrec -gt 0) {
    $why = ('{0} of {1} candidate(s) were read on a page whose cache named no retailerLocation (loc="UNRECORDED"), so they cannot be attributed to any store.' -f $unrec, $total)
  } elseif ($distinct.Count -gt 1) {
    $why = ('the sweep straddles {0} stores (retailerLocation {1}) - the session moved mid-sweep, and one file names one store.' -f $distinct.Count, ((@($distinct) | Sort-Object) -join ', '))
  } elseif (-not $Sanctioned) {
    $why = 'stores.json names no Fareway store_identity.retailer_location, so there is nothing to rule this capture against.'
  } elseif (-not [string]::Equals(@($distinct)[0], $Sanctioned, [StringComparison]::Ordinal)) {
    $why = ('retailerLocation {0} is not the sanctioned Fareway {1} (stores.json). 513473 is Des Moines - Euclid, the plausible store a fresh session defaults to.' -f @($distinct)[0], $Sanctioned)
  }
  $loc = ''
  if (-not $why -and $distinct.Count -eq 1) { $loc = @($distinct)[0] }
  return @{ loc = $loc; total = $total; refuse = $why; nostamp = ($total -gt 0 -and $stamped -eq 0) }
}

# ---- THE SELECTED ROW, as a pure function so -SelfTest drives the code the main loop runs --------------------------
# THE STORE'S OWN SALE COUNTDOWN RIDES THE ROW (2026-09-18, backlog I223). farewayShopExtract reads "Sale ends in N
# days" out of the page's Apollo cache and emits it as sale_ends_days (the integer) and sale_note (the text), and
# build-fareway-regular carries both onto the priced row so compare-deals can date the sale from the store's own
# answer. This row was built from a fixed field list that named neither, so both were dropped HERE, between the
# capture and the builder: on the 2026-09-11 capture 143 of 2,392 candidates carried a sale end and 0 of the 44
# selected rows kept one, so the builder's countdown branch could never fire on a daily capture.
# Copied only when the candidate carries the field, so a candidate without one yields exactly the row it always did.
# The value is passed through as captured; build-fareway-regular is the one place that parses and bounds it.
function ConvertTo-ShopRow {
  param($Id, $Best, [string]$Term, [string]$StoreLoc)
  $row = [ordered]@{
    id=$Id; name=[string]$Best.name; price=[string]$Best.price; per=[string]$Best.per;
    orig=[string]$Best.orig; unit=[string]$Best.unit; size=[string]$Best.size; url=[string]$Best.url;
    term=$Term; taxonomy_path=[string]$Best.taxonomy_path;
    store_loc=$StoreLoc
  }
  if ($Best.PSObject.Properties['sale_ends_days'] -and $null -ne $Best.sale_ends_days -and "$($Best.sale_ends_days)" -ne '') { $row['sale_ends_days'] = $Best.sale_ends_days }
  if ($Best.PSObject.Properties['sale_note'] -and "$($Best.sale_note)" -ne '') { $row['sale_note'] = [string]$Best.sale_note }
  return $row
}

if ($SelfTest) {
  $script:stFail = 0
  $script:stRan = 0
  function T($label, $cond, $got) { $script:stRan++; if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '  got: ' + $got); $script:stFail++ } }
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
  # ---- THE SALE COUNTDOWN RIDES THE SELECTED ROW (2026-09-18, backlog I223) -----------------------------------------
  # FROZEN, never regenerated: the first line of out\fareway\fareway-shop-2026-09-11.jsonl, term 'cod fillets', one of
  # the 143 of 2,392 candidates that day carrying the store's countdown. The row built from it lost both fields.
  $cod = [pscustomobject]@{ id = '84386690'; term = 'cod fillets'; name = 'Fresh Cod Fillets'; price = '8.74'; per = 'each'; orig = '11.37'; unit = '$9.99 / lb'; size = ''; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/84386690-fresh-cod-fillets-1-each'; sale_ends_days = 1; sale_note = 'Sale ends in 1 day' }
  $codRow = ConvertTo-ShopRow -Id 'cod' -Best $cod -Term 'cod fillets' -StoreLoc '531573'
  T 'MUST FIRE  a selected candidate with a sale end keeps sale_ends_days 1 and its sale_note on the shop row' (($codRow.Contains('sale_ends_days')) -and ([string]$codRow['sale_ends_days'] -eq '1') -and ([string]$codRow['sale_note'] -eq 'Sale ends in 1 day') -and ([string]$codRow['price'] -eq '8.74')) ($codRow | ConvertTo-Json -Compress)
  # The pre-I223 row, key for key: a candidate that carries no countdown must come out exactly as it always did.
  $preKeys = 'id,name,price,per,orig,unit,size,url,term,taxonomy_path,store_loc'
  $cocoRow = ConvertTo-ShopRow -Id 'coconut' -Best $coconut -Term 'whole coconut' -StoreLoc '531573'
  T 'CLEAN TWIN  a candidate without a sale end yields the pre-fix row: the same eleven keys in order, price 3.99' ((@($cocoRow.Keys) -join ',') -eq $preKeys -and [string]$cocoRow['price'] -eq '3.99' -and [string]$cocoRow['store_loc'] -eq '531573') (@($cocoRow.Keys) -join ',')
  # ---- A SIZE ITS OWN LINK CONTRADICTS (2026-09-19, PLAN-board-accuracy 4f) ------------------------------------------
  # FROZEN, never regenerated: out\fareway\fareway-shop-2026-09-01.jsonl, term 'liquid hand soap' (commodity hand-soap,
  # unit floz), the founding row and two of its real neighbours. Include/exclude are hand-soap's in commodities.json.
  $hsInc = @('hands?\s+soap', 'hand\s+wash\b')
  $hsExc = @('sanitizer', '\bdish\b', '\bbar\b', 'dispenser', '\bbody\b')
  $ss221 = [pscustomobject]@{ id = '17105464'; term = 'liquid hand soap'; name = 'Softsoap Liquid Hand Soap Pump, Fresh Breeze'; price = '1.99'; per = ''; orig = '2.99'; unit = ''; size = '221 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/17105464-softsoap-hand-soap-fresh-breeze-7-5-oz' }
  $ssAloe = [pscustomobject]@{ id = '81826'; term = 'liquid hand soap'; name = 'Softsoap Liquid Hand Soap Pump, Aloe Vera Fresh'; price = '1.99'; per = ''; orig = ''; unit = ''; size = '7.5 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/81826-softsoap-hand-soap-moisturizing-soothing-clean-aloe-vera-fresh-scent-7-5-fl-oz' }
  $ssRefill = [pscustomobject]@{ id = '19613282'; term = 'liquid hand soap'; name = 'Softsoap Aquarium Liquid Hand Soap Refill'; price = '5.97'; per = ''; orig = ''; unit = ''; size = '50 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/19613282-softsoap-aquarium-liquid-hand-soap-refill-50-fl-oz' }
  $s5 = Select-ShopCandidate -Candidates @($ss221, $ssAloe, $ssRefill) -Include $hsInc -Exclude $hsExc -Unit 'floz'
  T 'MUST FIRE  hand-soap does not select the Fresh Breeze pump whose size 221 fl oz contradicts its 7.5-oz link; the next qualifying row (the 50 fl oz refill) wins' ([string]$s5.best.id -eq '19613282') ([string]$s5.best.name + ' / ' + [string]$s5.best.size)
  T 'MUST FIRE  ...and the refusal is logged once, naming the 7.5 the link states' ((@($s5.refused).Count -eq 1) -and ([string]@($s5.refused)[0] -match 'Fresh Breeze') -and ([string]@($s5.refused)[0] -match '7\.5 oz')) (@($s5.refused) -join ' | ')
  T 'MUST FIRE  the founding bug is reachable on these rows: at 221 fl oz the pump scores cheaper per fl oz than the refill' ((PerUnit $ss221 'volume') -lt (PerUnit $ssRefill 'volume')) ('' + (PerUnit $ss221 'volume') + ' vs ' + (PerUnit $ssRefill 'volume'))
  T 'MUST NOT FIRE  a 7.5 fl oz pump whose link says 7-5-fl-oz is not refused' (-not (Test-SlugSizeContradiction $ssAloe).contradicts) ((Test-SlugSizeContradiction $ssAloe).detail)
  # MUST NOT FIRE - the three honest slug shapes a naive comparison refuses. Each is a real candidate from the captures.
  $slDrop = [pscustomobject]@{ size = '10.8 fl oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/27081907-bright-essentials-hand-soap-fresh-lemon-scent-108-fl-oz' }
  T 'MUST NOT FIRE  a slug that dropped the decimal point (108-fl-oz beside 10.8 fl oz) still agrees' (-not (Test-SlugSizeContradiction $slDrop).contradicts) ((Test-SlugSizeContradiction $slDrop).detail)
  $slCup = [pscustomobject]@{ size = '13 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/43460-snack-pack-pudding-sugar-free-vanilla-3-25-oz' }
  T 'MUST NOT FIRE  a slug naming one cup of a 4-cup pack (3-25-oz beside 13 oz, an exact multiple) still agrees' (-not (Test-SlugSizeContradiction $slCup).contradicts) ((Test-SlugSizeContradiction $slCup).detail)
  $slCut = [pscustomobject]@{ size = '1 lb'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/19040859-rummo-orecchiette-no-87-1-lb' }
  T 'MUST NOT FIRE  a pasta cut number before the size (no-87-1-lb beside 1 lb) still agrees' (-not (Test-SlugSizeContradiction $slCut).contradicts) ((Test-SlugSizeContradiction $slCut).detail)
  # AT THE BAR (ratio exactly SLUG_SIZE_TOLERANCE 1.5) and ONE STEP PAST IT (0.1 oz, the size line's resolution).
  $slAt = [pscustomobject]@{ size = '15 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/1-some-sauce-10-oz' }
  $slPast = [pscustomobject]@{ size = '15.1 oz'; url = 'https://shop.fareway.com/store/fareway-meat-grocery/products/1-some-sauce-10-oz' }
  T 'MUST NOT FIRE at the bar  15 oz beside a 10-oz link (ratio 1.5 = SLUG_SIZE_TOLERANCE) agrees' (-not (Test-SlugSizeContradiction $slAt).contradicts) ((Test-SlugSizeContradiction $slAt).detail)
  T 'MUST FIRE one step past the bar  15.1 oz beside a 10-oz link (ratio 1.51) is refused' ((Test-SlugSizeContradiction $slPast).contradicts) ('contradicts=' + (Test-SlugSizeContradiction $slPast).contradicts)
  # REFUSED, NOT DEMOTED: when the contradicted row is the only candidate, the commodity selects nothing (a gap).
  $s6 = Select-ShopCandidate -Candidates @($ss221) -Include $hsInc -Exclude $hsExc -Unit 'floz'
  T 'MUST FIRE  a contradicted row that is the ONLY candidate is not selected - the cell is withheld, never priced on 221 fl oz' ($null -eq $s6.best -and @($s6.refused).Count -eq 1) ('best=' + [string]$s6.best.name)
  # ---- THE STORE A CAPTURE WAS READ AT (2026-09-18, backlog I124) -------------------------------------------------
  # The same two frozen coconut candidates, each carrying the loc farewayShopExtract now stamps. The founding shape
  # is a capture read on the plausible wrong store: a fresh session sits on Des Moines (513473) and every price in it
  # is real, so nothing downstream could tell until this ruling existed.
  $stSan = '531573'
  function _FwLine($loc1, $loc2) {
    $a = $kindBar.PSObject.Copy(); $b = $coconut.PSObject.Copy()
    if ($null -ne $loc1) { $a | Add-Member -NotePropertyName loc -NotePropertyValue $loc1 -Force }
    if ($null -ne $loc2) { $b | Add-Member -NotePropertyName loc -NotePropertyValue $loc2 -Force }
    return [pscustomobject]@{ id = 'coconut'; term = 'whole coconut'; candidates = @($a, $b) }
  }
  $tblS = @(
    @{ l = 'MUST FIRE  a capture read at Des Moines 513473 is refused, and the refusal names both stores'; lines = @((_FwLine '513473' '513473')); want = 'retailerLocation 513473 is not the sanctioned Fareway 531573' },
    @{ l = 'MUST FIRE  a capture with NO stamp on any candidate is refused';                                lines = @((_FwLine $null $null)); want = 'carries no store stamp' },
    @{ l = 'MUST FIRE  loc="UNRECORDED" is refused, never folded into the store beside it';                 lines = @((_FwLine '531573' 'UNRECORDED')); want = 'loc="UNRECORDED"' },
    @{ l = 'MUST FIRE  a sweep whose session moved mid-sweep (two stores) is refused';                       lines = @((_FwLine '531573' '531573'), (_FwLine '513473' '513473')); want = 'straddles 2 stores' },
    @{ l = 'MUST FIRE  unstamped rows merged beside stamped ones are refused';                               lines = @((_FwLine '531573' $null)); want = 'carry no store stamp beside stamped ones' },
    @{ l = 'MUST FIRE  a registry with no Fareway store_identity cannot sanction anything';                  lines = @((_FwLine '531573' '531573')); want = 'names no Fareway store_identity'; san = '' }
  )
  foreach ($c in $tblS) {
    $san = if ($c.ContainsKey('san')) { $c.san } else { $stSan }
    $rs = Get-FarewayCaptureStore -Lines $c.lines -Sanctioned $san
    T $c.l ([bool]$rs.refuse -and $rs.refuse.Contains($c.want) -and -not $rs.loc) ('refuse=[' + $rs.refuse + '] loc=[' + $rs.loc + ']')
  }
  $empty = [pscustomobject]@{ id = 'kale'; term = 'kale'; candidates = @() }
  $rOk = Get-FarewayCaptureStore -Lines @((_FwLine '531573' '531573'), $empty) -Sanctioned $stSan
  T 'MUST NOT FIRE  every candidate read at 531573 (and a term with no candidates) is ruled 531573' ((-not $rOk.refuse) -and $rOk.loc -eq '531573' -and $rOk.total -eq 2) ('refuse=[' + $rOk.refuse + '] loc=' + $rOk.loc + ' total=' + $rOk.total)
  $rNo = Get-FarewayCaptureStore -Lines @((_FwLine $null $null)) -Sanctioned $stSan
  T '...and only the no-stamp-at-all shape is marked waivable' ($rNo.nostamp -and -not (Get-FarewayCaptureStore -Lines @((_FwLine '531573' $null)) -Sanctioned $stSan).nostamp) ('nostamp=' + $rNo.nostamp)
  # THE MIRROR. farewayIdentity() cannot read stores.json from a browser console, so it carries the id as a literal;
  # the two must name one store or the driver and this ruling disagree about what "Omaha" is.
  $regLoc = Get-FarewaySanctionedLocation $root
  $instSrc = [IO.File]::ReadAllText((Join-Path $root 'pull-fareway-instore.js'))
  $mirM = [regex]::Match($instSrc, "if \(loc !== '(\d+)'\)")
  T 'CLEAN TWIN  stores.json''s Fareway retailer_location equals farewayIdentity()''s literal' ($regLoc -and $mirM.Success -and [string]::Equals($regLoc, $mirM.Groups[1].Value, [StringComparison]::Ordinal)) ('stores.json=' + $regLoc + ' js=' + $(if ($mirM.Success) { $mirM.Groups[1].Value } else { '<no literal found>' }))

  # END TO END, through this script as a child over a frozen capture in a per-run temp directory: the path capture-run
  # takes. commodities.json and stores.json are READ from the checkout; nothing under out\ is touched.
  . (Join-Path $root 'native-lib.ps1')
  $stT = Join-Path $env:TEMP ('sfs-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $stT -Force -ErrorAction Stop | Out-Null
  try {
    $selfP = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $root 'select-fareway-shop.ps1' }
    function _FwRun([string]$name, $line, [string[]]$extra) {
      $inP = Join-Path $stT ($name + '.jsonl'); $outP = Join-Path $stT ($name + '.json')
      [IO.File]::WriteAllText($inP, (($line | ConvertTo-Json -Depth 6 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
      $argv = @('-In', $inP, '-Out', $outP, '-Today', '1999-01-01') + @($extra)
      $run = Invoke-NativeScript $selfP @argv
      $doc = $null
      if (Test-Path -LiteralPath $outP) { $doc = @(Get-Content -LiteralPath $outP -Raw -Encoding UTF8 | ConvertFrom-Json) }
      return @{ rc = $run.ExitCode; lines = @($run.Lines | ForEach-Object { [string]$_ }); doc = $doc }
    }
    $e1 = _FwRun 'ok' (_FwLine '531573' '531573') @()
    $e1Row = if ($e1.doc) { @($e1.doc)[0] } else { $null }
    T 'CLEAN TWIN  a capture read at 531573 still selects the real Coconut at 3.99 and every row says store_loc 531573' ($e1.rc -eq 0 -and $e1Row -and [string]$e1Row.name -eq 'Coconut' -and [string]$e1Row.price -eq '3.99' -and [string]$e1Row.store_loc -eq '531573') ('rc=' + $e1.rc + ' row=' + ($e1Row | ConvertTo-Json -Compress) + ' | ' + ($e1.lines -join ' / '))
    $e2 = _FwRun 'dsm' (_FwLine '513473' '513473') @()
    T 'MUST FIRE  the Des Moines capture exits 1 with a REFUSED line and writes NO shop file' ($e2.rc -eq 1 -and $null -eq $e2.doc -and (@($e2.lines | Where-Object { $_ -like 'REFUSED:*513473*' }).Count -eq 1)) ('rc=' + $e2.rc + ' doc=' + [bool]$e2.doc + ' | ' + ($e2.lines -join ' / '))
    $e3 = _FwRun 'old' (_FwLine $null $null) @()
    T 'MUST FIRE  an unstamped capture exits 1 and writes nothing' ($e3.rc -eq 1 -and $null -eq $e3.doc) ('rc=' + $e3.rc + ' | ' + ($e3.lines -join ' / '))
    $e4 = _FwRun 'waived' (_FwLine $null $null) @('-WaiveMissingStoreStamp')
    $e4Row = if ($e4.doc) { @($e4.doc)[0] } else { $null }
    T 'CLEAN TWIN  -WaiveMissingStoreStamp re-selects an old capture and says store_loc UNRECORDED, never a store' ($e4.rc -eq 0 -and $e4Row -and [string]$e4Row.store_loc -eq 'UNRECORDED' -and [string]$e4Row.price -eq '3.99') ('rc=' + $e4.rc + ' row=' + ($e4Row | ConvertTo-Json -Compress) + ' | ' + ($e4.lines -join ' / '))
    $e5 = _FwRun 'waivewrong' (_FwLine '513473' '513473') @('-WaiveMissingStoreStamp')
    T 'MUST FIRE  the waiver does not waive a WRONG store' ($e5.rc -eq 1 -and $null -eq $e5.doc) ('rc=' + $e5.rc + ' | ' + ($e5.lines -join ' / '))
    # The same frozen coconut capture with the countdown the cod row carried, through the whole script: the path
    # capture-run takes, and the one the fixed field list broke.
    $saleLine = _FwLine '531573' '531573'
    $saleLine.candidates[1] | Add-Member -NotePropertyName sale_ends_days -NotePropertyValue 1 -Force
    $saleLine.candidates[1] | Add-Member -NotePropertyName sale_note -NotePropertyValue 'Sale ends in 1 day' -Force
    $e6 = _FwRun 'sale' $saleLine @()
    $e6Row = if ($e6.doc) { @($e6.doc)[0] } else { $null }
    T 'MUST FIRE  end to end, the selected Coconut keeps sale_ends_days 1 and its sale_note in the shop file' ($e6.rc -eq 0 -and $e6Row -and [string]$e6Row.name -eq 'Coconut' -and [string]$e6Row.sale_ends_days -eq '1' -and [string]$e6Row.sale_note -eq 'Sale ends in 1 day') ('rc=' + $e6.rc + ' row=' + ($e6Row | ConvertTo-Json -Compress) + ' | ' + ($e6.lines -join ' / '))
  } finally { Remove-Item -LiteralPath $stT -Recurse -Force -ErrorAction SilentlyContinue }

  $stTotal = 8 + 2 + 10 + $tblS.Count + 3 + 6
  if ($script:stRan -ne $stTotal) { Write-Output ('FAIL  the suite ran ' + $script:stRan + ' case(s), not the ' + $stTotal + ' it lists'); $script:stFail++ }
  if ($script:stFail) { Write-Output ('select-fareway-shop SELF-TEST FAIL (' + $script:stFail + ' of ' + $stTotal + ')'); exit 1 }
  Write-Output ('select-fareway-shop SELF-TEST PASS (' + $stTotal + ' of ' + $stTotal + ': slug demotion, demotion logged, founding bug reachable, demote-not-delete, cheapest wins, clean slugs demote nothing, no-url, slug parse, sale countdown kept x2, size contradicts its link x10, store ruling x' + ($tblS.Count + 3) + ', end to end x6)')
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
# THE STORE FIRST, before a single row is selected (see the header). A refusal writes nothing, so yesterday's shop
# files keep pricing and the day's capture is repeated rather than published in an unknown basis.
$fwSanctioned = Get-FarewaySanctionedLocation $root
$fwStore = Get-FarewayCaptureStore -Lines $rows -Sanctioned $fwSanctioned
$fwWaived = [bool]($WaiveMissingStoreStamp -and $fwStore.nostamp)
if ($fwStore.refuse -and -not $fwWaived) {
  Write-Output ('REFUSED: ' + (Split-Path $In -Leaf) + ' - ' + $fwStore.refuse + ' No shop file was written.')
  exit 1
}
$storeLoc = if ($fwWaived) { 'UNRECORDED' } else { [string]$fwStore.loc }
if ($fwWaived) { Write-Output ('store: NOT RECORDED - ' + $fwStore.total + ' candidate(s) predate the loc stamp; selected under -WaiveMissingStoreStamp, so every row says store_loc UNRECORDED') }
elseif ($storeLoc) { Write-Output ('store: retailerLocation ' + $storeLoc + ' read on all ' + $fwStore.total + ' candidate(s)') }

# dedupe by id: last capture wins
$byIdRaw = [ordered]@{}
foreach ($r in $rows) { $byIdRaw[[string]$r.id] = $r }

$outRows = New-Object System.Collections.ArrayList
$dropped = @()
$demotedTotal = 0
$sizeRefusedTotal = 0
foreach ($id in $byIdRaw.Keys) {
  if (-not $incMap.ContainsKey($id)) { continue }
  $sel = Select-ShopCandidate -Candidates $byIdRaw[$id].candidates -Include $incMap[$id] -Exclude $excMap[$id] -Unit $unitMap[$id]
  foreach ($dl in @($sel.demoted)) { Write-Output ('  [' + $id + '] ' + $dl); $demotedTotal++ }
  foreach ($rl in @($sel.refused)) { Write-Output ('  [' + $id + '] SIZE-CONTRADICTS-LINK ' + $rl); $sizeRefusedTotal++ }
  if ($null -eq $sel.best) { $dropped += $id; continue }
  [void]$outRows.Add((ConvertTo-ShopRow -Id $id -Best $sel.best -Term ([string]$byIdRaw[$id].term) -StoreLoc $storeLoc))
}
$outDir = Split-Path $Out -Parent; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
($outRows | ConvertTo-Json -Depth 5) | Set-Content $Out -Encoding UTF8
Write-Output ("fareway-shop-$asof.json: $($outRows.Count) commodities selected (from $($byIdRaw.Count) captured); $($dropped.Count) had no include-match; $demotedTotal candidate(s) slug-demoted; $sizeRefusedTotal candidate(s) refused SIZE-CONTRADICTS-LINK")
if ($dropped.Count) { Write-Output ("  no-match ids: " + ($dropped -join ', ')) }
