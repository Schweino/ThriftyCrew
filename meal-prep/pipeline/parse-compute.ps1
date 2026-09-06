# parse-compute.ps1 (pipeline, run-agnostic - promoted 2026-07-27 from archive\r300; logic UNCHANGED,
# only the hardcoded r300 paths became parameters). Deterministic engine: source qty strings -> grams ->
# scale to 14 servings -> per-serving macros from food-macros-db -> 550-gate tuning proposals.
# PORT OF r100\parse-compute.ps1. Core logic is IDENTICAL (unit priority, fraction-safe metric, item-paren
# weights w/ the $Matches-clobber fix, fry-oil 84g house rule, cooked->dry, portion clamps, 550 tuner w/
# base bump + pf cap 1.6, protein floor 25g, auto Rice base, Salt+Pepper staples, >900 down-tuner, zero-gram guard).
# R300 DELTAS (additive except the one container rule noted last):
#   * paths/inputs point at r300\ ; slug is carried through every output record
#   * missing food-DB items are ALWAYS non-fatal (flagged + counted); -StrictItems restores r100's throw
#   * qty grammar extended for the r300 splitter's shapes (see QTY GRAMMAR NOTES below)
#   * empty qty string (311 lines in r300 canon, 0 in r100): the quantity, if any, lives in the ITEM text,
#     so the item text is parsed as the qty; if that yields nothing the line falls to the to-taste family.
# Inputs:  recipes-canon.json, densities.json, manual-overrides.json, ..\food-macros-db.json
# Outputs: recipes-computed.json + flags-report.txt (every line it could not confidently parse).
# NOTHING is guessed silently: unparseable lines are flagged for manual resolution.
#
# QTY GRAMMAR NOTES (r300 additions, each one flagged where it assumes):
#   - U+2044 fraction slash, leading number words (one..ten), "N to M" -> "N - M" between numerals
#   - ParseNum: leading-dot decimals (.87), "1-1/2" mixed, "11/2" glued mixed, ranges over mixed numbers
#   - "N can(s) (S oz)" / "N can 15 ounces"; generalized "N S unit [container]" (count x size)
#   - hyphen count x size only when implausible as a range (ratio >= 4) and oz-denominated
#   - metric kg/l/g/ml accept ranges and kilogram(s)/kilo(s)
#   - parenthetical sizes: hyphenated ("(15-ounce)"), spelled-out plurals, mixed numbers, lb/kg/ml,
#     "about/approx", container word inside the parens, trailing "each"
#   - units: tbs alias, strip->slice, sprig, inch, pint/quart/gallon. inch/pint/quart/gallon/sprig are
#     SOFT: used only if densities.json authors them (it already authors Ginger.inch and
#     Cherry Tomatoes.pint, which r100's parser could never reach), else they fall through to r100's chain
#   - size adjectives (small/large) are LAST-RESORT so a real unit always wins ("1 small bunch" -> bunch)
#   - bare number >= 60 with no unit -> grams, ahead of the each-density ("700" ml coconut milk was
#     reading as 700 cans); the 'fl' guard on the metric-g rule is narrowed to a real "fl oz"
#     (item text like "flank"/"flour" was suppressing the weight and falling through to lb)
#   - CONTAINER RULE (the one non-additive change): when a line names a can/jar/package AND densities.json
#     authors that container for the item AND the authored value is not larger than the stated label size,
#     the authored value wins. densities.json stores DRAINED grams per can and the food DB's macros are
#     per drained gram, so a "1 (15-oz) can black beans, drained" must be 255g, not 425g. r100 applied
#     this only on some code paths, so r100 itself was inconsistent between "(15 oz) can" and "(15-oz) can".
# PARITY: run against r100's own canon, this engine matches r100 on 89/100 recipes exactly; all 40 differing
# ingredient lines trace to the improvements above (authored pint/inch densities, "1 small bunch",
# "1/2 to 3/4 tsp" range midpoints, "8 (2 lb)" paren weights, real can sizes) plus tuner cascade.
param([Parameter(Mandatory=$true)][string]$RunDir,   # the run's working folder
      [string]$CanonFile,     # default <RunDir>\recipes-canon.json
      [string]$OverridesFile, # default <RunDir>\manual-overrides.json (optional file)
      [string]$DensitiesFile, # default <meal-prep>\db\densities.json (the canonical store)
      [string]$FoodDbFile,    # default <meal-prep>\food-macros-db.json
      [string]$OutFile,       # default <RunDir>\recipes-computed.json
      [string]$FlagsFile,     # default <RunDir>\flags-report.txt
      [switch]$StrictItems,   # r100 default was: missing DB items are fatal. r300 flags and keeps going.
      [string[]]$Slugs)       # targeted recompute: compute only these, splice into existing outputs (macros are per-recipe, no cross-recipe dependency, so a subset is valid). Default (no -Slugs) is unchanged.
$ErrorActionPreference='Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = Split-Path -Parent $MyInvocation.MyCommand.Path     # ...\meal-prep\pipeline
$mp = Split-Path -Parent $here
if(-not (Test-Path $RunDir)){ throw ("RunDir not found: $RunDir") }
if(-not $CanonFile){     $CanonFile     = Join-Path $RunDir 'recipes-canon.json' }
if(-not $OverridesFile){ $OverridesFile = Join-Path $RunDir 'manual-overrides.json' }
if(-not $DensitiesFile){ $DensitiesFile = Join-Path $mp 'db\densities.json' }
if(-not $FoodDbFile){    $FoodDbFile    = Join-Path $mp 'food-macros-db.json' }
if(-not $OutFile){       $OutFile       = Join-Path $RunDir 'recipes-computed.json' }
if(-not $FlagsFile){     $FlagsFile     = Join-Path $RunDir 'flags-report.txt' }
$rc  = Read-JsonFile $CanonFile
if($Slugs){ $rc = @($rc | Where-Object { $Slugs -contains [string]$_.slug }); if($rc.Count -eq 0){ throw "no canon recipes match -Slugs" } }
$ovr = @{}
$ovrPath = $OverridesFile
if(Test-Path $ovrPath){
  $ovrRaw = (Read-JsonFile $ovrPath).overrides
  # R300 TUNING: override values may be a plain number (grams at source scale, r100-compatible) OR an
  # object { grams, item?, why } where 'item' remaps the line to a different DB item (canon-mapper bugs
  # like sausages->Italian Seasoning, and title-protein swaps, fixed WITHOUT touching recipes-canon.json).
  # Keys of the form '<recipe>::+<Item>' ADD a new ingredient line (dishes whose source omits the title
  # protein or the rice base of a "rice bowl"). Every entry carries a 'why' in the file.
  if($ovrRaw){ foreach($p in $ovrRaw.PSObject.Properties){
    if($p.Value -is [pscustomobject]){ $ovr[$p.Name] = $p.Value } else { $ovr[$p.Name] = [double]$p.Value }
  } }
}
$dnRoot = Read-JsonFile $DensitiesFile
$db  = (Read-JsonFile $FoodDbFile).items
$dbMap=@{}; foreach($i in $db){ $dbMap[$i.item]=$i }
$dn=@{}; foreach($p in $dnRoot.items.PSObject.Properties){ $dn[$p.Name]=$p.Value }

