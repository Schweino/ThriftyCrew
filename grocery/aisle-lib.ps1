<#
  aisle-lib.ps1 - THE ONE COPY of Family Fare's shelf-path rule: which store DEPARTMENTS a commodity may take a
  product from.

  WHY IT IS A LIB (2026-09-11, queue 2026-09-11-62b248, triage-plans\plan-2026-09-11.json). The rule lived in
  aisle-test.ps1's script body, where it could only JUDGE a board that had already published. Family Fare's
  'Contadina Tmto Bsl Pizza Squz Btl' - a 13 oz pizza-SAUCE squeeze bottle - held the frozen-pizza cell at
  $2.99 because the store's abbreviated name carries no type word for any fence to see, while the store had
  itself shelved the product in pantry/canned_goods on the very row the estate held. The four earlier closes of
  this alert type each added a token, a brand class or a map entry; none moved the shelf path into ADMISSION.
  Two callers now read this one copy:
    - compare-deals.ps1 admits a Family Fare row only when the store's department is allowed for the commodity
      (Get-AisleAdmissionRefusal, over the index Add-AisleShelfRow builds as the everyday rows load);
    - aisle-test.ps1 keeps judging the LIVE board as the outcome watch, and its -SelfTest drives these same
      functions, so a frozen fixture proves the rule the engine runs rather than a transcription of it.
  pull-regular-familyfare.ps1 stamps dept/aisle on the rows it writes through Get-AisleDept / Get-AisleShelf.

  BLIND ADMITS AT ADMISSION; BLIND REFUSES A FLIP IN aisle-test. The two callers ask different questions.
  aisle-test asks "may this candidate REPLACE a cell", where no evidence means no change. compare-deals asks
  "may this price exist at all", where a row with no shelf path (an ad row, a carried row that has lost its
  canonical_url) is the known state, and refusing it would let a could-not-look settle the question. Only a
  BLOCK - a department the store itself authored, outside the commodity's allowed set - refuses.

  NO param() BLOCK AND NO $root, ON PURPOSE. Dot-sourcing runs a lib's param() in the caller's scope (the
  ff-price-lib.ps1 header has the incident), and both callers own a $root. Every path is an argument. It
  dot-sources lib\json-io.ps1 itself for its JSON reader rather than trusting its caller to have done so
  (the pre-commit bulk-edit gate refuses a file that calls a function it cannot resolve); a second load of
  json-io by a caller that already has it only redefines the same functions.
#>
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

# ---- the shelf path, reduced to what we compare on -------------------------------------------------
# Segment 1 is the DEPARTMENT (fresh_fruits_vegetables, household, health_beauty, pantry...). Segment 2 is
# the aisle within it. We gate on DEPARTMENT: it is the level the four failures violate, and it is stable -
# a store reshuffling an aisle inside a department must not start refusing real product.
# A PRODUCT SLUG IS NOT A DEPARTMENT (2026-09-11, found by the admission dry run for queue 2026-09-11-62b248).
# Some Family Fare rows carry a shelf-less canonical_url, '/shop/<product_slug>/p/<id>', and the reduction used
# to read the slug as the department: 'Kraft Grated Cheese, Parmesan Cheese, 8 Oz' sat in department
# 'kraft_grated_cheese_parmesan_cheese_8_oz' and was BLOCKED from parmesan, a real product refused on a word
# the store never wrote. A department is only a department when another shelf segment follows it, so that
# URL now reduces to no shelf path (BLIND), which admits at admission and refuses a flip in aisle-test.
function Get-AisleDept([string]$u) {
  if (-not $u) { return '' }
  $m = [regex]::Match([string]$u, '/shop/([^/]+)/(?!p/)[^/]+/')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}
function Get-AisleShelf([string]$u) {
  if (-not $u) { return '' }
  $m = [regex]::Match([string]$u, '/shop/([^/]+)/(?!p/)([^/]+)/')
  if ($m.Success) { return ($m.Groups[1].Value + '/' + $m.Groups[2].Value).ToLower() }
  return (Get-AisleDept $u)
}

