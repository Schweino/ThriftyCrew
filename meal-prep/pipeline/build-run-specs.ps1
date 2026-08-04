# build-run-specs.ps1 (pipeline, run-agnostic - promoted 2026-07-27 from archive\r300\build-specs.ps1;
# assembly logic UNCHANGED, hardcoded r300 paths/tables became parameters):
#   * every input/output path is a parameter defaulting under -RunDir
#   * the merged map takes -MapFiles (ordered, later files win) and now ALSO understands the canonical
#     db\ingredients.json array shape (rows with item/bid/gpu/unit) - the default map stack is
#     ingredient-map.json <- db\ingredients.json, so new runs inherit the vetted consolidated map
#   * the r300-baked NAME_OVERRIDES / DISPLAY_OVERRIDES / FORBIDDEN_PROSE tables load from an optional
#     -DisplayOverridesFile ({name_overrides:{}, display_overrides:{}, forbidden_prose:{}}); the r300
#     values stay in the archive original (that run is done - they were per-recipe data, not code)
# NOTE for NEW recipes: the modern intake path is pipeline\build-v2-spec.ps1 (one recipe, canonical db).
# This script remains THE batch skeleton builder for a full run (computed+costed -> specs\*.json).
#
# build-specs.ps1 (R300) - Assembles per-recipe spec skeletons (specs\<slug>.json) deterministically from
# recipes-computed.json + recipes-costed.json + the MERGED board map + food DB + densities + canon notes.
# Numeric/display/cost/scaler fields are MACHINE-BUILT here; prose fields (intro_html, shop_smart,
# make_it, portion_html, cost_closing_html, upsell_html, head.description/keywords/steps, prep/cook times)
# are left as "" / [] for the prose wave to fill. spec-guards.ps1 enforces consistency before any build.
#
# PORT OF r100\build-specs.ps1. Deltas (all deliberate, all documented in PIPELINE/RUN-STATE):
#  1. SLUGS come from selected.json (deduped vs live at selection). No re-slugify, no auto -2 suffixes.
#     Hard-fails on any duplicate inside the 300 or any collision with a live recipes-db.json slug.
#  2. MERGED MAP via cost-engine's Load-Map pattern: ingredient-map <- r100-board-map <- r300 extensions.
#  3. SCALER GPU IS UNIT-RECONCILED against the live price source the widget actually reads
#     (smp-feed.json unit, board unit as fallback) - the 2026-07-19 brown-sugar 16x lesson. r100 wrote the
#     raw map gpu, so a map calibrated in oz against a per-lb board row mispriced the widget by 16x.
#  4. PANTRY FOLD IS EXACTNESS-GATED: a line is folded into the "Pantry seasonings" line only when its
#     TRUE-cost contribution equals its utilization (bulk staple, or no package definition). r100 also
#     folded tiny non-bulk package items (red bell pepper, ginger, fresh basil...), whose package price
#     still landed in the true total - so the printed lines did NOT sum to the printed true cost
#     (measured: 63/300 recipes, up to $2.21 each). Now printed contributions sum EXACTLY to true.
#  5. Friendly amounts never render "0 <unit>": below a quarter unit they fall back to 2 decimals.
#  6. Package-label pluralization ("Buy 3 each", not "Buy 3 eachs").
#  7. DISPLAY_OVERRIDES: per-recipe source-faithful ingredient names required by
#     manual-overrides.json -> notes_for_spec_stage (Korean glass noodles, never "Cornstarch").
#     Canonical DB names are preserved in ingredients_grams (the macro basis) and in the scaler.
#  8. Spec carries servings=14, writer_notes[] (SELECTOR/HARVEST/tuning/override rationale for the prose
#     wave) and forbidden_prose_terms[] (enforced by spec-guards in full mode).
param(
  [Parameter(Mandatory=$true)][string]$RunDir,
  [string]$ComputedFile,          # default <RunDir>\recipes-computed.json
  [string]$CostedFile,            # default <RunDir>\recipes-costed.json
  [string]$SelectedFile,          # default <RunDir>\selected.json
  [string]$CanonFile,             # default <RunDir>\recipes-canon.json
  [string]$OverridesFile,         # default <RunDir>\manual-overrides.json
  [string]$FoodDbFile,            # default <meal-prep>\food-macros-db.json
  [string]$DensitiesFile,         # default <meal-prep>\db\densities.json
  [string[]]$MapFiles,            # ordered, later win; default ingredient-map.json + db\ingredients.json
  [string]$DisplayOverridesFile,  # default <RunDir>\display-overrides.json (optional)
  [string]$RunSlugsFile,          # default <RunDir>\run-slugs.txt (optional; post-publish regen exemption)
  [string]$RecipesDbFile,         # default <meal-prep>\recipes-db.json (live-slug collision gate)
  [string]$SpecsDir,              # default <RunDir>\specs
  [string]$FeedFile,              # default <estate>\grocery\out\smp-feed.json
  [string]$GroceryOutDir          # default <estate>\grocery\out (comparison-*.json + recipe-board.json)
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path     # ...\meal-prep\pipeline
$mp = Split-Path -Parent $here
if(-not (Test-Path $RunDir)){ throw ("RunDir not found: $RunDir") }
if(-not $ComputedFile){  $ComputedFile  = Join-Path $RunDir 'recipes-computed.json' }
if(-not $CostedFile){    $CostedFile    = Join-Path $RunDir 'recipes-costed.json' }
if(-not $SelectedFile){  $SelectedFile  = Join-Path $RunDir 'selected.json' }
if(-not $CanonFile){     $CanonFile     = Join-Path $RunDir 'recipes-canon.json' }
if(-not $OverridesFile){ $OverridesFile = Join-Path $RunDir 'manual-overrides.json' }
if(-not $FoodDbFile){    $FoodDbFile    = Join-Path $mp 'food-macros-db.json' }
if(-not $DensitiesFile){ $DensitiesFile = Join-Path $mp 'db\densities.json' }
if(-not $MapFiles -or $MapFiles.Count -eq 0){ $MapFiles = @((Join-Path $mp 'ingredient-map.json'),(Join-Path $mp 'db\ingredients.json')) }
if(-not $DisplayOverridesFile){ $DisplayOverridesFile = Join-Path $RunDir 'display-overrides.json' }
if(-not $RunSlugsFile){  $RunSlugsFile  = Join-Path $RunDir 'run-slugs.txt' }
if(-not $RecipesDbFile){ $RecipesDbFile = Join-Path $mp 'recipes-db.json' }
if(-not $SpecsDir){      $SpecsDir      = Join-Path $RunDir 'specs' }
if(-not $GroceryOutDir){ $GroceryOutDir = Join-Path (Split-Path $mp -Parent) 'grocery\out' }
if(-not $FeedFile){      $FeedFile      = Join-Path $GroceryOutDir 'smp-feed.json' }
$computed = Get-Content $ComputedFile -Raw | ConvertFrom-Json
$costed   = Get-Content $CostedFile -Raw | ConvertFrom-Json
$selected = (Get-Content $SelectedFile -Raw | ConvertFrom-Json).selected
$canon    = Get-Content $CanonFile -Raw | ConvertFrom-Json
$mo       = Get-Content $OverridesFile -Raw | ConvertFrom-Json
$db       = (Get-Content $FoodDbFile -Raw | ConvertFrom-Json).items
$dn       = (Get-Content $DensitiesFile -Raw | ConvertFrom-Json).items

$dbm=@{}; foreach($i in $db){ $dbm[$i.item]=$i }
$dnm=@{}; foreach($p in $dn.PSObject.Properties){ $dnm[$p.Name]=$p.Value }
# each-noun map: see db\each-nouns.json. Kept in step with build-v2-spec.ps1 - both builders share the
# FriendlyAmt each branch, so a fix in only one of them lets the bare-count bug back in through the other.
$enm=@{}
$EachNounsFile = Join-Path (Split-Path (Split-Path $DensitiesFile -Parent) -Parent) 'db\each-nouns.json'
if(-not (Test-Path $EachNounsFile)){ $EachNounsFile = Join-Path (Split-Path $DensitiesFile -Parent) 'each-nouns.json' }
foreach($p in ((Get-Content $EachNounsFile -Raw -Encoding utf8 | ConvertFrom-Json).items.PSObject.Properties)){ $enm[$p.Name]=$p.Value }

# ---- MERGED ITEM -> BOARD MAP (cost-engine Load-Map pattern; later files win) --------------------
function Add-MapFile([hashtable]$acc,[string]$path,[string]$label,[switch]$Required){
  if(-not (Test-Path $path)){
    if($Required){ throw ('map file missing: ' + $path) }
    Write-Warning ('map not found (skipped): ' + $label); return 0
  }
  $raw = Get-Content $path -Raw | ConvertFrom-Json
  $n=0
  if($raw -is [System.Array]){
    # canonical db\ingredients.json shape: array of rows {item, bid, gpu, unit, ...} (rows w/o bid skipped)
    foreach($row in $raw){
      if($row.PSObject.Properties.Name -contains 'bid' -and $row.bid){
        $acc[[string]$row.item]=@{ bid=[string]$row.bid; gpu=[double]$row.gpu; unit=[string]$row.unit; src=$label }; $n++
      }
    }
    return $n
  }
  if($raw.map){ foreach($p in $raw.map.PSObject.Properties){ $acc[$p.Name]=@{ bid=[string]$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit; src=$label }; $n++ } }
  if($raw.mappings){ foreach($m in $raw.mappings){ $acc[$m.item]=@{ bid=[string]$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit; src=$label }; $n++ } }
  if(-not $raw.map -and -not $raw.mappings){ Write-Warning ('map file has neither .map nor .mappings: ' + $path) }
  return $n
}
$bidMap=@{}
$mapCounts=@()
for($mi=0; $mi -lt $MapFiles.Count; $mi++){
  $mf = $MapFiles[$mi]
  $lbl = [IO.Path]::GetFileNameWithoutExtension($mf)
  # the FIRST map file is required (a run with no map at all is a config error); later ones may be absent
  if($mi -eq 0){ $mapCounts += (Add-MapFile $bidMap $mf $lbl -Required) } else { $mapCounts += (Add-MapFile $bidMap $mf $lbl) }
}
Write-Output ("map: " + (($MapFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }) -join ' <- ') + " (" + ($mapCounts -join '+') + ") -> " + $bidMap.Count + " distinct items")

