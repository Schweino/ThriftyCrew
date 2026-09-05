<#
  audit-name-drift.ps1 - catches "right price, WRONG product" links that the price-only audit-links.ps1
  misses (e.g. board = fresh "Freshness Guaranteed" chicken breast $2.48/lb, but the link points at the
  frozen Great Value 8 lb bag at a similar per-lb price). The board records the EXACT product name it
  priced (comparison stores[].item); this flags any link whose stored product name shares NONE of that
  board item's distinctive (non-commodity) words. Output: printed review list + out\name-drift.json.
  Expect some false positives (equivalent product, different brand/word-order) - it is a REVIEW signal, not
  an auto-fix: eyeball each, and for a genuinely wrong product re-resolve it by the board item name.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$cmp  = (Get-ChildItem (Join-Path $out 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
# BOTH BOARDS. This read was comparison-*.json ONLY, and that is what made the WRONG-PRODUCT half of guards.ps1
# guard 3 structurally unfirable: generate-board-overrides pins across the staple AND the recipe board, every
# one of today's 16 pins is a recipe-board-only id, so guard 3's $pinDrift map could never hold a key matching
# any pin while the guard printed "ok ... 16 checked". MEASURED 2026-07-30: staple 492 rows / recipe 80 rows /
# 0 ids in common; the union adds 243 examinable cells (2,435 -> 2,678) and exactly 3 new flags, none of them
# on a pinned cell, so no pin, page tile or pruned link changes today. Recipe rows whose id ALSO exists on the
# staple board are dropped: the same id carries a different unit basis on the two boards and one link cannot be
# right for both - the same collision rule generate-board-overrides.ps1 applies before it pins anything.
$c    = @((Read-JsonFile $cmp.FullName).comparison)
$stapleIds = @{}; foreach ($sr in $c) { $stapleIds[[string]$sr.id] = $true }
$rbF  = Join-Path $out 'recipe-board.json'
if (Test-Path $rbF) {
  $c = @($c) + @(@((Read-JsonFile $rbF).comparison) | Where-Object { -not $stapleIds.ContainsKey([string]$_.id) })
}
$purls = (Read-JsonFile (Join-Path $root 'product-urls.json')).items
# commodity + generic words that appear in both names, so are NOT distinctive of the specific product
$stop = 'boneless|skinless|chicken|breast|breasts|thigh|thighs|drumstick|drumsticks|ground|beef|turkey|pork|bacon|fresh|frozen|large|whole|family|pack|natural|all|lean|value|brand|each|lb|lbs|oz|count|ct|bag|tray|organic|cage|free|grade|sweet|original|classic|the|and|with|for|from|our|certified|the|of|per|shredded|cheese|milk|eggs|butter|sour|cream|juice|orange|apple|apples|banana|bananas|potato|potatoes|russet|onion|onions|bread|coffee|sugar|brown|tomato|tomatoes|sauce|paste|beans|kidney|garbanzo|cannellini|olives|pineapple|chunks|strawberries|blueberries|grapes|avocado|avocados|watermelon|corn|cabbage|carrots|ginger|honey|mustard|dijon|vinegar|balsamic|white|red|wine|soy|hoisin|sesame|oil|tahini|paprika|curry|powder|cornstarch|starch|rotini|pasta|marinara|spinach|peas|green|hominy|tomatillos|cashews|peanut|maple|syrup|yogurt|greek|cottage|provolone|cheddar|colby|jack|mozzarella|fries|crumbs|loin|chop|chops|thick|cut|roll|spread|soft|low|fat|pint|package|bowl'
# ---------------------------------------------------------------- BRAND LEXICON (2026-08-21)
# THE TOLERATED MIDDLE. The token test below flags a link only when it shares NO distinctive word
# with the board item, and this script's own output says so ("some are just brand differences").
# That conservatism is load-bearing - generate-board-overrides refuses to pin any cell flagged here,
# so a false flag silently blocks a good pin - but it leaves a gap, and 188 priced tiles were sitting
# in it: Fareway pricing Classico alfredo behind a Ragu link, Hy-Vee pricing its own fudge cookies
# behind CHIPS AHOY, Aldi pricing Friendly Farms half-and-half behind a Barissimo coconut creamer.
# Each shares enough words to pass. Each opens a different manufacturer's product than the price
# describes, which is the invariant this whole audit exists for.
#
# What separates those from noise is BRAND, not word overlap. "Traditional Yellow Mustard" against
# "Yellow Mustard" is one product written two ways; "Classico" against "Ragu" is not. So the question
# is which tokens name a manufacturer - and that is answerable from the corpus rather than guessed:
# a brand almost always LEADS a product name, a descriptor floats anywhere in it. Measured over
# 33,628 names: kroger 0.98 lead, ragu 1.00, classico 0.96, libby 1.00, tyson 1.00 - against
# vanilla 0.15, honey 0.20, original 0.27, light 0.25. The gap is not marginal.
#
# Built inline every run from the newest capture per store, NOT cached. A cached input is how
# tile-integrity spent this morning grading today's links against yesterday's verdicts; a lexicon
# file would be the same mistake with a slower fuse.
$leadN = @{}; $totalN = @{}
$lexNames = New-Object System.Collections.Generic.HashSet[string]
$lexFiles = New-Object System.Collections.Generic.List[string]
foreach ($grp in @('out\regular\*-regular-*.json','out\sams\sams-deals-*.json','out\bakers\bakers-deals-*.json','out\fareway\fareway-deals-*.json')) {
  $byPrefix = @{}
  foreach ($f in (Get-ChildItem (Join-Path $root $grp) -ErrorAction SilentlyContinue)) {
    $p = ($f.BaseName -replace '-[^-]+$','')          # strip the trailing date -> one bucket per store feed
    if (-not $byPrefix.ContainsKey($p) -or $f.Name -gt $byPrefix[$p].Name) { $byPrefix[$p] = $f }
  }
  foreach ($f in $byPrefix.Values) { $lexFiles.Add($f.FullName) }
}
foreach ($lf in $lexFiles) {
  try { $d = Read-JsonFile $lf } catch { continue }
  $rows = if ($d -is [array]) { $d } elseif ($d.PSObject.Properties['deals']) { $d.deals } elseif ($d.PSObject.Properties['products']) { $d.products } else { @() }
  foreach ($r in $rows) { $n = if ($r.item) { [string]$r.item } elseif ($r.name) { [string]$r.name } else { '' }; if ($n) { [void]$lexNames.Add($n) } }
}
$SIZERE = '\b\d+(?:\.\d+)?\s*(?:fl\s*oz|oz|lb|lbs|ct|ea|pk|pack|count|g|kg|ml|l|qt|gal)s?\b'
# 'great' and 'value' are NOT noise, however generic they read. Walmart's house brand is Great
# Value and it leads 2,071 product names in this corpus - with both words filtered out, the single
# most common brand at the biggest store could never register a brand at all, so a board row naming
# Libby's behind a Great Value link went unflagged. Measured lead ratio with them restored:
# great 0.97, value 0.92 - comfortably brand-shaped. A rival brand whose name also contains 'value'
# SHARES the token and therefore does not flag, which is the safe direction to be wrong in.
$LEXNOISE = 'fresh|organic|natural|premium|size|large|small|bulk|each|approx|bag|bagged|package|packaged|pack|box|boxed|jar|jarred|can|canned|bottle|bottled|tub|carton|container|pouch|per|with|and|the|of|in|on|for|new|quality|select|brand|family'
function Sig-Tokens([string]$s) {
  $t = ($s.ToLower() -replace $SIZERE, ' ') -replace '[^a-z0-9 ]', ' '
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($w in ($t -split '\s+')) {
    # A BARE POSSESSIVE "s" IS NOT A TOKEN, and letting it be one cost a lead slot. "Member's Mark Natural
    # Sliced Strawberries" tokenised to member(0), s(1), mark(2) - so `mark` was never once counted as leading
    # anywhere in this 26k-name corpus, never made the lexicon, and Brands-Of (first 3 tokens) matched on
    # `member` alone. The consequence was not cosmetic: `mark` then survived into the product-identity test
    # below as if it were a food word, and "Member's Mark Sliced Strawberries" vs "Member's Mark Triple Berry
    # Blend" SHARED it, so two different products read as the same one and a pin was written across them.
    # Dropping single characters restores the second word of every possessive brand (Member's Mark, Smucker's,
    # Hy-Vee's) to a lead slot. Measured: BRAND 755 -> 778, and no name loses a token that says anything.
    if (-not $w -or $w.Length -lt 2 -or $w -match '^\d+$' -or $w -match ('^(' + $LEXNOISE + ')$')) { continue }
    if ($w.Length -gt 3 -and $w.EndsWith('s') -and -not $w.EndsWith('ss')) { $w = $w.Substring(0, $w.Length - 1) }
    $out.Add($w)
  }
  return $out
}
foreach ($n in $lexNames) {
  $t = @(Sig-Tokens $n)   # @() IS LOAD-BEARING - see Brands-Of
  for ($i = 0; $i -lt $t.Count; $i++) {
    $w = $t[$i]
    if (-not $totalN.ContainsKey($w)) { $totalN[$w] = 0; $leadN[$w] = 0 }
    $totalN[$w]++
    if ($i -lt 2) { $leadN[$w]++ }
  }
}
$BRAND = New-Object System.Collections.Generic.HashSet[string]
foreach ($w in $totalN.Keys) { if ($totalN[$w] -ge 6 -and ($leadN[$w] / $totalN[$w]) -ge 0.80) { [void]$BRAND.Add($w) } }
# A WORD THAT NAMES A COMMODITY IS NOT A BRAND, however reliably it leads. Produce breaks the
# lead-position heuristic outright: "Carrot", "Blueberries", "Plum Bag" begin with the food itself, so
# `carrot` scored like a manufacturer and Fareway's "Carrot" was flagged against a "Dole Carrots, Mini
# Cut" link for disagreeing about a brand the board never named. Subtracting every commodity id and
# label word removes that whole class - and costs nothing real, since no manufacturer is named after
# the single word for the thing it sells.
$foodWords = New-Object System.Collections.Generic.HashSet[string]
# NAME THE DEPENDENCY WHEN IT IS ABSENT. A bare Get-Content throw here reads as a PowerShell stack trace
# rather than "this audit needs a file", and that is exactly how five red test cases spent a morning
# looking like a name-drift regression when they were fixtures that had never been given this file.
$cmFile = Join-Path $root 'commodities.json'
if (-not (Test-Path $cmFile)) {
  throw ("audit-name-drift needs commodities.json in $root - it subtracts every commodity id/label word " +
         'from the learned brand lexicon so a food word ("Carrot", "Paprika") is never mistaken for a ' +
         'manufacturer. A fixture that copies this script must copy a commodities.json beside it.')
}
foreach ($cm in (Read-JsonFile $cmFile)) {
  foreach ($src in @([string]$cm.id, [string]$cm.label)) {
    foreach ($w in (Sig-Tokens ($src -replace '-', ' '))) { [void]$foodWords.Add($w) }
  }
}
foreach ($w in @($foodWords)) { [void]$BRAND.Remove($w) }
function Brands-Of([string]$s) {
  # @() IS LOAD-BEARING. A one-token name ("Carrot") comes back from Sig-Tokens as a bare STRING,
  # not a list, and $t[0] then indexes the STRING - yielding the character "c". That is how Fareway
  # carrots was flagged brand-mismatch against a Dole link: the board named no brand, PowerShell
  # invented one letter long, and "c" happened to be in the lexicon (which the same bug had put there).
  $t = @(Sig-Tokens $s); $b = New-Object System.Collections.Generic.HashSet[string]
  for ($i = 0; $i -lt [math]::Min(3, $t.Count); $i++) { if ($BRAND.Contains($t[$i])) { [void]$b.Add($t[$i]) } }
  return $b
}
$brandActive = ($BRAND.Count -ge 100)   # too few names to have learned anything -> the clause has NO opinion, and says so

# ---------------------------------------------------------------- PRODUCT IDENTITY (2026-08-30)
# SAME BRAND, DIFFERENT PRODUCT - the hole every other clause here leaves open, and the one that let a pin be
# written over a price the board had got right.
#
# The token test asks only "does ANY distinctive board word appear in the link name", and a shared house brand
# answers it. Board "Member's Mark Natural Sliced Strawberries, Frozen, 4 lbs." reduces to member/mark/sliced
# once $stop has removed natural, strawberries, frozen and lbs - so `member` matched "Member's Mark Triple
# Berry Blend, Frozen, 64 oz." and the cell read clean. form-flip could not fire (both say frozen). count
# mismatch could not fire (neither states a pack count). brand mismatch could not fire either, and MUST not -
# it is the same brand. The two names disagree about nothing except WHICH PRODUCT, which is the only thing
# that mattered: generate-board-overrides then pinned frozen-fruit / Sam's to the Triple Berry link's
# 16.34c/oz over the board's own strawberries at 12.47c/oz, both of them real rows in the same capture.
#
# So ask the question the token test cannot: strip the brand off BOTH names and see whether anything is left
# that they still share. Deliberately narrow, because a false flag here silently blocks a legitimate pin:
#   - BRAND words are removed. Two products by one maker must be separable by what they ARE.
#   - FORM words are removed (fresh/frozen/canned/dried). $formFlip owns that axis; leaving them in let
#     "Blueberries, Fresh Frozen" and "Cherry Berry Blend, Fresh Frozen" share `frozen` and pass.
#   - Sizes, counts and $LEXNOISE are already gone via Sig-Tokens.
#   - Fires ONLY when BOTH sides still have an identity word. A name that is nothing but brand and size
#     states no product and cannot disagree about one - the same silence rule brand mismatch keeps.
# MEASURED over the live board (3,003 cells): 4 flags, every one a genuinely different product - Member's Mark
# strawberries vs triple berry blend, Our Family blueberries vs cherry berry blend, Summit lemon-lime vs
# Summit zero sugar cola, Hy-Vee trash bags vs tall kitchen bags. No false positives, and no existing pin
# other than the frozen-fruit one is touched.
$IDENTFORM = 'frozen|canned|dried|fresh|refrigerated'
function Ident-Tokens([string]$s) {
  $r = New-Object System.Collections.Generic.HashSet[string]
  foreach ($w in @(Sig-Tokens $s)) {
    if ($w.Length -le 3) { continue }
    if ($BRAND.Contains($w)) { continue }
    if ($w -match ('^(' + $IDENTFORM + ')$')) { continue }
    [void]$r.Add($w)
  }
  return $r
}

$flags = @(); $examined = 0; $exByStore = @{}; $exCells = New-Object System.Collections.Generic.List[string]
foreach ($it in $c) {
  $id = [string]$it.id
  if (-not $purls.$id) { continue }
  foreach ($s in $it.stores) {
    $store = [string]$s.store; $item = [string]$s.item
    if (-not $item) { continue }
    $lnk = $purls.$id.$store
    if (-not $lnk -or -not $lnk.url) { continue }
    $examined++; if (-not $exByStore.ContainsKey($store)) { $exByStore[$store] = 0 }; $exByStore[$store]++
    # WHICH cells, not just how many. guards.ps1 guard 3 has to know whether the pin it is about to bless was
    # actually product-identity-checked, and it CANNOT re-derive that: 161 of the recipe board's 404 cells
    # record no .item at all, so "the id is on a board" is NOT "the cell was examined" - that re-derivation
    # prints 16 of 16 when the true answer is 6 (measured 2026-07-30). Publish the examined set so the
    # consumer reads a fact instead of keeping a second, drifting copy of this loop's admission test.
    [void]$exCells.Add($id + '|' + $store)
    $lname = ([string]$lnk.name).ToLower()
    # FORM FLIP AND COUNT MISMATCH ARE INDEPENDENT OF THE TOKEN TEST, so compute them BEFORE the token bail-out.
    # The old order checked distinctive tokens first and `continue`d when there were none - and a board item named
    # with nothing BUT commodity words has none, because those words are all in $stop. That is exactly how Aldi's
    # FRESH blueberries stayed linked to "Season's Choice FROZEN Blueberries": the board item is literally
    # "Blueberries", so $btoks came back empty, the cell was skipped before the form check could fire, the wrong
    # link went unflagged, generate-board-overrides trusted it as ground truth and pinned the board to it, and the
    # page published Aldi fresh blueberries at the FROZEN price (16c/oz) with a CHEAPEST flag on it. The most
    # generic product names are the ones a token test can say least about, so they must not be the ones it skips.
    # NB the second clause needs "and the board item is not itself frozen": a product legitimately called
    # "Fresh Frozen" (Our Family's frozen veg / peas) contains BOTH words, so fresh->frozen fired on a link whose
    # name was byte-identical to the board item. A flag on an identical name is pure noise, and noise here has a
    # cost - generate-board-overrides refuses to pin any cell name-drift flags, so a false flag silently blocks a
    # legitimate price correction.
    $formFlip = ((($lname -match 'frozen|canned|dried') -and ($item.ToLower() -notmatch 'frozen|canned|dried')) -or (($item.ToLower() -match 'fresh') -and ($item.ToLower() -notmatch 'frozen|canned') -and ($lname -match 'frozen|canned')))
    # COUNT MISMATCH: when the board item and the link BOTH declare a pack count and the counts differ, they are
    # different products however similar the words are - the token test cannot see this at all (Hy-Vee's own
    # "Chewy Granola Bars Variety Pack 18Ct" vs a "Quaker Chewy ... 8 ct" link share "chewy"/"granola"/"bars", so
    # ONE shared word passed it). Same class as the Hy-Vee orange-juice 64oz-vs-gallon bug. Only fires when both
    # sides state a count, so a bare "Bananas" never trips it.
    function CountOf([string]$t) { $m = [regex]::Match(([string]$t).ToLower(), '(\d+)\s*(?:ct\b|count\b|pk\b|pack\b)'); if ($m.Success) { return [int]$m.Groups[1].Value } return 0 }
    $bCount = CountOf $item
    $lCount = CountOf ($lname + ' ' + [string]$lnk.size)
    $countMismatch = ($bCount -gt 0 -and $lCount -gt 0 -and $bCount -ne $lCount)
    $btoks = @(($item.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_ -and $_.Length -gt 3 -and $_ -notmatch ('^(' + $stop + ')$') })
    $hit = $false; foreach ($t in $btoks) { if ($lname -match [regex]::Escape($t)) { $hit = $true; break } }
    # no distinctive tokens = the token test has NO opinion; it must not read as "clean" (that was the bug above)
    if ($btoks.Count -eq 0) { $hit = $true }
    # BRAND MISMATCH: both names state a manufacturer and they are different manufacturers. Independent
    # of the token test for the same reason form-flip is - "Classico Pasta Sauce or Alfredo" and "Ragu
    # Classic Alfredo Sauce" share alfredo, sauce and classic/classico, so the token test is satisfied
    # by words that say nothing about who made it.
    #
    # Fires ONLY when both sides name a brand. Silence when either side names none is deliberate: a
    # board item reading just "Blueberries" cannot disagree about a brand it never stated, and guessing
    # there would flag the generic names this audit was specifically fixed to stop skipping.
    #
    # The prefix clause is not cosmetic. Aldi's board item arrives as "Nescaf" where the link says
    # "Nescafe Clasico" - the same brand with an accented character eaten in transit. Without it, that
    # was the single false positive in the 22 this rule found.
    $brandMismatch = $false
    if ($brandActive) {
      $bb = Brands-Of $item; $bl = Brands-Of ([string]$lnk.name)
      if ($bb.Count -gt 0 -and $bl.Count -gt 0) {
        $shared = $false
        foreach ($x in $bb) { foreach ($y in $bl) { if ($x -eq $y -or $x.StartsWith($y) -or $y.StartsWith($x)) { $shared = $true; break } }; if ($shared) { break } }
        $brandMismatch = -not $shared
      }
    }
    # PRODUCT MISMATCH: both names name a product, and after the shared brand is stripped they share none of it.
    # Gated on $brandActive for the same reason brand mismatch is - with no learned lexicon the brand words
    # stay in the identity set, every same-brand pair looks like a match, and the clause has no opinion worth
    # having. It must say nothing rather than guess.
    $prodMismatch = $false
    if ($brandActive) {
      $bi = Ident-Tokens $item; $li = Ident-Tokens ([string]$lnk.name)
      if ($bi.Count -gt 0 -and $li.Count -gt 0) {
        $sharedProd = $false
        foreach ($x in $bi) { if ($li.Contains($x)) { $sharedProd = $true; break } }
        $prodMismatch = -not $sharedProd
      }
    }
    if ((-not $hit) -or $formFlip -or $countMismatch -or $brandMismatch -or $prodMismatch) {
      $reason = if ($formFlip) { 'form-flip' } elseif ($countMismatch) { 'count-mismatch' } elseif ($brandMismatch) { 'brand-mismatch' } elseif ($prodMismatch) { 'product-mismatch' } else { 'name-drift' }
      $flags += [pscustomobject]@{ id=$id; store=$store; reason=$reason; board_item=$item; link_name=[string]$lnk.name; link_price=$lnk.price }
    }
  }
}
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); count=$flags.Count; examined=$examined; examined_by_store=$exByStore; examined_cells=@($exCells); flags=$flags } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $out 'name-drift.json') -Encoding UTF8
Write-Output ("name/form-drift suspects: " + $flags.Count + " of $examined cells tested (REVIEW - some are just brand differences)")
$flags | Sort-Object reason, store, id | ForEach-Object { Write-Output ("  [{0}] {1,-14} {2}`n     BOARD: {3}`n     LINK : {4}" -f $_.reason, $_.store, $_.id, $_.board_item, $_.link_name) }
if ($examined -eq 0) {
  Write-Output 'name-drift: BLIND - examined ZERO cells (product-urls.json has no id/store matching this board; check .items). The count=0 name-drift.json just written is blind, not clean: build-deals-page link suppression, guard 3, and tile-integrity WRONG-PRODUCT all read it as clean.'
  exit 3
}
# This script has no exit 0 - it falls off the end on its normal path, so the marker goes here. The BLIND
# branch above keeps exit 3 and no marker: could-not-evaluate is not completion.
Write-GuardComplete -Name 'name-drift'