# ---- the AUTHORED category -> department allowlist ---------------------------------------------------
# This table is written by a human and reviewed. The first build LEARNED it per commodity from rows the
# engine matched, and that failed for a reason worth keeping: the rules are already polluted, so the
# profile inherited their errors. watermelon's learned profile contained health_beauty (1 of 10 matches)
# purely because the rule already matches Olay Watermelon Body Wash - so the gate cheerfully ALLOWED the
# body wash. A gate that learns its baseline from the thing it is auditing cannot catch that thing.
#
# Measured department mix per estate category on the live FF catalogue (2026-08-01, n in parens):
#   pet 100% pets_wildlife (141)    baby 100% health_beauty (62)     canned 97% pantry (358)
#   personal 94% health_beauty (283) condiments 93% pantry (383)     household 91% household (265)
#   grains 91% pantry (201)         frozen 89% freezer (101)          baking 84% pantry (350)
#   meat 83% meat +13% deli (240)   bakery 78% bakery (94)            dairy 66% dairy +18% deli (282)
#   veg 62% fresh_fruits_vegetables (137)
# and THREE that are not mapping failures but rule pollution, recorded here because they are findings:
#   fruit  34% fresh_fruits_vegetables, 26% pantry, 24% BEVERAGES, 7% HEALTH_BEAUTY (140)
#   snacks 47% beverages, 45% pantry (600)
#   oils   69% pantry, 29% beverages (191)   [also: 'coffee' is filed under 'oils', likely miscategorised]
# For `fruit` the allowlist is deliberately produce-ONLY: the beverage and health_beauty share IS the
# defect this gate exists to stop, so encoding it would be encoding the bug.
$AISLE_CAT_DEPT = @{
  'baby'       = @('health_beauty')
  'bakery'     = @('bakery', 'pantry')
  'baking'     = @('pantry')
  'canned'     = @('pantry')
  'condiments' = @('pantry', 'deli')
  'dairy'      = @('dairy', 'deli')
  'frozen'     = @('freezer')
  'fruit'      = @('fresh_fruits_vegetables')
  'grains'     = @('pantry')
  'household'  = @('household')
  'meat'       = @('meat', 'deli', 'meat_seafood')
  'oils'       = @('pantry')
  'personal'   = @('health_beauty', 'household')
  'pet'        = @('pets_wildlife')
  'snacks'     = @('pantry', 'beverages')
  'veg'        = @('fresh_fruits_vegetables', 'pantry', 'freezer')
}

