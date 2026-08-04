# build-v2-spec.ps1 - THE v2 spec INTAKE tool (2026-07-27). Run-agnostic front door of the recipe
# import pipeline: assembles ONE db\recipes\<slug>.json v2 spec (the SPEC-SCHEMA.md shape) from a
# per-recipe intake JSON. This is the tool behind engine\README.md step 1 ("write a v2 spec into
# db\recipes"), which until now existed only as the r300 archive's hardcoded build-specs.ps1.
#
# INTAKE FILE SHAPE (-InFile, one recipe per file):
# {
#   "name": "...", "slug": "...", "protein": "beef", "cuisine": "Mexican",
#   "source_url": "https://...", "source_site": "site.com",       // site derived from url if absent
#   "visibility": "paid",                                          // optional, default paid
#   "ingredients": [ { "item": "93/7 Ground Beef",                 // CANONICAL db item name
#                      "grams": 1111,                              // grams at 14 servings (int)
#                      "buy": "2.5 lb",                            // optional; FriendlyAmt derives it
#                      "display_name": "..." } ],                  // optional reader-facing rename
#   "macros_per_serving": { "calories": 584, "protein_g": 28, "carbs_g": 90, "fat_g": 10 },
#   "tuning": [...], "manual_balance": false,                      // optional provenance
#   "writer_notes": [...], "forbidden_prose_terms": [...],         // optional authoring metadata
#   "prose": { "intro_html": "...", "shop_smart": "..."|[...], "make_it": [...],
#              "portion_html": "...", "cost_closing_html": "...", "upsell_html": "...",
#              "credit_html": "...",                               // optional; built from source if absent
#              "cost_note_html": "..." },                          // optional; house default if absent
#   "head": { "description": "...", "keywords": "...", "image": "", "prepTime": "PT20M",
#             "cookTime": "PT40M", "totalTime": "PT1H",            // recipeIngredient is NOT an intake
#             "steps": [...], "step_names": [...] }                // field; it is derived. step_names optional
# }
#
# WHAT THE TOOL DERIVES (never hand-typed):
#   * scaler.ing bid + gpu from db\ingredients.json (the canonical map), with the gpu UNIT-RECONCILED
#     to the live feed row's unit (fallback: board unit) - the 2026-07-19 brown-sugar 16x lesson.
#     A map gpu is calibrated to its era's unit; the widget computes feed.cheapest * grams/gpu, so gpu
#     MUST be grams per the unit the feed quotes.
#   * ingredients_display lines "<strong>Name (Brand):</strong> 2.5 lb (1111 g)" (brand from
#     food-macros-db, same filter as r300 build-specs; a display-renamed item never gets a second paren).
#   * ingredients_grams + scaler.ing PARALLEL to ingredients_display (equal length, same order -
#     build-card2 hard-fails otherwise).
#   * head.recipeIngredient (the JSON-LD ingredient list) derived FROM ingredients_display, one line per
#     displayed ingredient, same amounts, brand paren dropped (head-ingredients-lib.ps1). Never typed.
#   * cost_* numbers + cost_lines RENDERED from the recipe's db\costed.json row. The cost MATH lives in
#     engine\cost-recipes.ps1 ONLY (the two-copies-of-the-same-math blind spot is a documented board
#     trap); this tool renders and cross-checks, it never re-computes prices.
#   * stat + head.costPerServing populated; stat macros VERIFIED against a food-macros-db recompute
#     (tolerance 5 cal / 2 g protein, same as spec-guards).
#
# COSTING FLOW for a brand-new recipe (chicken-and-egg: cost-recipes reads specs, cost render needs
# the costed row):
#   1. build-v2-spec -InFile x.json                  -> fails: no costed row yet, tells you what to run
#   1. build-v2-spec -InFile x.json -RunCost         -> writes the structural spec, runs
#      engine\cost-recipes.ps1 -Slugs <slug> (splices db\costed.json), re-renders cost fields, rewrites.
#   or 1a. build-v2-spec -InFile x.json -AllowUncosted   (spec with zeroed cost fields)
#      1b. engine\cost-recipes.ps1 -Slugs <slug>
#      1c. build-v2-spec -InFile x.json -Force          (cost fields fill in)
#
# GUARDS RUN BEFORE WRITING (fail = nothing written):
#   * display/grams/scaler count + order match
#   * build-card2 self-test mirror: ceil(grams/pkg_g - 0.02) == costed buy_n on every package line
#   * CHEAPEST-FALLBACK: every emitted bid resolves on the public feed OR is allowlisted in
#     db\no-board-price-ok.json (else the live card silently shows cheapest == everyday)
#   * rendered cost lines sum EXACTLY to the costed row's batch/true totals (r300 exactness fix kept)
#   * em/en dash sweep over every string (Brad's rule); macro recompute check
#
# PS 5.1 NOTES: this file writes NEW spec files via per-object ConvertTo-Json (the proven r300
# build-specs path). It never round-trips an EXISTING spec (the \uXXXX prose corruption trap); on
# -Force it rebuilds from the intake file, it does not read-modify-write the old spec.
param(
  [Parameter(Mandatory=$true)][string]$InFile,
  [string]$OutDir,          # default <meal-prep>\db\recipes  (point at a scratch dir to stage/test)
  [string]$CostedFile,      # default <meal-prep>\db\costed.json
  [string]$IngredientsDb,   # default <meal-prep>\db\ingredients.json
  [string]$FoodDb,          # default <meal-prep>\food-macros-db.json
  [string]$DensitiesFile,   # default <meal-prep>\db\densities.json
  [string]$EachNounsFile,   # default <meal-prep>\db\each-nouns.json
  [string]$FeedFile,        # default <estate>\grocery\out\smp-feed.json
  [string]$NoBoardOkFile,   # default <meal-prep>\db\no-board-price-ok.json
  [string]$ManifestFile,    # default <meal-prep>\pipeline\v2-perserving.json (everyday_ps basis for stat.cost_ps)
  [switch]$RunCost,         # invoke engine\cost-recipes.ps1 -Slugs <slug> to cost a NEW recipe (writes db\costed.json; only valid when OutDir is the real db\recipes)
  [switch]$AllowUncosted,   # emit the spec with zeroed cost fields when no costed row exists yet
  [switch]$SkipMacroCheck,  # skip the food-macros-db stat recompute verification (items not in the DB yet)
  [switch]$Force            # allow overwriting an existing spec file
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path     # ...\meal-prep\pipeline
$mp   = Split-Path -Parent $here                            # ...\meal-prep
. (Join-Path $here 'head-ingredients-lib.ps1')              # head.recipeIngredient derived from ingredients_display
if(-not $OutDir){        $OutDir        = Join-Path $mp 'db\recipes' }
if(-not $CostedFile){    $CostedFile    = Join-Path $mp 'db\costed.json' }
if(-not $IngredientsDb){ $IngredientsDb = Join-Path $mp 'db\ingredients.json' }
if(-not $FoodDb){        $FoodDb        = Join-Path $mp 'food-macros-db.json' }
if(-not $DensitiesFile){ $DensitiesFile = Join-Path $mp 'db\densities.json' }
if(-not $EachNounsFile){ $EachNounsFile = Join-Path $mp 'db\each-nouns.json' }
if(-not $FeedFile){      $FeedFile      = Join-Path (Split-Path $mp -Parent) 'grocery\out\smp-feed.json' }
if(-not $NoBoardOkFile){ $NoBoardOkFile = Join-Path $mp 'db\no-board-price-ok.json' }
if(-not $ManifestFile){  $ManifestFile  = Join-Path $mp 'pipeline\v2-perserving.json' }

$LB=453.592; $OZ=28.3495

# ---------------- intake ----------------
$intake = Get-Content $InFile -Raw -Encoding utf8 | ConvertFrom-Json
foreach($k in @('name','slug','protein','cuisine','source_url','ingredients','macros_per_serving')){
  if($intake.PSObject.Properties.Name -notcontains $k -or -not $intake.$k){ throw ("intake missing required field: $k") }
}
$slug = [string]$intake.slug
if($slug -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$'){ throw ("slug is not kebab-case: '$slug'") }
$srcUrl = [string]$intake.source_url
if($srcUrl -notmatch '^https?://'){ throw ("source_url is not a URL: '$srcUrl'") }
$srcSite = if($intake.PSObject.Properties.Name -contains 'source_site' -and $intake.source_site){ [string]$intake.source_site } else { ([uri]$srcUrl).Host -replace '^www\.','' }
$visibility = if($intake.PSObject.Properties.Name -contains 'visibility' -and $intake.visibility){ [string]$intake.visibility } else { 'paid' }
$outFile = Join-Path $OutDir ($slug + '.json')
if((Test-Path $outFile) -and -not $Force -and -not $RunCost){ throw ("spec already exists: $outFile (pass -Force to rebuild it from the intake file)") }

function IProp($o,[string]$p){ $o.PSObject.Properties.Name -contains $p -and $null -ne $o.$p }

# ---------------- canonical stores ----------------
$ITEMS=@{}
foreach($row in (Get-Content $IngredientsDb -Raw -Encoding utf8 | ConvertFrom-Json)){ $ITEMS[[string]$row.item]=$row }
$dbm=@{}
foreach($i in ((Get-Content $FoodDb -Raw -Encoding utf8 | ConvertFrom-Json).items)){ $dbm[[string]$i.item]=$i }
$dnRoot = Get-Content $DensitiesFile -Raw -Encoding utf8 | ConvertFrom-Json
$dnm=@{}; foreach($p in $dnRoot.items.PSObject.Properties){ $dnm[$p.Name]=$p.Value }
$enm=@{}
foreach($p in ((Get-Content $EachNounsFile -Raw -Encoding utf8 | ConvertFrom-Json).items.PSObject.Properties)){ $enm[$p.Name]=$p.Value }
$noBoardOk=@{}
if(Test-Path $NoBoardOkFile){ foreach($b in ((Get-Content $NoBoardOkFile -Raw -Encoding utf8 | ConvertFrom-Json).bids)){ $noBoardOk[[string]$b]=1 } }

# ---- units of the LIVE price sources the scaler widget reads (feed first, board fallback) --------
$feedUnit=@{}; $feedKeys=@{}
if(Test-Path $FeedFile){
  $feed = (Get-Content $FeedFile -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
  if($feed){ foreach($p in $feed.PSObject.Properties){ $feedKeys[$p.Name]=1; if($p.Value.unit){ $feedUnit[$p.Name]=[string]$p.Value.unit } } }
} else { Write-Warning ("feed file not found ($FeedFile) - gpu reconciliation limited to board units, CHEAPEST-FALLBACK check skipped") }
$boardUnit=@{}
$gout = Join-Path (Split-Path $mp -Parent) 'grocery\out'
$cmpFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
if($cmpFile){ foreach($row in ((Get-Content $cmpFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json).comparison)){ $boardUnit[$row.id]=[string]$row.unit } }
$rbFile = Join-Path $gout 'recipe-board.json'
if(Test-Path $rbFile){
  foreach($row in ((Get-Content $rbFile -Raw -Encoding utf8 | ConvertFrom-Json).comparison)){ if(-not $boardUnit.ContainsKey($row.id)){ $boardUnit[$row.id]=[string]$row.unit } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
$script:gpuFixes=@(); $script:gpuFlags=@()
function Resolve-ScalerGpu([string]$item,[string]$bid,[double]$gpu,[string]$mapUnit){
  # ported verbatim from r300 build-specs (delta 3): gpu must be grams per the unit the FEED quotes
  $rowUnit = $null
  if($feedUnit.ContainsKey($bid)){ $rowUnit=$feedUnit[$bid] } elseif($boardUnit.ContainsKey($bid)){ $rowUnit=$boardUnit[$bid] }
  if(-not $rowUnit -or -not $mapUnit -or $rowUnit -eq $mapUnit){ return $gpu }
  if($UNIT_G.ContainsKey($mapUnit) -and $UNIT_G.ContainsKey($rowUnit)){
    $new = $gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$mapUnit])
    $script:gpuFixes += ("{0} [{1}] {2} -> {3}: gpu {4} -> {5}" -f $item,$bid,$mapUnit,$rowUnit,$gpu,[Math]::Round($new,3))
    return $new
  }
  $script:gpuFlags += ("{0} [{1}] NON-STANDARD UNIT MISMATCH map={2} live={3} (gpu left as mapped)" -f $item,$bid,$mapUnit,$rowUnit)
  return $gpu
}

# ---------------- friendly amounts (ported from r300 build-specs, deltas 5/6 kept) ----------------
function Den([string]$item,[string]$u){ if($dnm.ContainsKey($item) -and ($dnm[$item].PSObject.Properties.Name -contains $u)){ [double]$dnm[$item].$u } else { $null } }
# The noun that goes with a COUNT. Every other FriendlyAmt branch appends its unit; the each branch used
# to return the bare number, and 661 lines shipped reading "Potato (generic): 18.4 (3909 g)" - a typo as
# far as a reader can tell, recoverable only from the gram restatement. The noun cannot be derived from
# densities because 'each' is overloaded there (Chicken Broth each = 240 g IS a cup), so it is stated per
# item in db\each-nouns.json. A missing entry THROWS: a bare number is how this bug shipped the first time.
function EachNoun([string]$item,[double]$n){
  if(-not $enm.ContainsKey($item)){
    throw ("no each-noun for '$item' - it reaches the FriendlyAmt each branch, so it needs a {one, many} entry in db\each-nouns.json (otherwise the card prints a count with no unit)")
  }
  if([Math]::Abs($n - 1.0) -lt 1e-9){ return [string]$enm[$item].one }
  return [string]$enm[$item].many
}
function Frac([double]$v){
  # friendly quantity: quarters for anything a quarter-unit or larger, 2 decimals below that so a
  # small amount never prints as a bare "0" (r100 shipped "Bay Leaves ... 0 oz").
  $r=[Math]::Round($v*4)/4
  if($r -lt 0.25){ if($v -le 0){ return '0' }; return ([Math]::Max([Math]::Round($v,2),0.01)).ToString('0.##') }
  if($r -eq [Math]::Floor($r)){ return ([string][int]$r) }
  return $r.ToString('0.##')
}
# Items a shopper buys BY WEIGHT. Nobody scoops cups of turkey breast, kale or mushrooms into a cart
# (r100's cup fallback printed "Turkey Breast: 14.25 cups" - writer-wave finding).
$WEIGHT_MEAT   = 'Chicken|Beef|Turkey|Pork|Sausage|Chorizo|Bacon|\bHam\b|Brisket|Liver|Bratwurst|Lamb|Veal'
$WEIGHT_FIRST  = 'Kale|Spinach|Cabbage|Mushrooms|Broccoli|Brussels|Sprouts|Green Beans|Snow Peas|Zucchini|Eggplant|Cauliflower|Collard|Bok Choy|Asparagus|Okra|Squash|Peas$|Corn$'
# names that CONTAIN a meat word but are not sold as meat (r100 printed "Chicken Broth: 4.25 lb")
$NOT_MEAT = 'Broth|Stock|Soup|Bouillon|Seasoning|Powder|Sauce|Gravy|Rub|Bacon Bits'
function FriendlyAmt([string]$item,[double]$g){
  if($item -match 'Broth|Stock'){
    $cartons = Den $item 'carton'
    if($cartons -and $g -ge ($cartons*0.85)){ $n=[Math]::Round($g/$cartons,1); if([Math]::Abs($n-[Math]::Round($n)) -lt 0.15){ $n=[Math]::Round($n) }; return ("$n carton" + $(if($n -ne 1){'s'})) }
    return ((Frac ($g/240.0)) + ' cups')
  }
  if($item -match $WEIGHT_MEAT -and $item -notmatch $NOT_MEAT){ return ((Frac ($g/$LB)) + ' lb') }
  if($item -eq 'Rice'){ return ((Frac ($g/185.0)) + ' cups dry') }
  if($item -eq 'Eggs'){ return ([string][int][Math]::Round($g/50.0) + ' large eggs') }
  if($item -match 'Pasta|Spaghetti|Ziti|Fettuccine|Orzo|Noodles|Gnocchi|Tortellini|Shells'){ return ((Frac ($g/$OZ)) + ' oz dry') }
  if($item -match 'Cheese|Mozzarella|Cheddar|Feta|Parmesan|Ricotta'){ return ((Frac ($g/$OZ)) + ' oz') }
  $can = Den $item 'can'
  if($can -and $g -ge ($can*0.85)){ $n=[Math]::Round($g/$can,1); if([Math]::Abs($n-[Math]::Round($n)) -lt 0.15){ $n=[Math]::Round($n) }; return ("$n can" + $(if($n -ne 1){'s'})) }
  $each = Den $item 'each'
  if($each -and $each -ge 40 -and $g -ge ($each*0.6)){ $n=[Math]::Round($g/$each,1); if([Math]::Abs($n-[Math]::Round($n)) -lt 0.25){ $n=[Math]::Round($n) }; return ("$n " + (EachNoun $item $n)) }
  if($item -match $WEIGHT_FIRST -or $item -match $WEIGHT_MEAT){
    if($g -ge $LB){ return ((Frac ($g/$LB)) + ' lb') }
    return ((Frac ($g/$OZ)) + ' oz')
  }
  $tb = Den $item 'tbsp'
  if($tb -and $g -lt 120){ return ((Frac ($g/$tb)) + ' tbsp') }
  $cup = Den $item 'cup'
  if($cup){ return ((Frac ($g/$cup)) + ' cups') }
  return ((Frac ($g/$OZ)) + ' oz')
}
function GpuStr([double]$v){ $v.ToString('0.000') }
function Plural([string]$label,[int]$n){
  if($n -le 1){ return $label }
  if($label -match '(?i)each$'){ return $label }            # "Buy 3 each", never "3 eachs"
  if($label -match '(?i)(ch|sh|ss|s|x|z)$'){ return ($label + 'es') }
  return ($label + 's')
}

# ---------------- parallel ingredient arrays ----------------
$display=@(); $scalerIng=@(); $gramsArr=@(); $notPriced=@()
foreach($ing in $intake.ingredients){
  $item = [string]$ing.item
  $g = [int][Math]::Round([double]$ing.grams,0)
  if($g -le 0){ throw ("zero/negative grams on '$item' - intake must not carry zero-gram rows") }
  $dispItem = if((IProp $ing 'display_name') -and $ing.display_name){ [string]$ing.display_name } else { $item }
  $buy = if((IProp $ing 'buy') -and $ing.buy){ [string]$ing.buy } else { FriendlyAmt $item $g }
  # brand paren from the food DB (same filter as r300 build-specs); a renamed ingredient carries its
  # own parenthetical - a second brand paren would read as nonsense and the brand belongs to the
  # canonical item, not the reader-facing name
  $brand = ''
  $d = $dbm[$item]
  if($d -and (IProp $d 'brand') -and $d.brand -and $d.brand -notmatch '^fresh$|store'){ $brand = ' (' + (($d.brand -split '/')[0].Trim()) + ')' }
  if($dispItem -ne $item){ $brand = '' }
  $display += ('<strong>' + $dispItem + $brand + ':</strong> ' + $buy + ' (' + $g + ' g)')
  $gramsArr += [pscustomobject]@{ item=$item; grams=$g }
  # scaler entry: item is reader-facing, canon is the machine identity (r300 convention)
  $se = [ordered]@{ item=$dispItem; canon=$item; grams=$g; buy=$buy }
  if($ITEMS.ContainsKey($item) -and (IProp $ITEMS[$item] 'bid') -and $ITEMS[$item].bid){
    $mrow = $ITEMS[$item]
    $se.bid = [string]$mrow.bid
    $se.gpu = GpuStr (Resolve-ScalerGpu $item ([string]$mrow.bid) ([double]$mrow.gpu) $(if(IProp $mrow 'unit'){ [string]$mrow.unit } else { '' }))
  } else {
    $notPriced += $item   # widget will show "not price-tracked" - allowed, but surfaced
  }
  $scalerIng += [pscustomobject]$se
}
if(@($display).Count -ne @($scalerIng).Count -or @($display).Count -ne @($gramsArr).Count){
  throw ("parallel array bug: display {0} / scaler {1} / grams {2}" -f @($display).Count,@($scalerIng).Count,@($gramsArr).Count)
}

# ---- CHEAPEST-FALLBACK guard (fail-fast at intake, same rule audit-db-agreement enforces) --------
if($feedKeys.Count -gt 0){
  $fallback=@()
  foreach($se in $scalerIng){
    if($se.PSObject.Properties.Name -notcontains 'bid'){ continue }
    $b=[string]$se.bid
    if($b -and -not $feedKeys.ContainsKey($b) -and -not $noBoardOk.ContainsKey($b)){ $fallback += ("'" + $se.canon + "' bid '" + $b + "'") }
  }
  if($fallback.Count -gt 0){
    throw ("CHEAPEST-FALLBACK: " + ($fallback -join '; ') + " not on the feed and not in no-board-price-ok.json - the live card would silently show cheapest == everyday. Fix the bid in db\ingredients.json or allowlist it.")
  }
}

# ---------------- stat + macro verification ----------------
$mac = $intake.macros_per_serving
foreach($k in @('calories','protein_g','carbs_g','fat_g')){ if($mac.PSObject.Properties.Name -notcontains $k){ throw ("macros_per_serving missing $k") } }
$stat = [ordered]@{
  cal     = [int][Math]::Round([double]$mac.calories,0)
  protein = [int][Math]::Round([double]$mac.protein_g,0)
  carbs   = [int][Math]::Round([double]$mac.carbs_g,0)
  fat     = [int][Math]::Round([double]$mac.fat_g,0)
  cost_ps = '0.00'
}
if(-not $SkipMacroCheck){
  $cal=0.0; $prot=0.0; $missing=@()
  foreach($ig in $gramsArr){
    if(-not $dbm.ContainsKey($ig.item)){ $missing += $ig.item; continue }
    $d=$dbm[$ig.item]; $f=$ig.grams/[double]$d.serving_grams
    $cal += $f*[double]$d.calories; $prot += $f*[double]$d.protein_g
  }
  if($missing.Count -gt 0){ throw ("items not in food-macros-db (add labels first, or -SkipMacroCheck): " + (($missing | Select-Object -Unique) -join ', ')) }
  $calPS=[Math]::Round($cal/14,0); $protPS=[Math]::Round($prot/14,0)
  if([Math]::Abs($calPS - $stat.cal) -gt 5){ throw ("stat cal {0} != DB recompute {1} (tolerance 5)" -f $stat.cal,$calPS) }
  if([Math]::Abs($protPS - $stat.protein) -gt 2){ throw ("stat protein {0} != DB recompute {1} (tolerance 2)" -f $stat.protein,$protPS) }
}
if($stat.cal -lt 550){ Write-Warning ("550 GATE: {0} cal/serving is under the house floor - spec-guards will fail this" -f $stat.cal) }
if($stat.protein -lt 25){ Write-Warning ("PROTEIN FLOOR: {0} g/serving is under 25 g - spec-guards will fail this" -f $stat.protein) }

# ---------------- prose ----------------
$prose = if(IProp $intake 'prose'){ $intake.prose } else { [pscustomobject]@{} }
function ProseStr([string]$k){ if((IProp $prose $k) -and $prose.$k){ [string]$prose.$k } else { '' } }
$introHtml   = ProseStr 'intro_html'
$portionHtml = ProseStr 'portion_html'
$closingHtml = ProseStr 'cost_closing_html'
$upsellHtml  = ProseStr 'upsell_html'
$costNote    = ProseStr 'cost_note_html'
if(-not $costNote){ $costNote = 'Real Omaha store prices from our weekly grocery board (2026). They still swing by store and by what is on sale.' }
$creditHtml  = ProseStr 'credit_html'
if(-not $creditHtml){
  $creditHtml = 'Recipe adapted from <a href="' + $srcUrl + '" target="_blank" rel="noopener">' + $srcSite + '</a>, rebuilt for 14-serving budget meal prep with weighed portions and Omaha pricing.'
}
# shop_smart is an HTML string on modern specs (a few legacy specs store an array; both render)
$shopSmart = if((IProp $prose 'shop_smart') -and $prose.shop_smart){ $prose.shop_smart } else { '' }
$makeIt    = @(); if((IProp $prose 'make_it') -and $prose.make_it){ $makeIt = @($prose.make_it) }
foreach($pk in @('intro_html','portion_html','cost_closing_html','upsell_html')){
  if(-not (ProseStr $pk)){ Write-Warning ("prose field empty: $pk (skeleton spec; the writer wave fills it before spec-guards full mode)") }
}

# ---------------- head ----------------
$hIn = if(IProp $intake 'head'){ $intake.head } else { [pscustomobject]@{} }
function HeadStr([string]$k){ if((IProp $hIn $k) -and $hIn.$k){ [string]$hIn.$k } else { '' } }
# head.recipeIngredient is DERIVED, never hand-typed (2026-08-04). It used to be taken from the intake
# file whenever a writer supplied one, with the derivation as a mere fallback - and a hand-typed list of
# quantities is prose, so it drifted: 507 of 513 live specs named fewer ingredients than the card, in
# package units the page never uses ("3 boxs Penne Pasta" against the card's "10 cups (1050 g)"). Google
# wants the markup to represent the visible page, so it is now generated FROM the visible page's own list.
# See head-ingredients-lib.ps1 for the measurement and the line shape.
#
# This SUPERSEDES the each-noun-aware fallback that used to live here (the "18.4 potatoes potato" fix):
# the derivation reads the display line, which already carries the count noun EachNoun put there, so the
# doubled-noun case it guarded against cannot arise. db\each-nouns.json still drives FriendlyAmt above.
$recipeIngredient = @(Get-HeadRecipeIngredient $display $scalerIng $dbm)
if((IProp $hIn 'recipeIngredient') -and $hIn.recipeIngredient){
  Write-Warning ('intake supplies head.recipeIngredient (' + @($hIn.recipeIngredient).Count + ' lines) - IGNORED; the JSON-LD list is derived from ingredients_display (' + $recipeIngredient.Count + ' lines) so the two cannot disagree')
}
$headSteps = @(); if((IProp $hIn 'steps') -and $hIn.steps){ $headSteps = @($hIn.steps | ForEach-Object { [string]$_ }) }
$head = [ordered]@{
  description      = HeadStr 'description'
  keywords         = HeadStr 'keywords'
  image            = HeadStr 'image'
  prepTime         = HeadStr 'prepTime'
  cookTime         = HeadStr 'cookTime'
  totalTime        = HeadStr 'totalTime'
  costPerServing   = 0
  recipeIngredient = $recipeIngredient
  steps            = $headSteps
}
if((IProp $hIn 'step_names') -and $hIn.step_names){ $head.step_names = @($hIn.step_names | ForEach-Object { [string]$_ }) }

# ---------------- cost fields (rendered from the costed row; math lives in cost-recipes.ps1) ------
function Get-CostedRow([string]$path,[string]$wantSlug){
  if(-not (Test-Path $path)){ return $null }
  $costed = Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json
  $cr = @($costed | Where-Object { ($_.PSObject.Properties.Name -contains 'slug') -and ([string]$_.slug -eq $wantSlug) })
  if($cr.Count -gt 1){ throw ("ambiguous costed rows for $wantSlug") }
  if($cr.Count -eq 1){ return $cr[0] }
  return $null
}
$costRow = Get-CostedRow $CostedFile $slug

$structuralOnly = $false
if(-not $costRow){
  if($RunCost){
    if((Resolve-Path $OutDir).Path -ne (Resolve-Path (Join-Path $mp 'db\recipes')).Path){
      throw '-RunCost only works when OutDir is the real db\recipes (cost-recipes reads specs from there)'
    }
    $structuralOnly = $true   # write the structural spec first, cost below, then re-render
  } elseif($AllowUncosted){
    Write-Warning 'no costed row - emitting zeroed cost fields. Run engine\cost-recipes.ps1 -Slugs then re-run this tool with -Force.'
  } else {
    throw ("no costed row for '$slug' in $CostedFile. Run: engine\cost-recipes.ps1 -Slugs $slug (or pass -RunCost to do it in one step, or -AllowUncosted for a two-phase manual flow).")
  }
}

$costFields = $null
function Render-CostFields($cost){
  # ported from r300 build-specs (deltas 4/6 kept): pantry fold is EXACTNESS-GATED, printed
  # contributions sum EXACTLY to the printed true cost.
  $costLines=@{}; foreach($l in $cost.lines){ $costLines[$l.item]=$l }
  # build-card2 self-test mirror: ceil(grams/pkg_g - 0.02) must equal the engine's buy_n
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    $pkgG = $null; $n = $null
    if($cl.buy_n -and $cl.pkg_g){ $pkgG=[double]$cl.pkg_g; $n=[int]$cl.buy_n }
    elseif($cl.starter_n -and $cl.starter_pkg_g){ $pkgG=[double]$cl.starter_pkg_g; $n=[int]$cl.starter_n }
    if($null -eq $pkgG -or $pkgG -le 0){ continue }
    $chk = [Math]::Max(1,[Math]::Ceiling([double]$ig.grams/$pkgG - 0.02))
    if($chk -ne $n){ throw ("SELF-TEST: {0} ceil({1}g/{2}g)={3} != engine buy_n {4} - spec grams and costed row disagree (stale costed.json? run cost-recipes -Slugs {5})" -f $ig.item,$ig.grams,$pkgG,$chk,$n,$slug) }
  }
  $costHtml=@(); $sumUtil=0.0; $sumTrue=0.0
  $pantryItems=@(); $pantryUtil=0.0; $foldSet=@{}
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]
    $util = 0.0; if($cl){ $util=[double]$cl.util_cost }
    $isSpice = ($ig.item -match 'Salt|Pepper$|Powder$|Paprika|Cumin|Coriander|Turmeric|Masala|Cinnamon|Cloves|Allspice|Nutmeg|Oregano|Thyme|Basil$|Dill|Parsley|Bay Leaves|Flakes|Seasoning$|Five-Spice|Cayenne|Italian Seasoning')
    $utilOnly = ($null -eq $cl) -or [bool]$cl.bulk -or (-not $cl.buy_cost)
    # "Pantry seasonings (chicken broth)" reads as a mistake (sopa-de-fideo, writer-wave finding)
    if($ig.item -match 'Broth|Stock|Milk|Cream$|Juice$'){ $isSpice = $false; $utilOnly = $false }
    if(($isSpice -or ($ig.grams -lt 15 -and $util -lt 0.15)) -and $utilOnly){
      $sc = $scalerIng | Where-Object { $_.canon -eq $ig.item } | Select-Object -First 1
      $pantryItems += ([string]$sc.item).ToLower(); $pantryUtil += $util; $foldSet[$ig.item]=1
    }
  }
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ig.item)){ continue }
    $util=[double]$cl.util_cost
    $sumUtil += $util
    $sc = $scalerIng | Where-Object { $_.canon -eq $ig.item } | Select-Object -First 1
    $amt = [string]$sc.buy
    $nm  = [string]$sc.item
    if($cl.bulk){
      $sumTrue += $util
      if($cl.starter_n -and [int]$cl.starter_n -ge 2 -and $cl.starter_pkg){
        $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Pantry staple; this batch alone uses about ' + [int]$cl.starter_n + ' ' + (Plural ([string]$cl.starter_pkg) ([int]$cl.starter_n)) + '.</strong>')
      } else {
        $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy 1 (lasts several batches).</strong>')
      }
    } elseif($cl.buy_cost){
      $sumTrue += [double]$cl.buy_cost
      $pkgTxt = $cl.pkg; if(-not $pkgTxt){ $pkgTxt='pack' }
      $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy ' + $cl.buy_n + ' ' + (Plural $pkgTxt ([int]$cl.buy_n)) + ': $' + ([double]$cl.buy_cost).ToString('0.00') + '.</strong>')
    } else {
      $sumTrue += $util
      $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy as needed.</strong>')
    }
  }
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ig.item)){ $sumUtil += [double]$cl.util_cost; $sumTrue += [double]$cl.util_cost }
  }
  if($pantryItems.Count -gt 0){
    $pl = ($pantryItems | Select-Object -Unique) -join ', '
    $costHtml += ('Pantry seasonings (' + $pl + '): ~$' + $pantryUtil.ToString('0.00') + '. <strong>From jars you keep on hand.</strong>')
  }
  $batch=[Math]::Round($sumUtil,2); $trueC=[Math]::Round($sumTrue,2)
  $cps = [Math]::Round($batch/14,2); $cpsTrue=[Math]::Round($trueC/14,2)
  $pantryAdd=[double]$cost.cost_pantry_add; $firstRun=[double]$cost.cost_first_run
  # exactness cross-checks against the engine's own totals (never render numbers that disagree)
  if([Math]::Abs($batch-[double]$cost.cost_batch) -gt 0.005){ throw ($slug + ': rendered batch ' + $batch + ' != engine ' + $cost.cost_batch + ' (missing/extra ingredient vs the costed row?)') }
  if([Math]::Abs($trueC-[double]$cost.cost_batch_true) -gt 0.005){ throw ($slug + ': rendered true ' + $trueC + ' != engine ' + $cost.cost_batch_true) }
  if([Math]::Abs(($trueC+$pantryAdd)-$firstRun) -gt 0.005){ throw ($slug + ': first_run ' + $firstRun + ' != true+add ' + ($trueC+$pantryAdd)) }
  $costHtml += ('<strong>Batch total: about $' + $batch.ToString('0.00') + ' across 14 servings, so roughly $' + $cps.ToString('0.00') + ' per bowl.</strong> This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.')
  $costHtml += ('<strong>True shopping cost: about $' + $trueC.ToString('0.00') + ' across 14 servings, roughly $' + $cpsTrue.ToString('0.00') + ' per bowl.</strong> What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.')
  if($pantryAdd -gt 0){
    $costHtml += ('<strong>Starting with an empty pantry? Add about $' + $pantryAdd.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.')
  }
  @{ lines=@($costHtml); batch=$batch; trueC=$trueC; cps=$cps; cpsTrue=$cpsTrue; pantryAdd=[Math]::Round($pantryAdd,2); firstRun=[Math]::Round($firstRun,2) }
}
if($costRow){ $costFields = Render-CostFields $costRow }