$LB=453.592; $OZ=28.3495
$RICE_DRY_PER_COOKED_CUP=57; $PASTA_DRY_PER_COOKED_CUP=50
$TO_TASTE = @{ 'Salt'=20; 'Black Pepper'=4 }   # per-14-serving batch grams (house standard)
# Substantive items that sources list as "to serve / as desired": house default grams per 14-serving batch.
# Without these, a "rice, for serving" line computes 0g and the dish loses its base entirely.
$SERVE_DEFAULTS = @{
  'Rice'=700; 'Potato'=1400; 'Sweet Potatoes'=1200; 'Tortilla'=420;
  'Feta Cheese'=200; 'Greek Yogurt'=400; 'Hummus'=400; 'Chickpeas'=400;
  'Mexican Cheese Blend'=250; 'Cheddar Cheese, Shredded'=250; 'Reduced Fat Mozzarella'=250; 'Parmesan Cheese'=120;
  'Light Sour Cream'=300; 'Red Onion'=150; 'Cherry Tomatoes'=300; 'Cucumber'=300; 'Olives'=120;
  'Fresh Cilantro'=25; 'Fresh Basil'=15; 'Fresh Mint'=15; 'Green Onions'=60; 'Toasted Sesame Seeds'=25;
  'Lime Juice'=45; 'Lemon Juice'=45; 'Honey'=40; 'Sriracha'=40; 'Vegetable Oil'=42; 'Olive Oil'=42;
  'Sun-Dried Tomatoes'=60
}

# numeric token used by the extended grammar: mixed number | fraction | decimal, optionally a range
$NUMT = '(?:\d+\s+\d+/\d+|\d+/\d+|\d*\.?\d+)'
$NUMR = "(?:$NUMT(?:\s*-\s*$NUMT)?)"

