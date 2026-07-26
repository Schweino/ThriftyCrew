# cost-engine.ps1 (R300) - Everyday cost + TRUE shopping cost per recipe.
# PORT OF r100\cost-engine.ps1. Cost model is IDENTICAL:
#   batch total = EXACT sum of per-line util costs; per-serving = batch/14
#   true cost   = sum of per-line contributions where package items round UP to whole packages
#                 and bulk/pantry items stay at utilization; true >= batch always.
#   first run   = true cost + one-time pantry add (whole containers of every BULK staple)
# Price sources, in order: (1) weekly board Walmart everyday price (verified), (2) recipe-board,
# (3) smp-feed, (4) label package prices if any labels-*.json exist in r300\.
# R300 DELTAS (additive only):
#   * paths point at r300\ ; slug carried into every output record
#   * ONE merged item->board map (see Load-Map): meal-prep\ingredient-map.json (base)
#     <- r100\r100-board-map.json <- r300\mapper\map-extensions.json (wins on conflict).
#     The mapper stage may not have written map-extensions.json yet: that WARNS, never crashes.
#   * labels-*.json is a glob, not a fixed list - r300 has none yet, so it is simply skipped.
# Output: recipes-costed.json + cost-flags.txt (any item without a price basis = HARD FLAG, never guessed).
param([string[]]$Slugs)   # targeted recost: cost only these, splice into existing recipes-costed.json. Default unchanged.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$computed = Get-Content (Join-Path $here 'recipes-computed.json') -Raw | ConvertFrom-Json
if($Slugs){ $computed = @($computed | Where-Object { $Slugs -contains [string]$_.slug }); if($computed.Count -eq 0){ throw "no computed recipes match -Slugs" } }
$cmpFile = Get-ChildItem (Join-Path $here '..\..\grocery\out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison

$LB=453.592; $OZ=28.3495

# ---- MERGED ITEM -> BOARD MAP -------------------------------------------------------------------
# One lookup for the engine. Later sources overwrite earlier ones, so r300 extensions win.
# Accepts either shape: { map: { "<item>": {bid,unit,gpu} } }  or  { mappings: [ {item,board_id,grams_per_unit,unit} ] }
function Add-MapFile([hashtable]$acc,[string]$path,[string]$label,[switch]$Required){
  if(-not (Test-Path $path)){
    if($Required){ throw ("map file missing: " + $path) }
    Write-Warning ("map not found (skipped): " + $label + " -> " + $path)
    return 0
  }
  $raw = Get-Content $path -Raw | ConvertFrom-Json
  $n=0
  if($raw.map){
    foreach($p in $raw.map.PSObject.Properties){
      $acc[$p.Name] = @{ bid=[string]$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit; src=$label }; $n++
    }
  }
  if($raw.mappings){
    foreach($m in $raw.mappings){
      $acc[$m.item] = @{ bid=[string]$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit; src=$label }; $n++
    }
  }
  if(-not $raw.map -and -not $raw.mappings){ Write-Warning ("map file has neither .map nor .mappings: " + $path) }
  return $n
}
$itemBoard=@{}
$n1 = Add-MapFile $itemBoard (Join-Path $here '..\ingredient-map.json')      'ingredient-map'  -Required
$n2 = Add-MapFile $itemBoard (Join-Path $here '..\r100\r100-board-map.json') 'r100-board-map'  -Required
$n3 = Add-MapFile $itemBoard (Join-Path $here 'mapper\map-extensions.json')  'r300-extensions'
Write-Output ("map: ingredient-map {0} + r100 {1} + r300 ext {2} -> {3} distinct items" -f $n1,$n2,$n3,$itemBoard.Count)

# board rows by id -> walmart (preferred) or cheapest nomem price per unit (row UNIT kept for reconciliation)
$board=@{}
foreach($row in $cmp){
  $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  $p = $null; $src=''
  if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit; $src='walmart' }
  elseif($row.nomem_price -gt 0){ $p=[double]$row.nomem_price; $src=('nomem:'+$row.nomem_store) }
  if($p){ $board[$row.id] = @{ per_unit=$p; unit=[string]$row.unit; src=$src } }
}