# ---- reviewed per-commodity exceptions ---------------------------------------------------------------
# The category default is right for most things and WRONG for a predictable minority: commodities the
# STORE shelves somewhere other than where the estate files them. Measured by judging all 3,828
# rule-matched FF rows and reading every commodity that absorbed blocks - 10.8% blocked, and these are the
# ones where the blocked rows were REAL product, not pollution:
#   coffee(30) + orange-juice(26) + lemonade(7)  real drinks, but filed under 'oils'/'fruit'
#   hand-soap(24) + protein-bars(19)             stores shelve these in health_beauty, not household/snacks
#   whipped-cream(9)                             Cool Whip is literally frozen
#   dried-cranberries(7)                         dried fruit is pantry, not produce
# Everything else that blocked was the gate working: Spindrift Blood Orange sparkling water under
# `oranges`, Ruffles Cheddar & SOUR CREAM chips under `sour-cream`, Eggo Cookies-and-Creme waffles under
# `cookies`, Mike's HARD Lemonade under `lemonade`, Starbucks Refreshers under `watermelon`.
# NOTE for later: `coffee` sits in the estate category 'oils', which is almost certainly a
# miscategorisation rather than an aisle problem. Left alone here - recategorising a commodity moves it on
# the public board's category filter, which is a bigger change than this gate should make on its own.
# 2026-08-06 (triage plan-2026-08-06, item 2026-08-03-3ec6da): the standing BLOCK set had grown to a fixed
# 21 rows that re-paged on every product-string churn, and ALL 21 were read row by row against the board -
# every one a REAL instance of its commodity that Family Fare simply shelves somewhere else (Sugar 'N Spice
# spice packets and bagged Chile De Arbol in produce, canned milks and refrigerated bagels in dairy,
# ReaLemon-class juices in beverages, breaded nuggets and fish sticks filed under meat, Pampa rice and Lil
# Dutch Maid cookies in the trial-sizes aisle, dried prunes in pantry, California Sun Dry tomatoes in
# produce). A standing set of known-real blocks is worse than useless: a genuinely NEW cross-department
# hijack arrives buried in a 21-row list a human has to diff from memory. Draining it to zero re-arms the
# signature dedup in check-ad-cycles so the alert only speaks on a new block.
# EVERY entry below is the commodity's CURRENT category allowlist PLUS the observed FF department - never a
# raw replacement, because this table REPLACES the category map (see Test-AisleAllowed), so a bare list would
# silently BLOCK a department that is allowed today. Verified: none of the 21 loses a department it already
# allows. The category-level map above stays tight on purpose - loosening it is the thing this gate exists
# to refuse.
$AISLE_COMMODITY_DEPT = @{
  'coffee'            = @('beverages', 'pantry')
  'orange-juice'      = @('beverages', 'pantry')
  'lemonade'          = @('beverages', 'pantry')
  'hand-soap'         = @('health_beauty', 'household')
  'protein-bars'      = @('health_beauty', 'pantry')
  'whipped-cream'     = @('freezer', 'dairy')
  'dried-cranberries' = @('pantry', 'fresh_fruits_vegetables')
  # --- reviewed 2026-08-06, all 21 read against their board row ---
  'bagels'             = @('bakery', 'pantry', 'dairy')                                # FF shelves Lender's/Bubba's bagels in dairy
  'bay-leaves'         = @('pantry', 'fresh_fruits_vegetables')                         # Sugar 'N Spice packets hang in produce
  'curry-powder'       = @('pantry', 'fresh_fruits_vegetables')
  'dried-arbol-chiles' = @('pantry', 'fresh_fruits_vegetables')                         # bagged dried chiles are a produce item
  'ground-fennel'      = @('pantry', 'fresh_fruits_vegetables')
  'ground-turmeric'    = @('pantry', 'fresh_fruits_vegetables')
  'poultry-seasoning'  = @('pantry', 'fresh_fruits_vegetables')
  'condensed-milk'     = @('pantry', 'dairy')                                           # canned milks sit in the dairy aisle
  'evaporated-milk'    = @('pantry', 'dairy')
  'cheese-tortellini'  = @('pantry', 'freezer')
  'rice'               = @('pantry', 'seasonal_special_occasion')                        # Pampa rice in the trial-sizes aisle
  'chicken-nuggets'    = @('freezer', 'meat')                                            # breaded frozen nuggets filed under meat
  'fish-sticks'        = @('freezer', 'meat')
  'coffee-creamer'     = @('dairy', 'deli', 'beverages')                                 # 26 FF creamers hang in beverages
  'corned-beef-hash'   = @('pantry', 'meat')
  'gingersnaps'        = @('pantry', 'beverages', 'seasonal_special_occasion')
  'lemon-juice'        = @('pantry', 'deli', 'beverages')                                # ReaLemon-class juice bottles
  'lime-juice'         = @('pantry', 'deli', 'beverages')
  'minced-garlic'      = @('pantry', 'deli', 'fresh_fruits_vegetables')
  'prunes'             = @('fresh_fruits_vegetables', 'pantry')                          # dried fruit is pantry, not produce
  'sun-dried-tomatoes' = @('pantry', 'fresh_fruits_vegetables')                          # FF shelves the California Sun Dry jar in produce
  # --- reviewed 2026-08-30 (plan-2026-08-30-2, queue 2026-08-30-2611d3), each read against its board row ---
  # The standing BLOCK set had regrown to 11 and re-paged every 3 days. Ten were RIGHT products failing a
  # wrong map; the eleventh was Blue Bunny ICE CREAM holding the pistachios crown, which is the catch this
  # gate exists for and which was buried under the ten. Draining the ten re-arms the signature dedup so the
  # alert only speaks on a NEW block. Every entry below is the commodity's current category allowlist PLUS
  # the observed Family Fare department - never a bare replacement, because this table REPLACES the category
  # map in Test-AisleAllowed, so a short list would silently BLOCK a department that is allowed today.
  'dried-basil'        = @('pantry', 'fresh_fruits_vegetables')   # Litehouse freeze-dried herbs hang on the produce spice rack
  'black-peppercorns'  = @('pantry', 'fresh_fruits_vegetables')   # Sugar 'N Spice packets, same rack as bay-leaves above
  'cinnamon-stick'     = @('pantry', 'fresh_fruits_vegetables')   # Canela Entera, the Hispanic spice rack in produce
  'whole-cloves'       = @('pantry', 'fresh_fruits_vegetables')   # Sugar 'N Spice packets
  'dried-ancho-chiles' = @('pantry', 'fresh_fruits_vegetables')   # bagged dried chiles ARE a produce item at FF, like dried-arbol-chiles
  # The three alcohol rows are right products in the right aisle: the estate files them under the 'snacks'
  # CATEGORY (pantry, beverages), so beer_wine_spirits is disallowed for a bottle of wine. Fixed here rather
  # than by recategorising, because a commodity's category is also its section on the public board and that
  # is a bigger change than this gate should make on its own (see the coffee note above).
  'brandy'             = @('pantry', 'beverages', 'beer_wine_spirits')
  'red-wine'           = @('pantry', 'beverages', 'beer_wine_spirits')
  'white-wine'         = @('pantry', 'beverages', 'beer_wine_spirits')
  'vienna-sausage'     = @('pantry', 'meat')                      # FF files Libby's tins under meat/sausage; category 'canned' allows only pantry
  'parmesan'           = @('dairy', 'deli', 'pantry')             # Our Family GRATED 16 oz is shelf-stable and sits in pantry
  # --- reviewed 2026-08-31 (queue 2026-08-31-e6a93d), each read against its Family Fare row ---
  # Three blocks, all RIGHT product on a shelf the map does not allow, so the standing set was about to
  # start regrowing again - which is the state the 08-06 and 08-30 notes above both drained precisely so a
  # genuinely new hijack cannot arrive buried in a list. Nothing here loses a department it allows today.
  #   celery-salt    'Dan's Pantry Celery Salt' $4.99 / 12 oz, in fresh_fruits_vegetables/fresh_spices_herbs
  #   smoked-paprika 'Sugar N Spice Paprika Smoked Pp' $2.49 / 1 oz, the SAME produce spice rack and the
  #                  SAME brand already reviewed for bay-leaves, black-peppercorns and whole-cloves
  # Neither of those two is even on the board (both under MinStores), so the block was costing a candidate
  # rather than publishing a wrong cell - still worth draining, for the buried-in-a-list reason above.
  #   pistachios     'Planters Dry Roasted Pistachios 12.75 Oz' $5.99, filed in dairy/ready_to_eat. Read the
  #                  whole row before allowing it, because THIS is the commodity Blue Bunny ice cream
  #                  crowned on 08-30: all five cells are real pistachios today and the crown is Sam's
  #                  48 oz at 0.3538/oz, with the Planters row a non-crown runner-up at 0.4698.
  'celery-salt'        = @('pantry', 'fresh_fruits_vegetables')
  'smoked-paprika'     = @('pantry', 'fresh_fruits_vegetables')
  'pistachios'         = @('pantry', 'beverages', 'dairy')
  # --- reviewed 2026-09-11 (queue 2026-09-11-62b248), found by the ADMISSION dry run, each read against its row ---
  # compare-deals now refuses at admission, so a map gap costs a candidate on every build instead of paging once.
  # The dry run over the rebuilt comparison-2026-09-09 refused 19 Family Fare rows and moved 0 of 454 cells. The
  # rows below were REAL product on a shelf the map does not allow, so each commodity gets its current category
  # allowlist PLUS the observed department. Two more were a reduction defect, not a map gap (see Get-AisleDept).
  #   cookies        'Fresh & Finest' 10 ct chocolate chip and oatmeal raisin cookies (bakery), Bud's Best bite size
  #                  cookies (seasonal_special_occasion). Eggo cookies-and-creme WAFFLES in freezer stay refused.
  #   pickles        Grillo's Pickles Classic Dill Spears 32 fl oz, a refrigerated pickle filed in deli
  #   chili-powder   'Sugar N Spice Chili Powder Pp', the produce spice rack already reviewed for curry-powder
  #   garlic-powder  'Sugar 'N Spice Roasted Garlic Powder Pp', the same rack
  'cookies'            = @('pantry', 'beverages', 'bakery', 'seasonal_special_occasion')
  'pickles'            = @('pantry', 'deli')
  'chili-powder'       = @('pantry', 'fresh_fruits_vegetables')
  'garlic-powder'      = @('pantry', 'fresh_fruits_vegetables')
}