function NormalizeQty([string]$q){
  $q = $q -replace [char]0x00BD,' 1/2' -replace [char]0x00BC,' 1/4' -replace [char]0x00BE,' 3/4' -replace [char]0x2153,' 1/3' -replace [char]0x2154,' 2/3'
  $q = $q -replace [char]0x2013,'-' -replace [char]0x2014,'-'
  $q = $q -replace [char]0x2044,'/' -replace [char]0x00A0,' '   # R300: fraction slash, nbsp
  $q = $q.Trim().ToLower()
  # R300: leading number words ("One 28-ounce can diced tomatoes")
  $q = $q -replace '^one\b','1' -replace '^two\b','2' -replace '^three\b','3' -replace '^four\b','4' -replace '^five\b','5' -replace '^six\b','6' -replace '^seven\b','7' -replace '^eight\b','8' -replace '^nine\b','9' -replace '^ten\b','10'
  # R300: "2 to 3 cups" / "1.1 to 1.4 kg" -> range form (only between numerals; never touches "to taste")
  $q = [regex]::Replace($q,'(?<=\d)\s+to\s+(?=[\d.])',' - ')
  $q.Trim()
}
function FracVal([string]$s){
  if($s -match '^(\d+)\s+(\d+)/(\d+)$'){ return [double]$Matches[1] + [double]$Matches[2]/[double]$Matches[3] }
  if($s -match '^(\d+)/(\d+)$'){ return [double]$Matches[1]/[double]$Matches[2] }
  return [double]$s
}
function ParseNum([string]$s){
  $s=$s.Trim().TrimStart('~').Trim()
  $s=$s.TrimEnd('-','/',' ','.').Trim()            # R300: "20-ounce" leading capture leaves "20-"
  if($s -match '^(\d+)\s+(\d+)/(\d+)$'){ return [double]$Matches[1] + [double]$Matches[2]/[double]$Matches[3] }
  if($s -match '^(\d+)-(\d+)/(\d+)$'){ return [double]$Matches[1] + [double]$Matches[2]/[double]$Matches[3] }   # R300: 1-1/2
  if($s -match '^(\d)(\d)/(\d)$' -and [double]$Matches[2] -lt [double]$Matches[3]){ return [double]$Matches[1] + [double]$Matches[2]/[double]$Matches[3] }  # R300: 11/2 = 1 1/2
  if($s -match ('^(' + $NUMT + ')\s*-\s*(' + $NUMT + ')$')){ return ((FracVal $Matches[1])+(FracVal $Matches[2]))/2 }
  if($s -match '^(\d+)/(\d+)$'){ return [double]$Matches[1]/[double]$Matches[2] }
  if($s -match '^(\d*\.?\d+)$'){ return [double]$Matches[1] }
  return $null
}
function ItemUnit([string]$item,[string]$unit){
  if($dn.ContainsKey($item)){
    $e=$dn[$item]
    if($e.PSObject.Properties.Name -contains $unit -and $e.$unit -is [double] -or ($e.PSObject.Properties.Name -contains $unit -and $e.$unit)){ return [double]$e.$unit }
  }
  return $null
}
# R300: when a line names a CONTAINER ("1 (15-oz) can black beans"), the house density for that container
# beats the label size printed in the parens. densities.json encodes DRAINED grams per can for canned
# vegetables/beans ("drained grams per 15oz can") and the food DB's macros are per drained gram, so
# taking the 15 oz label weight would overstate beans/corn/chickpeas by ~60%. Returns $null when the
# item has no authored container density - then the stated label size is used.
# It only wins when it is NOT bigger than the stated label size (+10% slack): equal means the same
# container, smaller means a drained weight, but bigger means the line stated a DIFFERENT, smaller can
# ("1 8-oz can tomato sauce" must stay 227g, not the 15oz-can density).
function ContainerGrams([string]$item,[string]$containerWord,[double]$labelG){
  if(-not $containerWord){ return $null }
  $c = $containerWord.ToLower()
  $v = $null
  if($c -match 'can'){ $v = ItemUnit $item 'can' }
  elseif($c -match 'jar'){ $v = ItemUnit $item 'jar' }
  elseif($c -match 'package|pkg|box|bag|packet|bottle|tube'){
    $v = ItemUnit $item 'pkg'; if(-not $v){ $v = ItemUnit $item 'packet' }
  }
  if(-not $v){ return $null }
  if($labelG -gt 0 -and $v -gt $labelG*1.10){ return $null }
  return $v
}
function CookFactor([string]$item){
  if($item -eq 'Rice'){ return 0.36 }
  if($item -match 'Pasta|Spaghetti|Noodle|Orzo|Ziti|Fettuccine'){ return 0.44 }
  return 1.0
}
function UnitGrams([string]$u,[double]$n){
  switch -Regex ($u){
    '^(lbs?|pounds?)$'   { return $n*$LB }
    '^(kgs?|kilograms?|kilos?)$' { return $n*1000 }
    '^(g|grams?)$'       { return $n }
    '^ml$'               { return $n }
    default              { return $n*$OZ }   # oz / ounce / fl oz (aqueous canned goods)
  }
}
function GramsFor([string]$item,[string]$qtyRaw,[ref]$flag){
  $q = NormalizeQty $qtyRaw
  $cookedish = ($q -match '\b(cooked|steamed|boiled)\b') -or $script:cookedCtx
  # to-taste family (R300 adds: if desired / for topping / to sprinkle / for crunch - item-text phrasings)
  if($q -match 'to taste|for serving|optional|as desired|as needed|to garnish|garnish|to serve|seasonings|per taste|if desired|for topping|to sprinkle|for crunch'){
    if($TO_TASTE.ContainsKey($item)){ return [double]$TO_TASTE[$item] }
    if($SERVE_DEFAULTS.ContainsKey($item)){ $flag.Value='serve-default'; return [double]$SERVE_DEFAULTS[$item] * $script:curSrcServ / 14.0 }
    $flag.Value = "TO-TASTE zero (minor item)"; return 0
  }
  if($q -match 'pinch|dash'){ $v = ItemUnit $item 'pinch'; if($v){return $v}; return 0.4 }
  if($q -match 'handful'){ $v = ItemUnit $item 'handful'; if($v){return $v}; $flag.Value='handful w/o density'; return 10 }
  $q = $q -replace '~','' -replace '^about ',''
  # "N X-oz can" (unhyphenated size, no parens): 1 14.5-oz can / 1 8-oz can
  if($q -match '^(\d+)\s+(\d+(?:\.\d+)?)[- ]?oz\.?\s+cans?'){
    $n=[double]$Matches[1]; $sz=[double]$Matches[2]
    $av = ContainerGrams $item 'can' ($sz*$OZ)     # R300: authored (drained) can size wins over the label
    if($av){ $flag.Value='authored container size'; return $n*$av }
    return $n*$sz*$OZ
  }
  # R300: "N can(s) [(]S oz[)]" - count of cans x can size ("1 can 15 ounces", "2 cans (13.5 oz)",
  # "1 can (14 oz / 400 g)"). Runs BEFORE metric so the paren's metric equivalent is not read as the total.
  if($q -match ('^(\d+)\s+cans?\s*\(?\s*(' + $NUMR + ')\s*(oz|ounces?|fl ?oz|g|grams?)\b')){
    $n=[double]$Matches[1]; $sz=ParseNum $Matches[2]; $u=$Matches[3]
    if($null -ne $sz){
      $av = ContainerGrams $item 'can' (UnitGrams $u $sz)  # R300: authored (drained) can size wins
      if($av){ $flag.Value='authored container size'; return $n*$av }
      return $n*(UnitGrams $u $sz)
    }
  }
  # R300: generalized "COUNT SIZE UNIT [container]" ("2 15 oz cans", "1 10 3/4 oz can", "1 30 oz.",
  # "1 3 1/2-5 pound (1.75-2.5k)"). Size may not be a bare fraction, so "2 1/2 pounds" stays 2.5 lb.
  if($q -match ('^(\d+)\s+((?:\d+\s+\d+/\d+|\d*\.?\d+)(?:\s*-\s*(?:\d+\s+\d+/\d+|\d*\.?\d+))?)\s*[- ]?\s*(oz|ounces?|lbs?|pounds?|kgs?|kilograms?|kilos?|grams?|g)\.?\b')){
    $n=[double]$Matches[1]; $sz=ParseNum $Matches[2]; $u=$Matches[3]
    if($null -ne $sz){
      $mc=[regex]::Match($q,'\b(cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?|bags?)\b')
      if($mc.Success){ $av = ContainerGrams $item $mc.Value (UnitGrams $u $sz); if($av){ $flag.Value='authored container size'; return $n*$av } }
      return $n*(UnitGrams $u $sz)
    }
  }
  # R300: hyphenated count x size ("2-14.5 ounces" = 2 cans of 14.5oz). Only when the pair is implausible
  # as a range (ratio >= 4) and oz-denominated; everything else stays a range average.
  if($q -match '^(\d+)\s*-\s*(\d+(?:\.\d+)?)\s*(oz|ounces?)\b'){
    $a=[double]$Matches[1]; $b=[double]$Matches[2]
    if($a -gt 0 -and ($b/$a) -ge 4){ $flag.Value='count-x-size assumed'; return $a*$b*$OZ }
  }
  # metric direct (fraction-safe: "1/2 kg" is half a kilo, not 2 kg). Cooked rice/pasta weights convert to dry.
  $cf = 1.0; if($cookedish){ $cf = CookFactor $item }
  if($q -match ('(' + $NUMR + ')\s*(kg|kilograms?|kilos?)\b')){ return (ParseNum $Matches[1])*1000*$cf }
  if($q -match ('(' + $NUMR + ')\s*(litres?|liters?|l)\b') -and $q -notmatch 'lb|large|leaf|leaves'){ return (ParseNum $Matches[1])*1000 }
  # R300: the 'fl' guard is narrowed to an actual "fl oz" - parsing ITEM text hit words like
  # flank / flour / cauliflower and silently skipped the metric weight ("500g/1 lb ... flank" -> 500 lb).
  if($q -match ('(' + $NUMR + ')\s*(g|grams?)\b') -and $q -notmatch 'fl\.? ?oz'){ return (ParseNum $Matches[1])*$cf }
  if($q -match ('(' + $NUMR + ')\s*ml\b')){ return (ParseNum $Matches[1]) }
  # leading count
  $num = $null
  if($q -match '^([\d\s./-]+)'){ $num = ParseNum ($Matches[1].Trim()) }
  # parenthetical container size: N (S oz|g) can/jar/...
  # NOTE: the capture -match must be the LAST regex evaluated before reading $Matches ($Matches-clobber trap).
  if($q -match '\((\d+(?:\.\d+)?)\s*(oz|ounce|fl ?oz|g)\)\s*(cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?)?'){
    $size=[double]$Matches[1]; $u=$Matches[2]; $cw=[string]$Matches[3]; $hasContainer=[bool]$Matches[3]
    $g = if($u -eq 'g'){ $size } else { $size*$OZ }   # fl oz for canned goods ~ weight oz close enough for aqueous
    # "2 (14.5 oz) cans" -> multiply by count. "24 (~8 oz)" (pieces totaling 8 oz) -> paren IS the total.
    if($hasContainer){
      $av = ContainerGrams $item $cw $g   # R300: authored container density wins (see ContainerGrams)
      if($av){ $g = $av; $flag.Value='authored container size' }
      $n = if($num){$num}else{1}; return $n*$g
    }
    return $g
  }
  # R300: extended parenthetical - hyphenated/spelled-out/mixed sizes, lb|kg|ml, "about", container word
  # inside the parens ("1 (10 oz can)") or a trailing "each" ("1 (16.3 ounce each) can").
  if($q -match ('\(\s*(?:about\s*|approx\.?\s*|approximately\s*)?(' + $NUMR + ')\s*-?\s*(oz|ounces?|fl\.? ?oz|g|grams?|ml|lbs?|pounds?|kgs?|kilograms?|kilos?)\b([^)]*)\)\s*(cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?|bags?)?')){
    $sz=ParseNum $Matches[1]; $u=$Matches[2]; $inner=[string]$Matches[3]; $hasContainer=[bool]$Matches[4]
    if($null -ne $sz){
      $g = UnitGrams $u $sz
      $cw = [string]$Matches[4]
      if($inner -match 'cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?|bags?|each'){
        $hasContainer=$true
        if(-not $cw){ $cw = $inner }
      }
      # the container word can also sit BEFORE the parens ("2 cans (10.75 oz each)", "1 package (8-10 oz)")
      if($hasContainer -and -not (ContainerGrams $item $cw $g)){
        $mc=[regex]::Match($q,'\b(cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?|bags?)\b')
        if($mc.Success){ $cw = $mc.Value }
      }
      if($hasContainer){
        $av = ContainerGrams $item $cw $g  # R300: authored container density wins (see ContainerGrams)
        if($av){ $g = $av; $flag.Value='authored container size' }
        $n = if($num){$num}else{1}; return $n*$g
      }
      return $g
    }
  }
  if($null -ne $num){
    # POSITION-BASED unit resolution: the unit that appears EARLIEST in the string wins
    # ("6 tbsp (1/3 cup)" must read tbsp, not cup; "12 tenderloins (1.75 pounds)" must not read pounds
    # from a parenthetical - parentheticals are stripped for unit detection, handled separately below).
    $qUnits = $q -replace '\([^)]*\)',' '   # strip parentheticals for unit detection
    $unitDefs = @(
      @('lb',       '\b(lbs?|pounds?)\b'),
      @('floz',     '\bfl\.? ?oz\b'),
      @('oz',       '\b(oz|ounces?)\b'),
      @('cup',      '\bcups?\b'),
      @('tbsp',     '\b(tbsp|tbs|tablespoons?)\b'),
      @('tsp',      '\b(tsp|teaspoons?)\b'),
      @('clove',    '\bcloves?\b'),
      @('can',      '\bcans?\b'),
      @('jar',      '\bjars?\b'),
      @('pkg',      '\b(packages?|pkgs?|boxes?|bottles?|tubes?|packets?)\b'),
      @('bunch',    '\bbunch(es)?\b'),
      @('stalk',    '\b(stalks?|ribs?)\b'),
      @('slice',    '\b(slices?|strips?)\b'),
      @('head',     '\bheads?\b'),
      @('leaf',     '\b(leaf|leaves)\b'),
      @('stick',    '\bsticks?\b'),
      @('sprig',    '\bsprigs?\b'),
      @('pint',     '\bpints?\b'),
      @('quart',    '\bquarts?\b'),
      @('gallon',   '\bgallons?\b'),
      @('inch',     '\binch(es)?\b')
    )
    # R300: size adjectives are NOT units - they only resolve when no real unit is present, so
    # "1 large clove" reads clove (5g) instead of a whole-item 'each'.
    $sizeDefs = @( @('small','\bsmall\b'), @('large','\blarge\b') )
    $best=$null; $bestPos=[int]::MaxValue
    foreach($ud in $unitDefs){
      $m=[regex]::Match($qUnits, $ud[1])
      if($m.Success -and $m.Index -lt $bestPos){ $best=$ud[0]; $bestPos=$m.Index }
    }
    if(-not $best){
      foreach($ud in $sizeDefs){
        $m=[regex]::Match($qUnits, $ud[1])
        if($m.Success -and $m.Index -lt $bestPos){ $best=$ud[0]; $bestPos=$m.Index }
      }
    }
    switch($best){
      'lb'   { return $num*$LB*$cf }
      'floz' { $v=ItemUnit $item 'floz'; if(-not $v){$v=29.57}; return $num*$v }
      'oz'   { return $num*$OZ*$cf }
      'cup'  {
        if($cookedish -and $item -eq 'Rice'){ return $num*$RICE_DRY_PER_COOKED_CUP }
        if($cookedish -and $item -match 'Pasta|Spaghetti|Noodle|Orzo|Ziti|Fettuccine'){ return $num*$PASTA_DRY_PER_COOKED_CUP }
        $v=ItemUnit $item 'cup'; if($v){ return $num*$v }
        $flag.Value="no cup density"; return $null }
      'tbsp' { $v=ItemUnit $item 'tbsp'; if(-not $v){$v=[double]$dnRoot.defaults.sauce_tbsp; $flag.Value="default tbsp"}; return $num*$v }
      'tsp'  { $v=ItemUnit $item 'tsp'; if(-not $v){$v=[double]$dnRoot.defaults.sauce_tsp; $flag.Value="default tsp"}; return $num*$v }
      'clove'{ $v=ItemUnit $item 'clove'; if(-not $v){$v=5}; return $num*$v }
      'can'  { $v=ItemUnit $item 'can'; if($v){ return $num*$v }; $flag.Value="no can size"; return $null }
      'jar'  { $v=ItemUnit $item 'jar'; if($v){ return $num*$v }; $flag.Value="no jar size"; return $null }
      'pkg'  { $v=ItemUnit $item 'pkg'; if(-not $v){$v=ItemUnit $item 'packet'}; if($v){ return $num*$v }; $flag.Value="no pkg size"; return $null }
      'bunch'{ $v=ItemUnit $item 'bunch'; if($v){ return $num*$v }; $flag.Value="no bunch size"; return $null }
      'stalk'{ $v=ItemUnit $item 'stalk'; if($v){ return $num*$v }; $flag.Value="no stalk size"; return $null }
      'slice'{ $v=ItemUnit $item 'slice'; if($v){ return $num*$v }; $flag.Value="no slice size"; return $null }
      'head' { $v=ItemUnit $item 'head'; if($v){ return $num*$v }; $flag.Value="no head size"; return $null }
      'leaf' { $v=ItemUnit $item 'leaf'; if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v }; $flag.Value="no leaf size"; return $null }
      'stick'{ $v=ItemUnit $item 'stick'; if($v){ return $num*$v }; $flag.Value="no stick size"; return $null }
      # R300 SOFT UNITS: consulted only if densities.json actually defines them. No hardcoded volume/length
      # default - an unauthored soft unit falls through to r100's bare-count chain (each -> can -> pkg -> flag),
      # so "1 pint grape tomatoes" and "1 inch ginger" resolve exactly as they did in r100.
      'sprig' { $v=ItemUnit $item 'sprig';  if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v } }
      'pint'  { $v=ItemUnit $item 'pint';   if($v){ return $num*$v } }
      'quart' { $v=ItemUnit $item 'quart';  if($v){ return $num*$v } }
      'gallon'{ $v=ItemUnit $item 'gallon'; if($v){ return $num*$v } }
      'inch'  { $v=ItemUnit $item 'inch';   if($v){ return $num*$v } }
      'small'{ $v=ItemUnit $item 'small'; if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v }; $flag.Value="no small/each"; return $null }
      'large'{ $v=ItemUnit $item 'large'; if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v }; $flag.Value="no large/each"; return $null }
    }
    # bare count / medium / whole
    # R300: a bare number >= 60 with NO unit is a split-off metric weight ("700" for "700 / milliliters
    # coconut milk"), never a count - it must beat the each-density (700 x 400g cans = 280kg of coconut milk).
    if($num -ge 60){ $flag.Value='bare-number-assumed-grams'; return [double]$num }
    $v=ItemUnit $item 'each'
    if($v){ return $num*$v }
    # canned-goods convention: a bare count on an item whose natural unit is the can means "N cans"
    # (e.g. "1" Diced Tomatoes). Only for shelf items, never broths (could mean cups) - broths flagged.
    if($item -notmatch 'Broth'){
      $v=ItemUnit $item 'can'; if($v){ $flag.Value='bare-count->can assumed'; return $num*$v }
      $v=ItemUnit $item 'pkg'; if($v){ $flag.Value='bare-count->pkg assumed'; return $num*$v }
    }
    $flag.Value="bare count w/o each density"; return $null
  }
  if($q -match 'juice of (\d+(?:\.\d+)?|1/2)'){
    $n = ParseNum $Matches[1]; $v=ItemUnit $item 'each'; if($v){ return $n*$v }
  }
  if($q -match '^(1/2|1/4|1/3|3/4)$'){ $n=ParseNum $Matches[1]; $v=ItemUnit $item 'each'; if($v){ return $n*$v }; $flag.Value='fraction w/o each'; return $null }
  if($q -match 'thumb'){ return 15 }
  if($q -match '400ml'){ return 400 }
  # R300: "a knob of butter" / "a handful" - a bare article is one unit
  if($q -match '^(a|an)\b'){ $v=ItemUnit $item 'each'; if($v){ $flag.Value='article->1 each'; return $v } }
  $flag.Value = "UNPARSED"
  return $null
}