# ---- everyday per-serving basis (2026-07-26 cost redesign): stat.cost_ps + head.costPerServing carry
# the EVERYDAY whole-package per-serving from the v2-perserving manifest, not cost_batch/14. For a
# brand-new recipe the manifest row does not exist yet - fall back to the batch cps and note that
# compute-v2-perserving + reanchor-machine-fields (the normal post-cost steps) will stamp the real one.
$everydayPs = $null
if(Test-Path $ManifestFile){
  $manRow = @((Get-Content $ManifestFile -Raw -Encoding utf8 | ConvertFrom-Json) | Where-Object { [string]$_.slug -eq $slug })
  if($manRow.Count -eq 1 -and $manRow[0].everyday_ps){ $everydayPs = [double]$manRow[0].everyday_ps }
}
if($null -eq $everydayPs -and $costRow){
  Write-Warning 'no v2-perserving manifest row - stat.cost_ps falls back to batch/14; run compute-v2-perserving.ps1 + reanchor-machine-fields.ps1 after costing to stamp the everyday basis'
}

# ---------------- assemble + write ----------------
function Build-Spec($cf){
  $tuningArr = @(); if(IProp $intake 'tuning'){ $tuningArr = @($intake.tuning) }
  $spec = [ordered]@{
    name        = [string]$intake.name
    slug        = $slug
    cuisine     = [string]$intake.cuisine
    protein     = [string]$intake.protein
    servings    = 14
    visibility  = $visibility
    source_url  = $srcUrl
    source_site = $srcSite
    manual_balance = [bool]$(if(IProp $intake 'manual_balance'){ $intake.manual_balance } else { $false })
    tuning      = $tuningArr
  }
  if(IProp $intake 'writer_notes'){ $spec.writer_notes = @($intake.writer_notes) }
  if(IProp $intake 'forbidden_prose_terms'){ $spec.forbidden_prose_terms = @($intake.forbidden_prose_terms) }
  $psShow = if($null -ne $everydayPs){ $everydayPs } elseif($cf){ $cf.cps } else { $null }
  $statOut = [ordered]@{ cal=$stat.cal; protein=$stat.protein; carbs=$stat.carbs; fat=$stat.fat; cost_ps=$(if($null -ne $psShow){ $psShow.ToString('0.00') } else { '0.00' }) }
  $spec.stat = $statOut
  $spec.intro_html = $introHtml
  $spec.ingredients_display = @($display)
  $spec.cost_note_html = $costNote
  $spec.cost_lines = @($(if($cf){ $cf.lines } else { @() }))
  $spec.cost_closing_html = $closingHtml
  $spec.shop_smart = $shopSmart
  $spec.make_it = @($makeIt)
  $spec.portion_html = $portionHtml
  $spec.credit_html = $creditHtml
  $spec.upsell_html = $upsellHtml
  $spec.cost_batch            = $(if($cf){ $cf.batch }     else { 0 })
  $spec.cost_batch_true       = $(if($cf){ $cf.trueC }     else { 0 })
  $spec.cost_per_serving      = $(if($cf){ $cf.cps }       else { 0 })
  $spec.cost_per_serving_true = $(if($cf){ $cf.cpsTrue }   else { 0 })
  $spec.cost_pantry_add       = $(if($cf){ $cf.pantryAdd } else { 0 })
  $spec.cost_first_run        = $(if($cf){ $cf.firstRun }  else { 0 })
  $spec.scaler = [ordered]@{ cost=$(if($cf){ $cf.trueC.ToString('0.00') } else { '0.00' }); ing=@($scalerIng) }
  $head.costPerServing = $(if($null -ne $psShow){ [Math]::Round($psShow,2) } else { 0 })
  $spec.head = $head
  $spec.ingredients_grams = @($gramsArr)
  return $spec
}
function Test-Dashes($spec){
  # em/en dash sweep over EVERY string (Brad's rule; spec-guards enforces the same)
  $q=New-Object System.Collections.Generic.Queue[object]
  $q.Enqueue($spec)
  while($q.Count -gt 0){
    $v=$q.Dequeue()
    if($null -eq $v){ continue }
    if($v -is [string]){
      if($v -match [char]0x2014){ throw ('EM DASH in spec text: ' + $v.Substring(0,[Math]::Min(70,$v.Length))) }
      if($v -match [char]0x2013){ throw ('EN DASH in spec text: ' + $v.Substring(0,[Math]::Min(70,$v.Length))) }
      continue
    }
    if($v -is [System.Collections.IDictionary]){ foreach($vv in $v.Values){ $q.Enqueue($vv) }; continue }
    if($v -is [System.Collections.IEnumerable]){ foreach($vv in $v){ $q.Enqueue($vv) }; continue }
    if($v -is [psobject] -and $v.PSObject.Properties.Count -gt 0){ foreach($p in $v.PSObject.Properties){ $q.Enqueue($p.Value) } }
  }
}
function Write-Spec($spec,[string]$path){
  Test-Dashes $spec
  if(-not (Test-Path (Split-Path -Parent $path))){ New-Item -ItemType Directory (Split-Path -Parent $path) -Force | Out-Null }
  $json = ConvertTo-Json -InputObject $spec -Depth 8
  $null = $json | ConvertFrom-Json    # parse-verify before writing, never ship a broken file
  [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

if($structuralOnly){
  # -RunCost flow: structural spec first so cost-recipes can read it, then cost, then final render
  Write-Spec (Build-Spec $null) $outFile
  Write-Output ("structural spec written; running engine\cost-recipes.ps1 -Slugs $slug ...")
  & (Join-Path $mp 'engine\cost-recipes.ps1') -Slugs @($slug)
  $costRow = Get-CostedRow $CostedFile $slug
  if(-not $costRow){ throw ("cost-recipes ran but no costed row appeared for $slug - check db\cost-flags.txt") }
  $costFields = Render-CostFields $costRow
}
Write-Spec (Build-Spec $costFields) $outFile

# ---------------- report ----------------
Write-Output ("spec written: " + $outFile)
Write-Output ("  ingredients: {0} (display/grams/scaler all {0})" -f @($scalerIng).Count)
if($costFields){ Write-Output ("  cost: batch ${0} true ${1} cps ${2} (rendered from {3})" -f $costFields.batch,$costFields.trueC,$costFields.cps,(Split-Path -Leaf $CostedFile)) }
else { Write-Output '  cost: UNCOSTED (zeroed) - run cost-recipes -Slugs then re-run with -Force' }
if($script:gpuFixes.Count -gt 0){ Write-Output ('  gpu unit-reconciled: ' + (($script:gpuFixes | Sort-Object -Unique) -join ' | ')) }
if($script:gpuFlags.Count -gt 0){ Write-Output ('  GPU UNIT FLAGS: ' + (($script:gpuFlags | Sort-Object -Unique) -join ' | ')) }
if($notPriced.Count -gt 0){ Write-Output ('  not price-tracked (no bid in db\ingredients.json): ' + (($notPriced | Select-Object -Unique) -join ', ')) }