# ---- which estate category key each commodity id carries ---------------------------------------------
function Get-AisleCategoryMap {
  param([Parameter(Mandatory)][string]$Root)
  $cats = Read-JsonFile (Join-Path $Root 'categories.json')
  $m = @{}
  $keyByLabel = @{}
  foreach ($c in @($cats.categories)) {
    $keyByLabel[[string]$c.label] = [string]$c.key
    foreach ($id in @($c.commodities)) { $m[[string]$id] = [string]$c.key }
  }
  # THE RECIPE BOARD IS A SECOND ID NAMESPACE (2026-08-30, queue 2026-08-30-2611d3). categories.json lists
  # only the STAPLE ids, so every recipe-board id reached the verdict with no category and came back BLIND -
  # 21 of them on 2026-08-30 (greek-yogurt, mozzarella-cheese, salsa-verde, smoked-paprika and 17 more),
  # while -LiveBoard has been reading recipe-board.json since it was written. Unjudged is exactly how the
  # Blue Bunny ice cream held the pistachios crown, so a whole namespace nobody judges is the same hole
  # one commodity wide. The recipe rows carry their category as a LABEL on the row itself; build-deals-page
  # already THROWS if that label is not one of categories.json's sections, so the label is canonical and
  # this is a lookup, not a guess. categories.json membership always wins - a staple id can never be
  # re-keyed by a recipe row - and a label with no section is left BLIND rather than mapped to something.
  foreach ($rbn in @('out\recipe-board-everyday.json', 'out\recipe-board.json')) {
    $rbp = Join-Path $Root $rbn
    if (-not (Test-Path $rbp)) { continue }
    try { $rbd = Read-JsonFile $rbp } catch { continue }
    foreach ($r in @($rbd.comparison)) {
      $rid = [string]$r.id; $rlab = [string]$r.category
      if (-not $rid -or -not $rlab) { continue }
      if ($m.ContainsKey($rid)) { continue }
      if ($keyByLabel.ContainsKey($rlab)) { $m[$rid] = $keyByLabel[$rlab] }
    }
  }
  return $m
}