$out=@(); $flags=New-Object System.Collections.Generic.List[string]
foreach($r in $rc){
  $srcServ = [double]$r.source_servings
  if(-not $srcServ -or $srcServ -le 0){ $srcServ = 4; $flags.Add(($r.proposed_name + " :: MISSING source_servings, assumed 4")) }
  $script:curSrcServ = $srcServ
  $ings=@()
  foreach($i in $r.ingredients){
    $ovKey = $r.proposed_name + '::' + $i.canon
    if($ovr.ContainsKey($ovKey)){
      $ov = $ovr[$ovKey]
      if($ov -is [pscustomobject]){
        $ovItem = if($ov.PSObject.Properties.Name -contains 'item' -and $ov.item){ [string]$ov.item } else { $i.canon }
        $ovFlags = if($ovItem -ne $i.canon){ @('manual-override','override-remap:'+$i.canon) } else { @('manual-override') }
        $ings += [pscustomobject]@{ item=$ovItem; grams_src=[double]$ov.grams; flags=$ovFlags }
      } else {
        $ings += [pscustomobject]@{ item=$i.canon; grams_src=[double]$ov; flags=@('manual-override') }
      }
      continue
    }
    $totalG = 0.0; $lineFlags=@()
    foreach($s in $i.sources){
      $f=[ref]''
      $srcItem = [string]$s.item; $srcQty = [string]$s.qty
      $g = $null
      # FRY-OIL rule: oil "for frying" is mostly not consumed; house = 6 tbsp per 14-serving batch
      if($i.canon -match 'Oil' -and (($srcQty + ' ' + $srcItem) -match 'for frying|frying')){
        $g = 84.0 * $script:curSrcServ / 14.0; $f.Value='fry-oil-house'
      }
      # ITEM-NAME parenthetical total weight: "chicken tenderloins (approx 1.75 pounds)" qty "12".
      # NOTE: qty regex must run FIRST - a later -match would clobber $Matches before we read the weight.
      elseif(($srcQty -match '^[\d\s./-]+$') -and ($srcItem -match '\((?:approx\.?\s*|about\s*)?([\d.]+)\s*(pounds?|lbs?|kg|oz)\)')){
        $w = [double]$Matches[1]; $u = $Matches[2]
        $g = switch -Regex ($u){ '^(pounds?|lbs?)$'{ $w*$LB } '^kg$'{ $w*1000 } '^oz$'{ $w*$OZ } }
        $f.Value='item-paren-weight'
      }
      else {
        $script:cookedCtx = ($srcItem -match '\b(cooked|steamed|boiled)\b')
        if(-not $srcQty.Trim()){
          # R300 EMPTY QTY: the r300 splitter leaves qty blank when the amount is inside the item text
          # ("One 28-ounce can diced tomatoes") or when the source truly gives none ("cilantro leaves").
          # Parse the item text as the qty; if nothing parses, fall to the to-taste family house defaults.
          $g = GramsFor $i.canon $srcItem $f
          if($null -ne $g){ if($f.Value){ $f.Value = ([string]$f.Value + '+qty-from-item') } else { $f.Value='qty-from-item' } }
          else {
            if($TO_TASTE.ContainsKey($i.canon)){ $g=[double]$TO_TASTE[$i.canon]; $f.Value='no-qty->house staple' }
            elseif($SERVE_DEFAULTS.ContainsKey($i.canon)){ $g=[double]$SERVE_DEFAULTS[$i.canon]*$script:curSrcServ/14.0; $f.Value='no-qty->serve-default' }
            else { $g=0.0; $f.Value='no-qty zero (minor item)'; $flags.Add(("{0} :: {1} :: '{2}' :: NO QTY ANYWHERE" -f $r.proposed_name, $i.canon, $srcItem)) }
          }
        } else {
          $g = GramsFor $i.canon $srcQty $f
        }
        $script:cookedCtx = $false
      }
      if($null -eq $g){ $flags.Add(("{0} :: {1} :: '{2}' :: {3}" -f $r.proposed_name, $i.canon, $s.qty, $f.Value)); $lineFlags += $f.Value; continue }
      # R300 advisory: an implausibly large single line is almost always a qty misread - value kept, flagged
      if($g -gt 3000){ $flags.Add(("{0} :: {1} :: '{2}' :: LARGE-LINE {3}g (src scale) - review" -f $r.proposed_name, $i.canon, ($s.qty + ' / ' + $srcItem), [Math]::Round($g,0))) }
      if($f.Value){ $lineFlags += $f.Value }
      $totalG += $g
    }
    $ings += [pscustomobject]@{ item=$i.canon; grams_src=[Math]::Round($totalG,1); flags=@($lineFlags | Where-Object {$_}) }
  }
  # ---- THE SOURCE-BASIS SNAPSHOT (ADDED 2026-08-24, phase-6a A-package / pin P3). --------------------
  # PURELY ADDITIVE: a new output field, nothing above or below it changed. It exists because
  # map-preresolve's -Assemble needs THIS recipe's per-line gram weights at the SOURCE recipe's own
  # scale, and the only other per-line grams this file publishes (`ingredients`, below) are the wrong
  # number for that job in three separate ways:
  #   1. they are TARGET-scaled by $fFinal, and the assembler applies the 14/source_servings scale
  #      EXACTLY ONCE - scaling something already scaled is how a 1588 g line becomes 5558 g;
  #   2. the 550-gate TUNER has already moved them - it injects a Rice base into recipes that have
  #      none, walks a base line up or down 5% at a time, and lifts the protein toward a floor. Every
  #      one of those is legitimate arithmetic for a MACRO estimate and a fiction on a shopping list;
  #   3. the auto-staple block appends Salt and Black Pepper lines the recipe never listed.
  # Taken HERE, the snapshot is one entry per input ingredient, in input order, after the qty parser and
  # any reviewed manual override and before all three of those. Positional alignment with the caller's
  # own `ingredients` array is exact: the inner `continue` above skips a SOURCE, never an ingredient, so
  # this loop appends exactly once per entry.
  $srcBasis = @($ings | ForEach-Object {
    [pscustomobject]@{ item=$_.item; grams_src=$_.grams_src; flags=@($_.flags) } })
  # R300 TUNING: '<recipe>::+<Item>' overrides ADD a line the canon lacks (title protein absent from a
  # cross-protein source; rice base absent from a "rice bowl" source). Reviewed by hand, rationale in file.
  $addPrefix = $r.proposed_name + '::+'
  foreach($k in @($ovr.Keys | Where-Object { $_.StartsWith($addPrefix) })){
    $addItem = $k.Substring($addPrefix.Length)
    $ov = $ovr[$k]
    $g = if($ov -is [pscustomobject]){ [double]$ov.grams } else { [double]$ov }
    $ings += [pscustomobject]@{ item=$addItem; grams_src=$g; flags=@('manual-override','override-added') }
  }
  # ZERO-GRAM GUARD: a substantive item at 0g means a silent parse failure - hard flag, never ship.
  # Overridden lines are exempt: a hand-set 0 is a reviewed decision (e.g. optional giblets dropped).
  foreach($zg in ($ings | Where-Object { $_.grams_src -le 0 -and $_.flags -notcontains 'manual-override' })){
    if($zg.item -match 'Chicken|Beef|Turkey|Pork|Sausage|Chorizo|Rice|Pasta|Noodle|Potato|Gnocchi|Tortellini|Spaghetti|Ziti|Orzo|Fettuccine|Cheese|Cream|Butter|Oil$'){
      $flags.Add(($r.proposed_name + " :: " + $zg.item + " :: ZERO GRAMS on substantive item"))
    }
  }
  # ensure house staples present
  foreach($st in @('Salt','Black Pepper')){
    if(-not ($ings | Where-Object { $_.item -eq $st })){
      $ings += [pscustomobject]@{ item=$st; grams_src=(@{Salt=20*$srcServ/14.0;'Black Pepper'=4*$srcServ/14.0}[$st]); flags=@('auto-staple') }
    }
  }
  # ---- PORTION-REALISM CLAMPS (house meal-prep norms, per SERVING at src scale) ----
  # Source dishes sized for huge restaurant portions get brought into house range; every clamp is logged.
  $clampLog=@()
  # R300: protein list extended to the r300 item universe (r100's list was its own 11 proteins; without
  # these, chuck-roast/shoulder dishes sailed past the 240g clamp and turkey-breast dishes could not be
  # protein-bumped - the root cause of the first-pass 21-under-550 / 47-under-25g tail).
  $PROTS_C = @('Boneless Skinless Chicken Breast','Boneless Skinless Chicken Thigh','93/7 Ground Beef','93/7 Ground Turkey','Ground Pork','Pork Chops','Pork Tenderloin','Pork Loin','Pork Chorizo','Smoked Turkey Sausage','Hot Italian Sausage','Turkey Breast','Pork Shoulder','Beef Chuck Roast','Beef Flank/Sirloin Steak','Bratwurst','Diced Ham','Corned Beef Brisket','99/1 Ground Turkey')
  $protTotal = ($ings | Where-Object { $PROTS_C -contains $_.item } | Measure-Object grams_src -Sum).Sum
  $protPerServ = $protTotal / $srcServ
  if($protPerServ -gt 260){
    $k = 240.0/$protPerServ
    foreach($ing in $ings){ if($PROTS_C -contains $ing.item){ $ing.grams_src = [Math]::Round($ing.grams_src*$k,1) } }
    $clampLog += ('protein clamp ' + [Math]::Round($protPerServ,0) + '->240 g/serving')
  }
  foreach($cl in @(
    @{items=@('Walnuts','Peanuts','Cashews'); cap=40; to=35; name='nuts'},
    @{items=@('Butter'); cap=30; to=28; name='butter'},
    @{items=@('Olive Oil','Vegetable Oil','Sesame Oil'); cap=20; to=18; name='oil'},
    @{items=@('Brown Sugar','Sugar','Honey','Hot Honey'); cap=28; to=24; name='sugar'},
    @{items=@('Bread Crumbs'); cap=60; to=50; name='breading'}
  )){
    $tt = ($ings | Where-Object { $cl.items -contains $_.item } | Measure-Object grams_src -Sum).Sum
    $pServ = $tt / $srcServ
    if($pServ -gt $cl.cap){
      $k = $cl.to/$pServ
      foreach($ing in $ings){ if($cl.items -contains $ing.item){ $ing.grams_src = [Math]::Round($ing.grams_src*$k,1) } }
      $clampLog += ($cl.name + ' clamp ' + [Math]::Round($pServ,0) + '->' + $cl.to + ' g/serving')
    }
  }

  # macro compute at pf=1 (scale factor 14/src applies uniformly; per-serving == per-src-serving)
  function PerServing($ings,$f){
    $tot=@{cal=0.0;p=0.0;c=0.0;fat=0.0}; $missing=@()
    foreach($ing in $ings){
      if(-not $dbMap.ContainsKey($ing.item)){ $missing += $ing.item; continue }
      $d=$dbMap[$ing.item]; $per=$ing.grams_src*$f/[double]$d.serving_grams
      $tot.cal+=$per*[double]$d.calories; $tot.p+=$per*[double]$d.protein_g; $tot.c+=$per*[double]$d.carbs_g; $tot.fat+=$per*[double]$d.fat_g
    }
    ,@($tot,$missing)
  }
  $f0 = 14.0/$srcServ
  $res = PerServing $ings $f0; $tot=$res[0]; $missing=$res[1]
  # R300: the 50 new canon items are not in the food DB yet - flag and keep going (r100 threw here).
  if($missing.Count -gt 0){
    $flags.Add(($r.proposed_name + " :: MISSING DB ITEMS: " + (($missing|Select-Object -Unique) -join ', ')))
    if($StrictItems){ throw ("missing DB items: " + (($missing|Select-Object -Unique) -join ', ')) }
  }

  # ---- 550-gate tuner (house style: cheap-carb base first, then portion factor) ----
  # Target 560 (10-cal buffer). Order: 1) bump the recipe's own carb base up to +60%;
  # 2) then portion factor up to 1.6. Protein floor 25g via protein-item bump up to +35%.
  # R300: base + protein lists extended to the r300 item universe (see $PROTS_C note above).
  $BASES = @('Rice','Penne Pasta','Rotini Pasta','Spaghetti','Ziti Pasta','Pasta Shells','Egg Noodles','Fettuccine','Orzo Pasta','Rice Noodles','Lo Mein Noodles','Potato','Sweet Potatoes','Potato Gnocchi','Cheese Tortellini','Grits','Frozen Hash Browns','Tortilla','Corn Muffin Mix','Refrigerated Biscuits','Wild Rice','Bulgur Wheat','Tater Tots','Fries','Stuffing Mix','Sandwich Bread','Rye Bread','Korean Rice Cakes','Pasta Shells - jumbo','Keto Bun')
  $PROTS = @('Boneless Skinless Chicken Breast','Boneless Skinless Chicken Thigh','93/7 Ground Beef','93/7 Ground Turkey','Ground Pork','Pork Chops','Pork Tenderloin','Pork Loin','Pork Chorizo','Smoked Turkey Sausage','Hot Italian Sausage','Turkey Breast','Pork Shoulder','Beef Chuck Roast','Beef Flank/Sirloin Steak','Bratwurst','Diced Ham','Corned Beef Brisket','99/1 Ground Turkey')
  $tuning=@($clampLog)
  $pf=1.0
  function CalcPS([double]$pfv){
    $r2 = PerServing $ings ($f0*$pfv)
    @{cal=$r2[0].cal/14.0;p=$r2[0].p/14.0;c=$r2[0].c/14.0;fat=$r2[0].fat/14.0}
  }
  $ps = CalcPS $pf
  if($ps.cal -lt 560 -and $missing.Count -eq 0){
    $baseIng = $ings | Where-Object { $BASES -contains $_.item } | Sort-Object { -$_.grams_src } | Select-Object -First 1
    if($baseIng -and $baseIng.grams_src -le 1){
      # base exists but computed ~0 (a "for serving" line): set the house base before bumping
      $baseIng.grams_src = [Math]::Round(700.0*$srcServ/14.0,1)
      $tuning += ('base was 0g -> set house default (' + $baseIng.item + ')')
      $ps = CalcPS $pf
    }
    if(-not $baseIng -and -not $ovr.ContainsKey($r.proposed_name + '::__no_auto_base')){
      # no base at all: add a Rice base (house default for bowls) at 50g dry/serving src-equivalent.
      # R300: '<recipe>::__no_auto_base' override suppresses this for dishes whose starch is baked-in
      # (dumplings from flour) - the tuner then works with pf only.
      $addG = [Math]::Round(50*$srcServ/1.0,0)
      $ings += [pscustomobject]@{ item='Rice'; grams_src=[double]$addG; flags=@('tuner-added-base') }
      $tuning += ('added Rice base ' + $addG + 'g (src scale)')
      $baseIng = $ings[-1]
      $ps = CalcPS $pf
    }
    $bump=0.0
    while($baseIng -and $ps.cal -lt 560 -and $bump -lt 0.6){
      $bump += 0.05
      $baseIng.grams_src = [Math]::Round($baseIng.grams_src*1.05,1)
      $ps = CalcPS $pf
    }
    if($bump -gt 0){ $tuning += ('base +' + [Math]::Round($bump*100,0) + '% (' + $baseIng.item + ')') }
    while($ps.cal -lt 560 -and $pf -lt 1.6){
      $pf = [Math]::Round($pf+0.05,2)
      $ps = CalcPS $pf
    }
    if($pf -gt 1.0){ $tuning += ('portion factor ' + $pf) }
  }
  # DOWN-TUNER: rich single-plate dishes over 900 cal/serving trim their carb base (never below the
  # 550 floor; base floor 45g dry/serving equivalent). Anything still >900 gets flagged for manual balance.
  if($ps.cal -gt 900 -and $missing.Count -eq 0){
    $baseIng2 = $ings | Where-Object { $BASES -contains $_.item } | Sort-Object { -$_.grams_src } | Select-Object -First 1
    if($baseIng2){
      $floor = 630.0*$srcServ/14.0
      $trim=0
      while($ps.cal -gt 880 -and $baseIng2.grams_src -gt $floor){
        $baseIng2.grams_src = [Math]::Round($baseIng2.grams_src*0.95,1)
        $trim++
        $ps = CalcPS $pf
        if($trim -gt 20){ break }
      }
      if($trim -gt 0){ $tuning += ('base trimmed -' + [Math]::Round((1-[Math]::Pow(0.95,$trim))*100,0) + '% (' + $baseIng2.item + ')') }
    }
    if($ps.cal -gt 900){ $tuning += 'RICH-DISH FLAG: still >900 after trim - manual balance in spec phase' }
  }
  if($ps.p -lt 25 -and $missing.Count -eq 0){
    $protIng = $ings | Where-Object { $PROTS -contains $_.item } | Sort-Object { -$_.grams_src } | Select-Object -First 1
    if($protIng){
      $pb=0.0
      while($ps.p -lt 25 -and $pb -lt 0.35){
        $pb += 0.05
        $protIng.grams_src = [Math]::Round($protIng.grams_src*1.05,1)
        $ps = CalcPS $pf
      }
      if($pb -gt 0){ $tuning += ('protein +' + [Math]::Round($pb*100,0) + '% (' + $protIng.item + ')') }
    }
  }

  $fFinal = $f0*$pf
  # final scaled grams (integers) for the 14-serving batch
  $scaled = @()
  foreach($ing in $ings){
    $scaled += [pscustomobject]@{ item=$ing.item; grams=[int][Math]::Round($ing.grams_src*$fFinal,0); flags=$ing.flags }
  }
  $out += [pscustomobject]@{
    proposed_name=$r.proposed_name; slug=$r.slug; protein=$r.protein; cuisine=$r.cuisine; format=$r.format
    source_url=$r.source_url; source_site=$r.source_site; source_servings=$srcServ
    scale_factor=[Math]::Round($fFinal,4); portion_factor=$pf
    tuning=@($tuning)
    ingredients=@($scaled)
    ingredients_source_basis=@($srcBasis)   # see the snapshot note above: untuned, unstapled, source scale
    per_serving=@{ calories=[Math]::Round($ps.cal,0); protein_g=[Math]::Round($ps.p,1); carbs_g=[Math]::Round($ps.c,1); fat_g=[Math]::Round($ps.fat,1) }
    missing_db_items=@($missing | Select-Object -Unique)
    gate_550 = ($ps.cal -ge 550)
    gate_gap = [Math]::Round([Math]::Max(0,550-$ps.cal),0)
  }
}
if($Slugs){
  # splice the recomputed subset into the existing recipes-computed.json (keep the other recipes as-is)
  $existing = Read-JsonFile $OutFile
  $newBySlug = @{}; foreach($r in $out){ $newBySlug[[string]$r.slug] = $r }
  $merged = @($existing | ForEach-Object { if($newBySlug.ContainsKey([string]$_.slug)){ $newBySlug[[string]$_.slug] } else { $_ } })
  $merged | ConvertTo-Json -Depth 8 | Out-File $OutFile -Encoding utf8
  Write-Output ("targeted recompute: spliced {0} recipe(s) into {1} total" -f $out.Count, $merged.Count)
} else {
  $out | ConvertTo-Json -Depth 8 | Out-File $OutFile -Encoding utf8
}
$flags | Out-File $FlagsFile -Encoding utf8
$pass = @($out | Where-Object { $_.gate_550 }).Count
$unparsed = @($flags | Where-Object { $_ -match 'UNPARSED|NO QTY ANYWHERE' }).Count
Write-Output ("computed {0} recipes; 550-gate pass at pf=1: {1}; flags: {2}; recipes w/ missing DB items: {3}; unparsed/no-qty lines: {4}" -f $out.Count,$pass,$flags.Count,(@($out | Where-Object { $_.missing_db_items.Count -gt 0 }).Count),$unparsed)