# ---- units of the LIVE price sources the scaler widget reads ------------------------------------
# The widget computes  cost = feed.cheapest * (grams / gpu), so gpu must be grams per the unit the
# FEED quotes. Board unit is the fallback for ids the feed does not carry.
$feedUnit=@{}
$feed = (Get-Content $FeedFile -Raw | ConvertFrom-Json).ingredients
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.unit){ $feedUnit[$p.Name]=[string]$p.Value.unit } } }
$boardUnit=@{}
$cmpFile = Get-ChildItem (Join-Path $GroceryOutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
foreach($row in ((Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison)){ $boardUnit[$row.id]=[string]$row.unit }
$rbFile = Join-Path $GroceryOutDir 'recipe-board.json'
if(Test-Path $rbFile){
  foreach($row in ((Get-Content $rbFile -Raw | ConvertFrom-Json).comparison)){ if(-not $boardUnit.ContainsKey($row.id)){ $boardUnit[$row.id]=[string]$row.unit } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
$gpuFixes=@(); $gpuFlags=@()
function Resolve-ScalerGpu([string]$item,[string]$bid,[double]$gpu,[string]$mapUnit){
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

$costIdx=@{}; foreach($c in $costed){ $costIdx[$c.slug]=$c }
$selIdx=@{};  foreach($s in $selected){ $selIdx[$s.slug]=$s }
$canonIdx=@{}; foreach($c in $canon){ $canonIdx[$c.slug]=$c }

# live catalog slugs - a new spec may never collide with a published recipe
$liveSlugs=@{}
foreach($m in [regex]::Matches([IO.File]::ReadAllText($RecipesDbFile), '"slug"\s*:\s*"([^"]+)"')){ $liveSlugs[$m.Groups[1].Value]=1 }
Write-Output ("live catalog slugs: " + $liveSlugs.Count)

$LB=453.592; $OZ=28.3495
function Den([string]$item,[string]$u){ if($dnm.ContainsKey($item) -and ($dnm[$item].PSObject.Properties.Name -contains $u)){ [double]$dnm[$item].$u } else { $null } }
# The noun that goes with a COUNT - see build-v2-spec.ps1 and db\each-nouns.json for the why. A missing
# entry throws rather than printing a bare number, which is exactly how 661 lines shipped unitless.
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
# Items a shopper buys BY WEIGHT. Nobody scoops cups of turkey breast, kale or mushrooms into a cart,
# and r100's cup fallback produced "Turkey Breast: 14.25 cups" / "Kale: 75.5 cups" (writer-wave finding).
# Meats keep the r100 pounds-always rule; everything else here goes lb at a pound or more, oz below.
$WEIGHT_MEAT   = 'Chicken|Beef|Turkey|Pork|Sausage|Chorizo|Bacon|\bHam\b|Brisket|Liver|Bratwurst|Lamb|Veal'
$WEIGHT_FIRST  = 'Kale|Spinach|Cabbage|Mushrooms|Broccoli|Brussels|Sprouts|Green Beans|Snow Peas|Zucchini|Eggplant|Cauliflower|Collard|Bok Choy|Asparagus|Okra|Squash|Peas$|Corn$'
# names that CONTAIN a meat word but are not sold as meat (r100 printed "Chicken Broth: 4.25 lb")
$NOT_MEAT = 'Broth|Stock|Soup|Bouillon|Seasoning|Powder|Sauce|Gravy|Rub|Bacon Bits'
function FriendlyAmt([string]$item,[double]$g){
  # returns display amount string (without grams)
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
  # bulk/leafy produce and whole-muscle cuts that reached here: weigh them, do not cup them
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

# ---- display-name overrides -----------------------------------------------------------------------
# All three tables load from the optional -DisplayOverridesFile (per-recipe DATA, not code):
#   { "name_overrides":    { "<pipeline name>": "<card display name>" },
#     "display_overrides": { "<slug>::<canonical item>": "<reader-facing name>" },
#     "forbidden_prose":   { "<slug>": ["term", ...] } }
# NAME_OVERRIDES: card title overrides (slug + prose keys unchanged).
# DISPLAY_OVERRIDES: per-recipe ingredient display names. The canonical name stays the macro and pricing
#   basis (ingredients_grams + scaler); only reader-facing text is renamed (the r300 example: dangmyeon IS
#   sweet-potato starch, canonized to Cornstarch, but must never be called cornstarch in front of a cook).
# FORBIDDEN_PROSE: terms the prose may never contain for a given slug (spec-guards full mode enforces).
$NAME_OVERRIDES = @{}
$DISPLAY_OVERRIDES = @{}
$FORBIDDEN_PROSE = @{}
if(Test-Path $DisplayOverridesFile){
  $dof = Get-Content $DisplayOverridesFile -Raw | ConvertFrom-Json
  if($dof.PSObject.Properties.Name -contains 'name_overrides' -and $dof.name_overrides){
    foreach($p in $dof.name_overrides.PSObject.Properties){ $NAME_OVERRIDES[$p.Name]=[string]$p.Value }
  }
  if($dof.PSObject.Properties.Name -contains 'display_overrides' -and $dof.display_overrides){
    foreach($p in $dof.display_overrides.PSObject.Properties){ $DISPLAY_OVERRIDES[$p.Name]=[string]$p.Value }
  }
  if($dof.PSObject.Properties.Name -contains 'forbidden_prose' -and $dof.forbidden_prose){
    foreach($p in $dof.forbidden_prose.PSObject.Properties){ $FORBIDDEN_PROSE[$p.Name]=@($p.Value) }
  }
  Write-Output ("display-overrides loaded: {0} names, {1} ingredient renames, {2} forbidden-term slugs" -f $NAME_OVERRIDES.Count,$DISPLAY_OVERRIDES.Count,$FORBIDDEN_PROSE.Count)
}
# writer_notes are authored metadata (selector/harvest prose), never rendered - but the spec files are
# swept for typographic dashes as a whole, so normalize them here rather than weakening the sweep.
function DeDash([string]$s){
  if($null -eq $s){ return $s }
  ($s -replace ([char]0x2014), ', ') -replace ([char]0x2013), '-' -replace '\s+,', ','
}
function DispName([string]$slug,[string]$item){
  $k = $slug + '::' + $item
  if($DISPLAY_OVERRIDES.ContainsKey($k)){ return $DISPLAY_OVERRIDES[$k] }
  return $item
}

# ---- slug integrity (hard fail before anything is written) ----------------------------------------
$ownSlugs=@{}
$runManifest = $RunSlugsFile
if(Test-Path $runManifest){ foreach($s in (Get-Content $runManifest)){ if($s){ $ownSlugs[$s.Trim()]=1 } } }
$seen=@{}; $slugErrors=@()
foreach($r in $computed){
  $slug = [string]$r.slug
  if(-not $slug){ $slugErrors += ('no slug on ' + $r.proposed_name); continue }
  if(-not $selIdx.ContainsKey($slug)){ $slugErrors += ("slug not in selected.json: $slug"); continue }
  if($seen.ContainsKey($slug)){ $slugErrors += ("duplicate slug inside the 300: $slug") }
  $seen[$slug]=1
  # Live-collision gate: pre-publish this catches accidental reuse of an existing catalog slug.
  # POST-publish (this run's rows are now in recipes-db) a regeneration legitimately "collides"
  # with its own rows - the run manifest (specs-ready.txt, if present) exempts exactly those.
  if($liveSlugs.ContainsKey($slug) -and -not $ownSlugs.ContainsKey($slug)){ $slugErrors += ("slug collides with a LIVE recipe: $slug") }
  if($selIdx[$slug].source_url -ne $r.source_url){ $slugErrors += ("source_url differs selected vs computed: $slug") }
}
if($slugErrors.Count -gt 0){
  $slugErrors | ForEach-Object { Write-Output ('SLUG FAIL :: ' + $_) }
  throw ('slug integrity failed on ' + $slugErrors.Count + ' recipes - nothing written')
}
Write-Output ("slugs: {0} unique, 0 collisions vs live" -f $seen.Count)

if(-not (Test-Path $SpecsDir)){ New-Item -ItemType Directory $SpecsDir | Out-Null }

$index=@(); $notPriced=@{}
foreach($r in $computed){
  $slug = [string]$r.slug
  $cost = $costIdx[$slug]
  if(-not $cost){ throw ('no cost row for ' + $slug) }
  $sel  = $selIdx[$slug]

  $costLines=@{}; foreach($l in $cost.lines){ $costLines[$l.item]=$l }

  # display list: substantive items; only exactness-safe pantry lines fold into the seasonings line
  $display=@(); $scalerIng=@(); $pantryItems=@(); $pantryUtil=0.0; $foldSet=@{}
  foreach($ing in $r.ingredients){
    if($ing.grams -le 0){ continue }
    $cl = $costLines[$ing.item]
    $util = 0.0; if($cl){ $util=[double]$cl.util_cost }
    $isSpice = ($ing.item -match 'Salt|Pepper$|Powder$|Paprika|Cumin|Coriander|Turmeric|Masala|Cinnamon|Cloves|Allspice|Nutmeg|Oregano|Thyme|Basil$|Dill|Parsley|Bay Leaves|Flakes|Seasoning$|Five-Spice|Cayenne|Italian Seasoning')
    # a folded line must contribute its UTILIZATION to the true cost, or the printed pantry line would
    # understate the true total (r100 leak, see header note 4)
    $utilOnly = ($null -eq $cl) -or [bool]$cl.bulk -or (-not $cl.buy_cost)
    # ...and it must actually BE a jar you keep on hand. A 12 g splash of broth is util-only and tiny,
    # but "Pantry seasonings (chicken broth)" reads as a mistake (sopa-de-fideo, writer-wave finding).
    if($ing.item -match 'Broth|Stock|Milk|Cream$|Juice$'){ $isSpice = $false; $utilOnly = $false }
    $dispItem = DispName $slug $ing.item
    $d = $dbm[$ing.item]
    $brand = ''; if($d -and $d.brand -and $d.brand -notmatch '^fresh$|store'){ $brand = ' (' + (($d.brand -split '/')[0].Trim()) + ')' }
    # a renamed ingredient carries its own parenthetical; a second brand paren would read as nonsense
    # ("Korean glass noodles (dangmyeon) (Thai Kitchen)") and the brand belongs to the canonical item
    if($dispItem -ne $ing.item){ $brand = '' }
    # COST folds pantry staples into one "Pantry seasonings" line, but the INGREDIENTS list must still
    # itemize every one (2026-07-26: the list omitted salt/pepper/spices that the recipe actually needs -
    # a reader shopping from it would miss them). So track the fold for the cost line AND always emit the
    # display line, so Ingredients == the scaler's full item set.
    if(($isSpice -or ($ing.grams -lt 15 -and $util -lt 0.15)) -and $utilOnly){
      $pantryItems += $dispItem.ToLower(); $pantryUtil += $util; $foldSet[$ing.item]=1
    }
    $display += ('<strong>' + $dispItem + $brand + ':</strong> ' + (FriendlyAmt $ing.item $ing.grams) + ' (' + [int]$ing.grams + ' g)')
    # Scaler entry (ALL items). The widget renders scaler.item to the READER, so it carries the display
    # name or the same page contradicts itself ("Korean glass noodles" in the ingredient list,
    # "Cornstarch" in the size widget). 'canon' keeps the canonical DB name for machines: build-card
    # emits only item/grams/buy/bid/gpu, so the payload is unchanged in shape, and update-recipes-db +
    # spec-guards read 'canon' for the macro/pricing identity. bid/gpu/pricing untouched.
    $se = [ordered]@{ item=$dispItem; canon=$ing.item; grams=[int]$ing.grams; buy=(FriendlyAmt $ing.item $ing.grams) }
    if($bidMap.ContainsKey($ing.item) -and $bidMap[$ing.item].bid){
      $b=$bidMap[$ing.item]
      $se.bid=$b.bid; $se.gpu=(GpuStr (Resolve-ScalerGpu $ing.item $b.bid $b.gpu $b.unit))
    } else {
      $notPriced[$ing.item]=[int]$notPriced[$ing.item]+1   # widget shows "not price-tracked"
    }
    $scalerIng += [pscustomobject]$se
  }

  # cost section lines (printed contributions sum EXACTLY to the printed true cost)
  $costHtml=@(); $sumUtil=0.0; $sumTrue=0.0
  foreach($ing in $r.ingredients){
    $cl = $costLines[$ing.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ing.item)){ continue }
    $util=[double]$cl.util_cost
    $sumUtil += $util
    $amt = FriendlyAmt $ing.item $ing.grams
    $nm  = DispName $slug $ing.item
    if($cl.bulk){
      $sumTrue += $util
      # "Buy 1 (lasts several batches)" is a lie when the batch drinks 5 cartons of broth. Pantry items
      # still take the utilization path in the true cost (documented 3-part model), but the line has to
      # tell the shopper how much this batch actually consumes. No dollar figure is added, so the
      # printed contributions still sum exactly to the true cost.
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
  # pantry fold line (every folded line contributes exactly its utilization)
  foreach($ing in $r.ingredients){
    $cl = $costLines[$ing.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ing.item)){ $sumUtil += [double]$cl.util_cost; $sumTrue += [double]$cl.util_cost }
  }
  if($pantryItems.Count -gt 0){
    $pl = ($pantryItems | Select-Object -Unique) -join ', '
    $costHtml += ('Pantry seasonings (' + $pl + '): ~$' + $pantryUtil.ToString('0.00') + '. <strong>From jars you keep on hand.</strong>')
  }
  $batch=[Math]::Round($sumUtil,2); $trueC=[Math]::Round($sumTrue,2)
  $cps = [Math]::Round($batch/14,2); $cpsTrue=[Math]::Round($trueC/14,2)
  # three cost views, each labeled with exactly what it assumes (Brad 2026-07-19):
  #   batch = ingredient value used; true = register trip with a stocked pantry; first run = empty pantry
  $pantryAdd=[double]$cost.cost_pantry_add; $firstRun=[double]$cost.cost_first_run
  if([Math]::Abs($batch-[double]$cost.cost_batch) -gt 0.005){ throw ($slug + ': spec batch ' + $batch + ' != engine ' + $cost.cost_batch) }
  if([Math]::Abs($trueC-[double]$cost.cost_batch_true) -gt 0.005){ throw ($slug + ': spec true ' + $trueC + ' != engine ' + $cost.cost_batch_true) }
  if([Math]::Abs(($trueC+$pantryAdd)-$firstRun) -gt 0.005){ throw ($slug + ': first_run ' + $firstRun + ' != true+add ' + ($trueC+$pantryAdd)) }
  $costHtml += ('<strong>Batch total: about $' + $batch.ToString('0.00') + ' across 14 servings, so roughly $' + $cps.ToString('0.00') + ' per bowl.</strong> This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.')
  $costHtml += ('<strong>True shopping cost: about $' + $trueC.ToString('0.00') + ' across 14 servings, roughly $' + $cpsTrue.ToString('0.00') + ' per bowl.</strong> What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.')
  if($pantryAdd -gt 0){
    $costHtml += ('<strong>Starting with an empty pantry? Add about $' + $pantryAdd.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.')
  }

  # ---- writer notes: everything the prose wave must know that is not in the numbers ---------------
  $wn=@()
  $cn = $canonIdx[$slug]
  if($cn -and $cn.notes){ $wn += [string]$cn.notes }
  if($cn -and $cn.source_servings){ $wn += ('SOURCE YIELD: ' + $cn.source_servings + ' servings, rebuilt to 14.') }
  foreach($t in @($r.tuning)){ if($t){ $wn += ('TUNING: ' + $t) } }
  $ovPrefix = [string]$r.proposed_name + '::'
  foreach($p in $mo.overrides.PSObject.Properties){
    if($p.Name.StartsWith($ovPrefix)){
      $why = $null
      if($p.Value -is [string] -or $p.Value -is [double] -or $p.Value -is [int]){ $why = $null } elseif($p.Value.why){ $why = [string]$p.Value.why }
      if($why){ $wn += ('OVERRIDE ' + $p.Name.Substring($ovPrefix.Length) + ': ' + $why) }
    }
  }
  foreach($k in $DISPLAY_OVERRIDES.Keys){
    if($k.StartsWith($slug + '::')){
      $wn += ('NAME IT RIGHT: call "' + $k.Substring($slug.Length+2) + '" -> "' + $DISPLAY_OVERRIDES[$k] + '" in every sentence; the canonical name is a macro/pricing basis only.')
    }
  }

  $dispName = [string]$r.proposed_name
  if($NAME_OVERRIDES.ContainsKey($dispName)){ $dispName = $NAME_OVERRIDES[$dispName] }
  $spec = [ordered]@{
    name = $dispName
    slug = $slug
    cuisine = $r.cuisine
    protein = $r.protein
    servings = 14
    visibility = 'paid'
    source_url = [string]$sel.source_url
    source_site = [string]$r.source_site
    manual_balance = ([bool]($r.tuning -match 'RICH-DISH'))
    tuning = @($r.tuning)
    writer_notes = @($wn | ForEach-Object { DeDash $_ })
    forbidden_prose_terms = @($(if($FORBIDDEN_PROSE.ContainsKey($slug)){ $FORBIDDEN_PROSE[$slug] } else { @() }))
    stat = [ordered]@{ cal=[int]$r.per_serving.calories; protein=[int][Math]::Round($r.per_serving.protein_g,0); carbs=[int][Math]::Round($r.per_serving.carbs_g,0); fat=[int][Math]::Round($r.per_serving.fat_g,0); cost_ps=$cps.ToString('0.00') }
    intro_html = ''
    ingredients_display = @($display)
    cost_note_html = 'Real Omaha store prices from our weekly grocery board (2026). They still swing by store and by what is on sale.'
    cost_lines = @($costHtml)
    cost_closing_html = ''
    shop_smart = @()
    make_it = @()
    portion_html = ''
    credit_html = ('Recipe adapted from <a href="' + $sel.source_url + '" target="_blank" rel="noopener">' + $r.source_site + '</a>, rebuilt for 14-serving budget meal prep with weighed portions and Omaha pricing.')
    upsell_html = ''
    cost_batch = $batch
    cost_batch_true = $trueC
    cost_per_serving = $cps
    cost_per_serving_true = $cpsTrue
    cost_pantry_add = [Math]::Round($pantryAdd,2)
    cost_first_run = [Math]::Round($firstRun,2)
    scaler = [ordered]@{ cost=$trueC.ToString('0.00'); ing=@($scalerIng) }
    head = [ordered]@{ description=''; keywords=''; image=''; prepTime=''; cookTime=''; totalTime=''; costPerServing=$cps; recipeIngredient=@(); steps=@() }
    ingredients_grams = @($r.ingredients | Where-Object { $_.grams -gt 0 } | ForEach-Object { [pscustomobject]@{ item=$_.item; grams=[int]$_.grams } })
  }
  $spec | ConvertTo-Json -Depth 8 | Out-File (Join-Path $SpecsDir ($slug + '.json')) -Encoding utf8
  $index += [pscustomobject]@{ slug=$slug; name=$dispName; protein=$r.protein; cuisine=$r.cuisine; cal=[int]$r.per_serving.calories; protein_g=[int][Math]::Round($r.per_serving.protein_g,0); cost=$cps; cost_true=$cpsTrue; manual_balance=([bool]($r.tuning -match 'RICH-DISH')) }
}
ConvertTo-Json -InputObject $index -Depth 4 | Out-File (Join-Path $SpecsDir '_index.json') -Encoding utf8

Write-Output ("built {0} spec skeletons -> specs\  (manual-balance: {1})" -f $index.Count, (@($index | Where-Object { $_.manual_balance }).Count))
if($gpuFixes.Count -gt 0){
  Write-Output ("scaler gpu unit-reconciled on " + (@($gpuFixes | Sort-Object -Unique).Count) + " distinct items:")
  $gpuFixes | Sort-Object -Unique | ForEach-Object { Write-Output ('  ' + $_) }
}
if($gpuFlags.Count -gt 0){
  Write-Output ("GPU UNIT FLAGS (non-standard, review):")
  $gpuFlags | Sort-Object -Unique | ForEach-Object { Write-Output ('  ' + $_) }
}
if($notPriced.Count -gt 0){
  Write-Output ("items with no board mapping (widget shows 'not price-tracked'): " + $notPriced.Count)
  $notPriced.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Output ('  ' + $_.Key + ' x' + $_.Value) }
}