# ---- the verdict: ALLOW, BLOCK or BLIND, with the department it saw ----------------------------------
# The reason strings are the ones aisle-test has always printed; check-ad-cycles dedupes its BLOCK alert on
# them, so rewording one re-pages every standing block.
function Test-AisleAllowed {
  param($CatMap, [string]$CommodityId, [string]$Url = '', [string]$Dept = '')
  if (-not $Dept) { $Dept = Get-AisleDept $Url }
  if (-not $Dept) { return [pscustomobject]@{ verdict = 'BLIND'; reason = 'candidate has no shelf path - cannot place it on a shelf, so the flip is refused'; dept = '' } }
  if ($AISLE_COMMODITY_DEPT.ContainsKey($CommodityId)) {
    $ov = @($AISLE_COMMODITY_DEPT[$CommodityId])
    if ($ov -contains $Dept) { return [pscustomobject]@{ verdict = 'ALLOW'; reason = "'$Dept' is a reviewed exception department for '$CommodityId'"; dept = $Dept } }
    return [pscustomobject]@{ verdict = 'BLOCK'; reason = "candidate sits in '$Dept'; '$CommodityId' allows only: $($ov -join ', ')"; dept = $Dept }
  }
  if (-not $CatMap.ContainsKey($CommodityId)) { return [pscustomobject]@{ verdict = 'BLIND'; reason = "'$CommodityId' is in no estate category - refused rather than guessed"; dept = $Dept } }
  $cat = $CatMap[$CommodityId]
  if (-not $AISLE_CAT_DEPT.ContainsKey($cat)) { return [pscustomobject]@{ verdict = 'BLIND'; reason = "category '$cat' has no reviewed department allowlist - refused rather than guessed"; dept = $Dept } }
  $allowed = @($AISLE_CAT_DEPT[$cat])
  if ($allowed -contains $Dept) { return [pscustomobject]@{ verdict = 'ALLOW'; reason = "'$Dept' is an allowed department for category '$cat'"; dept = $Dept } }
  return [pscustomobject]@{ verdict = 'BLOCK'; reason = "candidate sits in '$Dept'; category '$cat' allows only: $($allowed -join ', ')"; dept = $Dept }
}