# UNIT RECONCILIATION (2026-07-19, the brown-sugar 16x lesson): a map's gpu was calibrated against the
# board unit of ITS era; boards re-register commodities with new units (recipe-board oz -> weekly lb).
# For standard weight/volume units, rescale gpu to the CURRENT row unit; anything else must match exactly.
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
function Resolve-Gpu([double]$gpu,[string]$mapUnit,[string]$rowUnit){
  if(-not $mapUnit -or -not $rowUnit -or $mapUnit -eq $rowUnit){ return $gpu }
  if($UNIT_G.ContainsKey($mapUnit) -and $UNIT_G.ContainsKey($rowUnit)){ return $gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$mapUnit]) }
  return -1.0   # non-standard mismatch: caller must hard-flag
}

# recipe board (the 90-run's own verified per-store data; ids like pork-loin live ONLY here).
# Same walmart-preferred rule as the weekly board; never overrides a weekly-board id.
$rbFile = Join-Path $here '..\..\grocery\out\recipe-board.json'
if(Test-Path $rbFile){
  $rb = (Get-Content $rbFile -Raw | ConvertFrom-Json).comparison
  foreach($row in $rb){
    if($board.ContainsKey($row.id)){ continue }
    $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
    $p=$null; $src=''
    if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit; $src='recipeboard-walmart' }
    elseif($row.cheapest_price -gt 0){ $p=[double]$row.cheapest_price; $src=('recipeboard-cheapest:'+$row.cheapest_store) }
    if($p){ $board[$row.id] = @{ per_unit=$p; unit=$row.unit; src=$src } }
  }
}

# smp-feed (recipe-board ingredient prices, our own verified data - what the live widgets use)
$feed = (Get-Content (Join-Path $here '..\..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedMap=@{}
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.cheapest -gt 0){ $feedMap[$p.Name] = @{ per_unit=[double]$p.Value.cheapest; unit=$p.Value.unit } } } }

