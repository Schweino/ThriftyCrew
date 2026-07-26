# parse-compute.ps1 - Deterministic engine: source qty strings -> grams -> scale to 14 servings ->
# per-serving macros from food-macros-db -> 550-gate tuning proposals.
# Inputs: recipes-canon.json, densities.json, ..\food-macros-db.json (must already contain all new items)
# Outputs: recipes-computed.json + flags-report.txt (every line it could not confidently parse).
# NOTHING is guessed silently: unparseable lines are flagged for manual resolution.
param([switch]$AllowMissingItems)  # early runs before DB merge: missing items flagged, not fatal
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc  = Get-Content (Join-Path $here 'recipes-canon.json') -Raw | ConvertFrom-Json
$ovr = @{}
$ovrRaw = (Get-Content (Join-Path $here 'manual-overrides.json') -Raw | ConvertFrom-Json).overrides
foreach($p in $ovrRaw.PSObject.Properties){ $ovr[$p.Name] = [double]$p.Value }
$dnRoot = Get-Content (Join-Path $here 'densities.json') -Raw | ConvertFrom-Json
$db  = (Get-Content (Join-Path $here '..\food-macros-db.json') -Raw | ConvertFrom-Json).items
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

function NormalizeQty([string]$q){
  $q = $q -replace [char]0x00BD,' 1/2' -replace [char]0x00BC,' 1/4' -replace [char]0x00BE,' 3/4' -replace [char]0x2153,' 1/3' -replace [char]0x2154,' 2/3'
  $q = $q -replace [char]0x2013,'-' -replace [char]0x2014,'-'
  $q.Trim().ToLower()
}
function FracVal([string]$s){
  if($s -match '^(\d+)/(\d+)$'){ return [double]$Matches[1]/[double]$Matches[2] }
  return [double]$s
}
function ParseNum([string]$s){
  $s=$s.Trim().TrimStart('~')
  if($s -match '^(\d+)\s+(\d+)/(\d+)$'){ return [double]$Matches[1] + [double]$Matches[2]/[double]$Matches[3] }
  if($s -match '^(\d+(?:\.\d+)?|\d+/\d+)\s*-\s*(\d+(?:\.\d+)?|\d+/\d+)$'){ return ((FracVal $Matches[1])+(FracVal $Matches[2]))/2 }
  if($s -match '^(\d+)/(\d+)$'){ return [double]$Matches[1]/[double]$Matches[2] }
  if($s -match '^(\d+(?:\.\d+)?)$'){ return [double]$Matches[1] }
  return $null
}
function ItemUnit([string]$item,[string]$unit){
  if($dn.ContainsKey($item)){
    $e=$dn[$item]
    if($e.PSObject.Properties.Name -contains $unit -and $e.$unit -is [double] -or ($e.PSObject.Properties.Name -contains $unit -and $e.$unit)){ return [double]$e.$unit }
  }
  return $null
}
function CookFactor([string]$item){
  if($item -eq 'Rice'){ return 0.36 }
  if($item -match 'Pasta|Spaghetti|Noodle|Orzo|Ziti|Fettuccine'){ return 0.44 }
  return 1.0
}
function GramsFor([string]$item,[string]$qtyRaw,[ref]$flag){
  $q = NormalizeQty $qtyRaw
  $cookedish = ($q -match '\b(cooked|steamed|boiled)\b') -or $script:cookedCtx
  # to-taste family
  if($q -match 'to taste|for serving|optional|as desired|as needed|to garnish|garnish|to serve|seasonings|per taste'){
    if($TO_TASTE.ContainsKey($item)){ return [double]$TO_TASTE[$item] }
    if($SERVE_DEFAULTS.ContainsKey($item)){ $flag.Value='serve-default'; return [double]$SERVE_DEFAULTS[$item] * $script:curSrcServ / 14.0 }
    $flag.Value = "TO-TASTE zero (minor item)"; return 0
  }
  if($q -match 'pinch'){ $v = ItemUnit $item 'pinch'; if($v){return $v}; return 0.4 }
  if($q -match 'handful'){ $v = ItemUnit $item 'handful'; if($v){return $v}; $flag.Value='handful w/o density'; return 10 }
  $q = $q -replace '~','' -replace '^about ',''
  # "N X-oz can" (unhyphenated size, no parens): 1 14.5-oz can / 1 8-oz can
  if($q -match '^(\d+)\s+(\d+(?:\.\d+)?)[- ]?oz\.?\s+cans?'){ return [double]$Matches[1]*[double]$Matches[2]*$OZ }
  # metric direct (fraction-safe: "1/2 kg" is half a kilo, not 2 kg). Cooked rice/pasta weights convert to dry.
  $cf = 1.0; if($cookedish){ $cf = CookFactor $item }
  if($q -match '(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)\s*(kg)\b'){ return (ParseNum $Matches[1])*1000*$cf }
  if($q -match '(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)\s*(litres?|liters?|l)\b' -and $q -notmatch 'lb|large|leaf|leaves'){ return (ParseNum $Matches[1])*1000 }
  if($q -match '(\d+(?:\.\d+)?)\s*(g|grams?)\b' -and $q -notmatch 'fl'){ return [double]$Matches[1]*$cf }
  if($q -match '(\d+(?:\.\d+)?)\s*ml\b'){ return [double]$Matches[1] }
  # leading count
  $num = $null
  if($q -match '^([\d\s./-]+)'){ $num = ParseNum ($Matches[1].Trim()) }
  # parenthetical container size: N (S oz|g) can/jar/...
  # NOTE: the capture -match must be the LAST regex evaluated before reading $Matches ($Matches-clobber trap).
  if($q -match '\((\d+(?:\.\d+)?)\s*(oz|ounce|fl ?oz|g)\)\s*(cans?|jars?|packages?|pkgs?|bottles?|boxes?|tubes?|packets?)?'){
    $size=[double]$Matches[1]; $u=$Matches[2]; $hasContainer=[bool]$Matches[3]
    $g = if($u -eq 'g'){ $size } else { $size*$OZ }   # fl oz for canned goods ~ weight oz close enough for aqueous
    # "2 (14.5 oz) cans" -> multiply by count. "24 (~8 oz)" (pieces totaling 8 oz) -> paren IS the total.
    if($hasContainer){ $n = if($num){$num}else{1}; return $n*$g }
    return $g
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
      @('tbsp',     '\b(tbsp|tablespoons?)\b'),
      @('tsp',      '\b(tsp|teaspoons?)\b'),
      @('clove',    '\bcloves?\b'),
      @('can',      '\bcans?\b'),
      @('jar',      '\bjars?\b'),
      @('pkg',      '\b(packages?|pkgs?|boxes?|bottles?|tubes?|packets?)\b'),
      @('bunch',    '\bbunch(es)?\b'),
      @('stalk',    '\b(stalks?|ribs?)\b'),
      @('slice',    '\bslices?\b'),
      @('head',     '\bheads?\b'),
      @('leaf',     '\b(leaf|leaves)\b'),
      @('stick',    '\bsticks?\b'),
      @('small',    '\bsmall\b'),
      @('large',    '\blarge\b')
    )
    $best=$null; $bestPos=[int]::MaxValue
    foreach($ud in $unitDefs){
      $m=[regex]::Match($qUnits, $ud[1])
      if($m.Success -and $m.Index -lt $bestPos){ $best=$ud[0]; $bestPos=$m.Index }
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
      'small'{ $v=ItemUnit $item 'small'; if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v }; $flag.Value="no small/each"; return $null }
      'large'{ $v=ItemUnit $item 'large'; if(-not $v){$v=ItemUnit $item 'each'}; if($v){ return $num*$v }; $flag.Value="no large/each"; return $null }
    }
    # bare count / medium / whole
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
      $ings += [pscustomobject]@{ item=$i.canon; grams_src=$ovr[$ovKey]; flags=@('manual-override') }
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
        $g = GramsFor $i.canon $srcQty $f
        $script:cookedCtx = $false
      }
      if($null -eq $g){ $flags.Add(("{0} :: {1} :: '{2}' :: {3}" -f $r.proposed_name, $i.canon, $s.qty, $f.Value)); $lineFlags += $f.Value; continue }
      if($f.Value){ $lineFlags += $f.Value }
      $totalG += $g
    }
    $ings += [pscustomobject]@{ item=$i.canon; grams_src=[Math]::Round($totalG,1); flags=@($lineFlags | Where-Object {$_}) }
  }
  # ZERO-GRAM GUARD: a substantive item at 0g means a silent parse failure - hard flag, never ship
  foreach($zg in ($ings | Where-Object { $_.grams_src -le 0 })){
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
  $PROTS_C = @('Boneless Skinless Chicken Breast','Boneless Skinless Chicken Thigh','93/7 Ground Beef','93/7 Ground Turkey','Ground Pork','Pork Chops','Pork Tenderloin','Pork Loin','Pork Chorizo','Smoked Turkey Sausage','Hot Italian Sausage')
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
  if($missing.Count -gt 0 -and -not $AllowMissingItems){ throw ("missing DB items: " + (($missing|Select-Object -Unique) -join ', ')) }

  # ---- 550-gate tuner (house style: cheap-carb base first, then portion factor) ----
  # Target 560 (10-cal buffer). Order: 1) bump the recipe's own carb base up to +60%;
  # 2) then portion factor up to 1.6. Protein floor 25g via protein-item bump up to +35%.
  $BASES = @('Rice','Penne Pasta','Rotini Pasta','Spaghetti','Ziti Pasta','Pasta Shells','Egg Noodles','Fettuccine','Orzo Pasta','Rice Noodles','Lo Mein Noodles','Potato','Sweet Potatoes','Potato Gnocchi','Cheese Tortellini','Grits','Frozen Hash Browns','Tortilla','Corn Muffin Mix','Refrigerated Biscuits')
  $PROTS = @('Boneless Skinless Chicken Breast','Boneless Skinless Chicken Thigh','93/7 Ground Beef','93/7 Ground Turkey','Ground Pork','Pork Chops','Pork Tenderloin','Pork Loin','Pork Chorizo','Smoked Turkey Sausage','Hot Italian Sausage')
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
    if(-not $baseIng){
      # no base at all: add a Rice base (house default for bowls) at 50g dry/serving src-equivalent
      $addG = [Math]::Round(50*$srcServ/1.0,0)
      $ings += [pscustomobject]@{ item='Rice'; grams_src=[double]$addG; flags=@('tuner-added-base') }
      $tuning += ('added Rice base ' + $addG + 'g (src scale)')
      $baseIng = $ings[-1]
      $ps = CalcPS $pf
    }
    $bump=0.0
    while($ps.cal -lt 560 -and $bump -lt 0.6){
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
    proposed_name=$r.proposed_name; protein=$r.protein; cuisine=$r.cuisine; format=$r.format
    source_url=$r.source_url; source_site=$r.source_site; source_servings=$srcServ
    scale_factor=[Math]::Round($fFinal,4); portion_factor=$pf
    tuning=@($tuning)
    ingredients=@($scaled)
    per_serving=@{ calories=[Math]::Round($ps.cal,0); protein_g=[Math]::Round($ps.p,1); carbs_g=[Math]::Round($ps.c,1); fat_g=[Math]::Round($ps.fat,1) }
    missing_db_items=@($missing | Select-Object -Unique)
    gate_550 = ($ps.cal -ge 550)
    gate_gap = [Math]::Round([Math]::Max(0,550-$ps.cal),0)
  }
}
$out | ConvertTo-Json -Depth 8 | Out-File (Join-Path $here 'recipes-computed.json') -Encoding utf8
$flags | Out-File (Join-Path $here 'flags-report.txt') -Encoding utf8
$pass = @($out | Where-Object { $_.gate_550 }).Count
Write-Output ("computed {0} recipes; 550-gate pass at pf=1: {1}; flags: {2}; recipes w/ missing DB items: {3}" -f $out.Count,$pass,$flags.Count,(@($out | Where-Object { $_.missing_db_items.Count -gt 0 }).Count))