# ---- ADMISSION: the index compare-deals builds as rows load, and the refusal it asks ------------------
# Keyed by the store's product id first and the trimmed name second, so an ad row naming the same product
# (ads carry no shelf path) is judged by the department its everyday twin was shelved in. A product keeps
# its department across captures; the newest row indexed wins.
function New-AisleShelfIndex { return @{ by_id = @{}; by_name = @{} } }
function Add-AisleShelfRow($Index, $Row) {
  if (-not $Row) { return }
  $dept = [string]$Row.dept
  if (-not $dept) { $dept = Get-AisleDept ([string]$Row.canonical_url) }
  if (-not $dept) { return }
  $prodId = [string]$Row.product_id
  if ($prodId) { $Index.by_id[$prodId] = $dept }
  $nm = ([string]$Row.item).Trim()
  if ($nm) { $Index.by_name[$nm] = $dept }
}
function Get-AisleShelfDept($Index, [string]$ProductId, [string]$Name) {
  if ($ProductId -and $Index.by_id.ContainsKey($ProductId)) { return [string]$Index.by_id[$ProductId] }
  $nm = ([string]$Name).Trim()
  if ($nm -and $Index.by_name.ContainsKey($nm)) { return [string]$Index.by_name[$nm] }
  return ''
}
# $null = ADMIT. A verdict object = REFUSE, carrying the department the store shelves the product in.
function Get-AisleAdmissionRefusal {
  param($CatMap, [string]$Store, [string]$CommodityId, [string]$Dept)
  if ([string]$Store -ne 'Family Fare') { return $null }   # the only capture that carries a shelf path today
  if (-not $Dept) { return $null }                          # BLIND admits at admission (see the header)
  $v = Test-AisleAllowed -CatMap $CatMap -CommodityId $CommodityId -Dept $Dept
  if ($v.verdict -eq 'BLOCK') { return $v }
  return $null
}