# pantry starter packages: whole-container size per BULK item (empty-pantry one-time stock-up)
$pantryPkg=@{}
foreach($p in ((Get-Content (Join-Path $here 'pantry-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){
  $pantryPkg[$p.Name] = @{ g=[double]$p.Value.g; label=[string]$p.Value.label }
}

# label package prices (agent-captured labels for untracked items): item -> pkg grams + price
function SizeToGrams([string]$s){
  $s=$s.ToLower()
  if($s -match '([\d.]+)\s*(fl\.? ?oz|floz)'){ return [double]$Matches[1]*29.57 }
  if($s -match '([\d.]+)\s*oz'){ return [double]$Matches[1]*$OZ }
  if($s -match '([\d.]+)\s*lb'){ return [double]$Matches[1]*$LB }
  if($s -match '([\d.]+)\s*kg'){ return [double]$Matches[1]*1000 }
  if($s -match '([\d.]+)\s*g\b'){ return [double]$Matches[1] }
  return $null
}
$labels=@{}
$labelFiles = @(Get-ChildItem (Join-Path $here 'labels-*.json') -ErrorAction SilentlyContinue | Sort-Object Name)
if($labelFiles.Count -eq 0){ Write-Warning "no labels-*.json in r300 yet - untracked items will hard-flag as NO PRICE BASIS" }
foreach($f in $labelFiles){
  foreach($r in (Get-Content $f.FullName -Raw | ConvertFrom-Json)){
    $nm = $r.item
    if($nm -match '^Pasta Shells'){ $nm='Pasta Shells' }
    if($nm -match '^Chili Crisp'){ $nm='Chili Crisp' }
    if($null -eq $r.package_price_usd -or $r.package_price_usd -le 0){ continue }
    $g = SizeToGrams ([string]$r.package_size)
    if(-not $g){ continue }
    if(-not $labels.ContainsKey($nm)){ $labels[$nm] = @{ pkg_g=$g; pkg_price=[double]$r.package_price_usd; desc=($r.brand + ' ' + $r.package_size) } }
    # r300: canon keeps distinct price-class items (e.g. 'Pasta Shells - jumbo') - register the raw
    # name too so the normalized fold above cannot orphan them.
    $rawNm = [string]$r.item
    if($rawNm -ne $nm -and -not $labels.ContainsKey($rawNm)){ $labels[$rawNm] = $labels[$nm] }
  }
}

# BULK/pantry items: counted at utilization in the true cost (one container covers several batches)
$BULK = @('Salt','Black Pepper','Garlic Powder','Onion Powder','Paprika','Smoked Paprika','Cayenne Pepper','Chili Powder','Ground Cumin','Ground Coriander','Ground Turmeric','Garam Masala','Curry Powder','Five-Spice Powder','Ground Cinnamon','Ground Cloves','Ground Allspice','Ground Nutmeg','Ground Ginger','Dried Oregano','Dried Thyme','Dried Basil','Dried Dill','Dried Parsley','Bay Leaves','Red Pepper Flakes','Italian Seasoning','Cajun Seasoning','Berbere Seasoning','Taco Seasoning','Fajita Seasoning','Ranch Seasoning Mix',
'Olive Oil','Vegetable Oil','Sesame Oil','White Vinegar','Red Wine Vinegar','Apple Cider Vinegar','Rice Vinegar','Balsamic Vinegar',
'Soy Sauce','Fish Sauce','Oyster Sauce','Worcestershire Sauce','Hoisin Sauce','Mirin','Sriracha','Hot Sauce','Ketchup','Dijon Mustard','BBQ Sauce','BBQ Sauce (Sugar Free)','Buffalo Wing Sauce','Honey','Hot Honey','Sugar-Free Maple Syrup','Gochujang','Chili Crisp','Tahini','Peanut Butter','Teriyaki Sauce','Lemongrass Paste','Pomegranate Molasses','Achiote Paste','Harissa Paste','Miso Paste','Sweet Chili Sauce','Liquid Smoke',
'All-Purpose Flour','Sugar','Brown Sugar','Cornstarch','Bread Crumbs','Rice','Grits','Lemon Juice','Lime Juice','Mayonnaise','Golden Raisins','Toasted Sesame Seeds','Poppy Seeds','Sun-Dried Tomatoes','Dill Pickles','Chicken Broth','Beef Broth','Red Wine','Butter Crackers','Chipotle in Adobo','Diced Green Chiles',
# R300 pantry staples (2026-07-25 stage-4 close-out): dried chiles, new spice jars, baking goods, and
# jarred/bottled condiments from the 49 new items - one container covers several batches, so they take
# the utilization path in true cost. Every one has a pantry-packages.json entry except Jerk Seasoning
# (no sourced container size anywhere - deliberately left flagging rather than guessed).
'Dried Ancho Chiles','Dried Guajillo Chiles','Dried Arbol Chiles','Poultry Seasoning','Caraway Seeds','Ground Fennel','Jerk Seasoning','Sazon Seasoning','Sumac','Cocoa Powder','Baking Powder','Baking Soda','Sweet Soy Sauce','Doubanjiang','Aji Amarillo Paste','Horseradish Sauce','Brown Gravy Mix','Onion Soup Mix','Capers','Pepperoncini')

# package definitions for board-priced items (grams per package + how price maps)
# board price is per unit (lb/oz/floz/each/dozen); package = typical Walmart pack.
$PKG = @{
  # --- orig-113 additions (2026-07-26): package defs for original-catalog items missing from the r300 table ---
  'Fat Free Cheddar'=@{g=227;label='8oz bag'}; 'Cheddar Cheese'=@{g=227;label='8oz block'}; 'Mozzarella Cheese'=@{g=227;label='8oz bag'}; 'Provolone Cheese'=@{g=227;label='8oz pack'}
  'Shredded Carrots'=@{g=283;label='10oz bag'}; 'Spinach'=@{g=283;label='10oz bag'}; 'Frozen Peas'=@{g=340;label='12oz bag'}; 'Green Bell Pepper'=@{g=119;label='each'}; 'Shallots'=@{g=$LB;label='lb'}
  'Panko Breadcrumbs'=@{g=227;label='8oz box'}; 'Corn Tortillas'=@{g=750;label='30ct pack'}
  'Honey Dijon Mustard'=@{g=340;label='12oz bottle'}; 'White Wine Vinegar'=@{g=500;label='16.9floz bottle'}; 'Green Chile Sauce'=@{g=454;label='16oz can'}; 'Green Olives'=@{g=163;label='5.75oz jar'}
  'Turkey Pepperoni'=@{g=142;label='5oz pack'}; 'Turkey Bacon'=@{g=340;label='12oz pack'}
  'Plain Yogurt'=@{g=907;label='32oz tub'}; 'Half and Half'=@{g=473;label='pint'}; 'Pineapple Juice'=@{g=1360;label='46floz can'}; 'Apple Cider'=@{g=1890;label='64floz jug'}
  'Condensed French Onion Soup'=@{g=298;label='10.5oz can'}; 'Au Jus Gravy Mix'=@{g=28;label='1oz packet'}
  'Dried Rosemary'=@{g=20;label='0.7oz jar'}; 'Celery Salt'=@{g=142;label='5oz canister'}; 'Orange Zest'=@{g=131;label='each'}
  # --- end orig-113 additions ---
  'Boneless Skinless Chicken Breast'=@{g=$LB;label='lb'}; 'Boneless Skinless Chicken Thigh'=@{g=$LB;label='lb'}
  '93/7 Ground Beef'=@{g=$LB;label='lb'}; '93/7 Ground Turkey'=@{g=$LB;label='lb'}; 'Ground Pork'=@{g=$LB;label='lb'}
  'Pork Chops'=@{g=$LB;label='lb'}; 'Pork Tenderloin'=@{g=$LB;label='lb'}; 'Pork Loin'=@{g=$LB;label='lb'}
  'Hot Italian Sausage'=@{g=$LB;label='lb'}; 'Hickory Smoked Bacon'=@{g=$LB;label='lb'}
  'Eggs'=@{g=600;label='dozen'}
  'Butter'=@{g=$LB;label='lb box'}
  'Heavy Cream'=@{g=473;label='pint'}
  'Milk'=@{g=3785;label='gallon'}
  'Light Sour Cream'=@{g=454;label='16oz tub'}
  'Greek Yogurt'=@{g=907;label='32oz tub'}
  '1/3 Fat Cream Cheese'=@{g=227;label='8oz brick'}
  'Cheddar Cheese, Shredded'=@{g=227;label='8oz bag'}; 'Reduced Fat Mozzarella'=@{g=227;label='8oz bag'}
  'Mexican Cheese Blend'=@{g=227;label='8oz bag'}; 'Feta Cheese'=@{g=170;label='6oz tub'}
  'Parmesan Cheese'=@{g=227;label='8oz tub'}; 'Cottage Cheese'=@{g=680;label='24oz tub'}
  'Penne Pasta'=@{g=454;label='16oz box'}; 'Rotini Pasta'=@{g=454;label='16oz box'}
  'Spaghetti'=@{g=454;label='16oz box'}; 'Ziti Pasta'=@{g=454;label='16oz box'}
  'Fettuccine'=@{g=454;label='16oz box'}; 'Orzo Pasta'=@{g=454;label='16oz box'}
  'Pasta Shells'=@{g=340;label='12oz box'}; 'Egg Noodles'=@{g=340;label='12oz bag'}
  'Frozen Hash Browns'=@{g=737;label='26oz bag'}
  'Potato'=@{g=$LB;label='lb'}; 'Sweet Potatoes'=@{g=$LB;label='lb'}
  'Yellow Onion'=@{g=$LB;label='lb'}; 'Red Onion'=@{g=$LB;label='lb'}; 'Jalapeno'=@{g=$LB;label='lb'}
  'Green Onions'=@{g=90;label='bunch'}; 'Cucumber'=@{g=300;label='each'}; 'Celery'=@{g=450;label='bunch'}
  'Fresh Cilantro'=@{g=57;label='bunch'}
  'Carrots'=@{g=$LB;label='lb'}; 'Zucchini'=@{g=$LB;label='lb'}; 'Green Cabbage'=@{g=900;label='head'}
  'Green Bell Peppers'=@{g=120;label='each'}; 'Red Bell Pepper'=@{g=120;label='each'}; 'Poblano Peppers'=@{g=$LB;label='lb'}
  'White Mushrooms'=@{g=227;label='8oz pack'}; 'Broccoli Florets'=@{g=340;label='12oz bag'}
  'Frozen Chopped Spinach'=@{g=284;label='10oz box'}; 'Frozen Green Peas'=@{g=340;label='12oz bag'}; 'Green Beans'=@{g=340;label='12oz bag'}
  'Cherry Tomatoes'=@{g=283;label='10oz clamshell'}
  'Diced Tomatoes'=@{g=411;label='can'}; 'Crushed Tomatoes'=@{g=794;label='28oz can'}; 'Tomato Sauce'=@{g=425;label='15oz can'}
  'Tomato Paste'=@{g=170;label='6oz can'}; 'Diced Tomatoes & Green Chilies'=@{g=283;label='10oz can'}
  'Sweet Whole Kernel Corn'=@{g=432;label='can'}; 'Seasoned Black Beans'=@{g=425;label='can'}; 'Kidney Beans'=@{g=425;label='can'}
  'Chickpeas'=@{g=425;label='can'}; 'Cannellini Beans'=@{g=425;label='can'}; 'Hominy'=@{g=425;label='can'}
  'Coconut Milk'=@{g=400;label='13.5oz can'}; 'Enchilada Sauce'=@{g=283;label='10oz can'}
  'Marinara Sauce'=@{g=680;label='24oz jar'}; 'Traditional Pasta Sauce'=@{g=680;label='24oz jar'}; 'Alfredo Sauce'=@{g=425;label='15oz jar'}
  'Salsa'=@{g=454;label='16oz jar'}; 'Salsa Verde'=@{g=454;label='16oz jar'}
  'Olives'=@{g=170;label='6oz can'}; 'Roasted Red Peppers'=@{g=340;label='12oz jar'}; 'Pineapple Chunks'=@{g=567;label='20oz can'}
  'Tomatillos'=@{g=$LB;label='lb'}; 'Hummus'=@{g=283;label='10oz tub'}
  'Tortilla'=@{g=300;label='10ct pack'}
  'Frozen Green Peas '=@{g=340;label='bag'}
  'Fresh Basil'=@{g=14;label='0.5oz pack'}; 'Fresh Mint'=@{g=14;label='0.5oz pack'}
  'Walnuts'=@{g=227;label='8oz bag'}; 'Peanuts'=@{g=454;label='16oz jar'}; 'Cashews'=@{g=227;label='8oz can'}
  'Garlic'=@{g=40;label='head'}; 'Ginger'=@{g=100;label='piece'}
  'Potato Gnocchi'=@{g=499;label='17.6oz pack'}; 'Cheese Tortellini'=@{g=539;label='19oz bag'}
  'Rice Noodles'=@{g=397;label='14oz box'}; 'Lo Mein Noodles'=@{g=397;label='14oz pack'}
  'Pork Chorizo'=@{g=255;label='9oz tube'}; 'Smoked Turkey Sausage'=@{g=368;label='13oz rope'}
  'Ricotta Cheese'=@{g=425;label='15oz tub'}
  'Refrigerated Biscuits'=@{g=462;label='8ct can'}; 'Corn Muffin Mix'=@{g=241;label='box'}
  'Corn Chips'=@{g=262;label='9.25oz bag'}; 'Grits'=@{g=680;label='24oz canister'}
  'Japanese Curry Roux'=@{g=92;label='3.2oz box'}; 'Red Curry Paste'=@{g=113;label='4oz jar'}
  'Mole Paste'=@{g=234;label='8.25oz jar'}; 'Golden Raisins '=@{g=340;label='bag'}
  'Sugar-Free Maple Syrup '=@{g=340;label='bottle'}; 'Swiss Cheese'=@{g=227;label='8oz'}
  'Orange Juice'=@{g=1560;label='52floz carton'}
  # ---- R300 package defs (2026-07-25 stage-4 close-out). REAL sizes only; source per entry:
  # [board] = size field on the captured comparison/recipe-board row; [wm-raw] = walmart-r300-raw.txt
  # capture; [wl] = board-capture-worklist typical_size; [gpu] = mapper decisions.json per-each base;
  # [dir] = coordinator-specified (turkey breast 3lb Butterball, cream soups 10.5oz).
  'Turkey Breast'=@{g=1361;label='3lb frozen roast'}          # [dir]+[wm-raw] Butterball 3 lb
  'Beef Chuck Roast'=@{g=$LB;label='lb'}                      # meat by the pound (r100 convention)
  'Pork Shoulder'=@{g=$LB;label='lb'}
  'Beef Flank/Sirloin Steak'=@{g=$LB;label='lb'}
  'Corned Beef Brisket'=@{g=$LB;label='lb'}
  'Bratwurst'=@{g=539;label='19oz 5-pack'}                    # [board] Johnsonville 19 oz
  'Diced Ham'=@{g=454;label='16oz pack'}                      # [board]/[wm-raw] Farmland 16 oz
  'Chicken Livers'=@{g=567;label='1.25lb tub'}                # [wm-raw] Tyson 1.25 lb
  'Cream of Mushroom Soup'=@{g=298;label='10.5oz can'}        # [dir]+[board]
  'Cream of Chicken Soup'=@{g=298;label='10.5oz can'}         # [dir]+[board]
  'Tater Tots'=@{g=2268;label='80oz bag'}                     # [board] captured 80 oz
  'Stuffing Mix'=@{g=170;label='6oz box'}                     # [board]
  'Wild Rice'=@{g=454;label='16oz bag'}                       # [board]/[wm-raw] MN cultivated 16 oz
  'Rye Bread'=@{g=683;label='24oz loaf'}                      # [board]/[wm-raw] GV NY rye 24 oz
  'Sandwich Bread'=@{g=567;label='20oz loaf'}                 # [gpu] bread each = 567 g loaf
  'Sauerkraut'=@{g=411;label='14.5oz can'}                    # [board]
  'Kale'=@{g=250;label='bunch'}                               # [gpu] kale each = 250 g bunch
  'Eggplant'=@{g=548;label='each'}                            # [gpu] eggplant each = 548 g
  'Snow Peas'=@{g=227;label='8oz bag'}                        # [board]/[wm-raw] Marketside 8 oz
  'Brussels Sprouts'=@{g=$LB;label='lb'}                      # [board] sold by lb
  'Artichoke Hearts'=@{g=391;label='13.8oz can'}              # [board]
  'Pumpkin Puree'=@{g=822;label='29oz can'}                   # [board]
  'Pigeon Peas'=@{g=425;label='15oz can'}                     # [board]/[wm-raw] GOYA 15 oz
  'Baked Beans'=@{g=794;label='28oz can'}                     # [board]
  'Basil Pesto'=@{g=624;label='22oz jar'}                     # [board] captured 22 oz
  'Apple'=@{g=175;label='each'}                               # [gpu] apple each = 175 g
  'Apple Juice'=@{g=1893;label='64floz bottle'}               # [board] 64 fl oz
  'Blackberries'=@{g=170;label='6oz clamshell'}               # [board]
  'Fries'=@{g=907;label='32oz bag'}                           # [board] frozen-fries row 32 oz
  'Zero-Sugar Soda'=@{g=2000;label='2L bottle'}               # [board] zero-sugar-soda-2l row
  'Gingersnap Cookies'=@{g=312;label='11oz box'}              # [board] cookies row 11 oz
  'Almonds'=@{g=397;label='14oz bag'}                         # [board]
}

# ---- DRAINED-BASIS RECONCILIATION (2026-07-25, writer-wave finding) -----------------------------
# parse-compute weighs canned beans/hominy in DRAINED grams (densities.json 'can' = drained grams per
# can, because the food DB's macros are per drained gram). The board, however, prices the can by its
# NET label weight (15 oz = 425 g incl. liquid), and $PKG carried that same net figure. Both halves of
# the cost were therefore on the wrong basis:
#   * util  = drained_g x price-per-NET-gram  -> understated a can by net/drained (1.67x for beans)
#   * buy_n = ceil(drained_g / NET pack g)    -> "5.6 cans ... Buy 4 cans", i.e. a shopper comes home
#             with too few cans (32 lines across the 300 before this fix)
# Fix: for any item that has BOTH a $PKG net size and a smaller densities 'can' yield, price per
# DRAINED gram (ppg x net/drained) and round packages on the DRAINED yield. One can then costs exactly
# its shelf price on both sides, and the displayed "N cans" and the "Buy N cans" agree by construction.
# Derived, not hardcoded, so new canned items inherit it automatically.
$dnm=@{}
foreach($p in ((Get-Content (Join-Path $here 'densities.json') -Raw | ConvertFrom-Json).items).PSObject.Properties){ $dnm[$p.Name]=$p.Value }
$DRAINED=@{}
foreach($n in $PKG.Keys){
  if(-not $dnm.ContainsKey($n)){ continue }
  $props=$dnm[$n].PSObject.Properties.Name
  if($props -notcontains 'can'){ continue }
  $canG=[double]$dnm[$n].can
  if($canG -gt 0 -and $canG -lt ([double]$PKG[$n].g * 0.95)){ $DRAINED[$n]=@{ net=[double]$PKG[$n].g; drained=$canG } }
}
if($DRAINED.Count -gt 0){
  Write-Output ("drained-basis items (priced + packed on drained yield): " + (($DRAINED.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Key + ' ' + $_.Value.drained + '/' + $_.Value.net + 'g' }) -join '; '))
}

# allowlist of bids with no first-party Omaha board price (priced via register-estimate label; see
# no-board-price-ok.json). Suppresses the MAPPED-BID-NOT-ON-BOARD advisory for exactly these.
$noBoardOk=@{}
$nbFile = Join-Path $here 'no-board-price-ok.json'
if(Test-Path $nbFile){ foreach($b in (Get-Content $nbFile -Raw | ConvertFrom-Json).bids){ $noBoardOk[[string]$b]=1 } }
$script:registerEst=0
$out=@(); $costFlags=New-Object System.Collections.Generic.List[string]
foreach($r in $computed){
  $lines=@(); $batch=0.0; $trueCost=0.0; $bulkUtil=0.0; $starterOutlay=0.0
  foreach($ing in $r.ingredients){
    $g=[double]$ing.grams
    if($g -le 0){ continue }
    $ppg=$null; $basis=''
    if($itemBoard.ContainsKey($ing.item)){
      $b=$itemBoard[$ing.item]
      if($board.ContainsKey($b.bid)){
        $eg = Resolve-Gpu $b.gpu $b.unit $board[$b.bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $b.unit + ' vs ' + $board[$b.bid].unit)); continue }
        $ppg = $board[$b.bid].per_unit / $eg; $basis=('board:'+$b.bid+':'+$board[$b.bid].src)
      }
      elseif($feedMap.ContainsKey($b.bid)){
        $eg = Resolve-Gpu $b.gpu $b.unit $feedMap[$b.bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $b.unit + ' vs feed ' + $feedMap[$b.bid].unit)); continue }
        $ppg = $feedMap[$b.bid].per_unit / $eg; $basis=('feed:'+$b.bid)
      }
      elseif($noBoardOk.ContainsKey($b.bid)){ $script:registerEst++ }  # known no-Omaha-price; label fallback (below) prices it, no false alarm
      else { $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: MAPPED BID NOT ON ANY BOARD (' + $b.bid + ', map ' + $b.src + ')')) }
    }
    if($null -eq $ppg -and $labels.ContainsKey($ing.item)){
      $L=$labels[$ing.item]; $ppg = $L.pkg_price/$L.pkg_g; $basis=('label:'+$L.desc)
    }
    if($null -eq $ppg){
      $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: NO PRICE BASIS')); continue
    }
    # drained-basis items: the board price is per NET gram, the recipe grams are drained
    if($DRAINED.ContainsKey($ing.item)){
      $dr=$DRAINED[$ing.item]
      $ppg = $ppg * ($dr.net/$dr.drained)
      $basis = $basis + '+drained'
    }
    $util = [Math]::Round($g*$ppg,2)
    $batch += $util
    $isBulk = $BULK -contains $ing.item
    $buyN=$null; $buyCost=$null; $pkgLabel=$null; $stN=$null; $stCost=$null; $stPkg=$null; $pkgG=$null; $stPkgG=$null
    if($isBulk){
      $trueCost += $util
      # empty-pantry starter: whole container(s) of this staple at the same price basis
      if($pantryPkg.ContainsKey($ing.item)){
        $pp=$pantryPkg[$ing.item]
        $stN=[Math]::Ceiling(($g/$pp.g) - 0.02); if($stN -lt 1){ $stN=1 }
        $stCost=[Math]::Round($stN*$pp.g*$ppg,2)
        if($stCost -lt $util){ $stCost=$util }
        $stPkg=$pp.label; $stPkgG=[double]$pp.g
        $bulkUtil += $util; $starterOutlay += $stCost
      } else {
        # never guess: a bulk item without a pantry package is a hard flag, counted at util
        $bulkUtil += $util; $starterOutlay += $util
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: BULK ITEM WITHOUT PANTRY PACKAGE DEF'))
      }
    } else {
      # package rounding
      $pg=$null
      if($PKG.ContainsKey($ing.item)){ $pg=$PKG[$ing.item] }
      elseif($labels.ContainsKey($ing.item)){ $pg=@{g=$labels[$ing.item].pkg_g; label=$labels[$ing.item].desc} }
      if($pg){
        # a drained-basis package holds $drained grams of usable food; both the price and the count
        # must be figured on that yield or the shopper is sent home with too few cans
        $pgG = [double]$pg.g
        if($DRAINED.ContainsKey($ing.item)){ $pgG = $DRAINED[$ing.item].drained }
        $pkgG = $pgG   # emit the EXACT package grams the engine rounds on (drained-adjusted) - the card widget re-scales on this
        $pkgPrice = $pgG*$ppg
        $buyN = [Math]::Ceiling(($g/$pgG) - 0.02)   # 2% tolerance for rounding noise
        if($buyN -lt 1){ $buyN = 1 }
        $buyCost = [Math]::Round($buyN*$pkgPrice,2)
        if($buyCost -lt $util){ $buyCost = $util }
        $trueCost += $buyCost
        $pkgLabel = $pg.label
      } else {
        $trueCost += $util
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: no package def, counted at util in true cost'))
      }
    }
    $lines += [pscustomobject]@{ item=$ing.item; grams=$g; util_cost=$util; basis=$basis; bulk=$isBulk; buy_n=$buyN; buy_cost=$buyCost; pkg=$pkgLabel; pkg_g=$pkgG; starter_n=$stN; starter_cost=$stCost; starter_pkg=$stPkg; starter_pkg_g=$stPkgG }
  }
  $batch=[Math]::Round($batch,2); $trueCost=[Math]::Round($trueCost,2)
  # empty-pantry math (exact): first run = true cost with each pantry staple upgraded from
  # utilization to whole container(s); pantry_add is the one-time extra over the true cost.
  $pantryAdd=[Math]::Round($starterOutlay-$bulkUtil,2)
  if($pantryAdd -lt 0){ $pantryAdd=0.0 }
  $firstRun=[Math]::Round($trueCost+$pantryAdd,2)
  $priced = @($lines).Count
  $unpriced = @($r.ingredients | Where-Object { $_.grams -gt 0 }).Count - $priced
  $out += [pscustomobject]@{
    proposed_name=$r.proposed_name; slug=$r.slug
    cost_batch=$batch; cost_per_serving=[Math]::Round($batch/14,2)
    cost_batch_true=$trueCost; cost_per_serving_true=[Math]::Round($trueCost/14,2)
    cost_pantry_add=$pantryAdd; cost_first_run=$firstRun
    lines_priced=$priced; lines_unpriced=$unpriced
    lines=@($lines)
  }
}
if($Slugs){
  $existingCost = Get-Content (Join-Path $here 'recipes-costed.json') -Raw | ConvertFrom-Json
  $newBySlug = @{}; foreach($r in $out){ $newBySlug[[string]$r.slug] = $r }
  $out = @($existingCost | ForEach-Object { if($newBySlug.ContainsKey([string]$_.slug)){ $newBySlug[[string]$_.slug] } else { $_ } })
  Write-Output ("targeted recost: spliced into {0} total" -f $out.Count)
}
$out | ConvertTo-Json -Depth 7 | Out-File (Join-Path $here 'recipes-costed.json') -Encoding utf8
$costFlags | Out-File (Join-Path $here 'cost-flags.txt') -Encoding utf8
$cps = $out | ForEach-Object { $_.cost_per_serving }
# NOTE: r100 wrote "\${2}" here, which PowerShell reads as ${2} (a variable) and silently blanked the
# numbers. Backtick-escaped so the range actually prints. Display only - no computed value changes.
Write-Output ("costed {0} recipes; flags {1}; per-serving range `${2}-`${3} avg `${4}" -f $out.Count, $costFlags.Count, (($cps|Measure-Object -Minimum).Minimum), (($cps|Measure-Object -Maximum).Maximum), ([Math]::Round(($cps|Measure-Object -Average).Average,2)))
Write-Output ("unpriced ingredient lines: {0} across {1} recipes" -f (($out|Measure-Object lines_unpriced -Sum).Sum), (@($out|Where-Object{$_.lines_unpriced -gt 0}).Count))
if($script:registerEst -gt 0){ Write-Output ("register-estimate lines (known no-Omaha-price, allowlisted, not flagged): {0}" -f $script:registerEst) }
$bad = @($out | Where-Object { $_.cost_batch_true -lt $_.cost_batch })
Write-Output ("true<batch violations: " + $bad.Count)
$bad2 = @($out | Where-Object { $_.cost_first_run -lt $_.cost_batch_true })
Write-Output ("firstrun<true violations: " + $bad2.Count)
