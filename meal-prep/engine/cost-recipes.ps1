# cost-recipes.ps1 - THE unified, run-agnostic cost engine (2026-07-26 consolidation).
# Exact computational port of the per-run engines (r100/r300/orig cost-engine.ps1, whose cores were
# identical); ALL data now comes from canonical stores instead of per-run copies/hardcoded tables:
#   recipes ............ db\recipes\<slug>.json specs (scaler.ing: canon||item + grams)
#   item knowledge ..... db\ingredients.json (bid/gpu/unit, buy + pantry packages, bulk flag, macros)
#   drained yields ..... db\densities.json ('can' = drained grams; drained basis derived, not hardcoded)
#   label prices ....... db\label-prices.json (agent-captured; SizeToGrams + canon folds applied here)
#   allowlist .......... db\no-board-price-ok.json
#   prices ............. grocery\out comparison-*.json (weekly board) -> recipe-board.json -> smp-feed.json
# Output: db\costed.json (one file, whole catalog) + db\cost-flags.txt. Takes -Slugs for a targeted
# recost (splices into the existing db\costed.json). NOTHING here depends on how many recipes exist.
#
# -DbRoot/-GroceryOut/-OutFile/-FlagsFile exist ONLY so engine\golden-test.ps1 can run this engine
# hermetically over a FROZEN input fixture (2026-08-06). Every default reproduces the live paths
# exactly, so the daily automation path is unchanged. Two rules the golden test depends on:
#   - a fixture run must never write where the live run writes (the harness always passes -OutFile
#     to a temp dir; see grocery\test-auditors.ps1 for the same lesson learned the hard way);
#   - the -Slugs splice reads the file it is about to WRITE ($OutFile), not a hardcoded db\costed.json,
#     so a targeted recost against a fixture splices the fixture's own baseline.
param([string[]]$Slugs,[string]$DbRoot,[string]$GroceryOut,[string]$OutFile,[string]$FlagsFile)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$db = if($DbRoot){ $DbRoot } else { Join-Path $mp 'db' }
$gout = if($GroceryOut){ $GroceryOut } else { Join-Path (Split-Path $mp -Parent) 'grocery\out' }
$costedPath = if($OutFile){ $OutFile } else { Join-Path $db 'costed.json' }
$flagsPath  = if($FlagsFile){ $FlagsFile } else { Join-Path $db 'cost-flags.txt' }
$LB=453.592; $OZ=28.3495

# ---- recipes from the spec store ----
$specFiles = Get-ChildItem (Join-Path $db 'recipes\*.json')
if($Slugs){ $specFiles = @($specFiles | Where-Object { $Slugs -contains $_.BaseName }); if(-not $specFiles.Count){ throw 'no specs match -Slugs' } }
$computed = foreach($sf in $specFiles){
  $s = Get-Content $sf.FullName -Raw | ConvertFrom-Json
  [pscustomobject]@{
    proposed_name=[string]$s.name; slug=[string]$s.slug
    ingredients=@($s.scaler.ing | ForEach-Object {
      $key = if($_.PSObject.Properties.Name -contains 'canon' -and $_.canon){ [string]$_.canon } else { [string]$_.item }
      [pscustomobject]@{ item=$key; grams=[double]$_.grams }
    })
  }
}

# ---- item knowledge ----
$ITEMS=@{}
$ALIASES=@{}
foreach($row in (Get-Content (Join-Path $db 'ingredients.json') -Raw | ConvertFrom-Json)){
  $ITEMS[[string]$row.item]=$row
  # ALIASES MUST RESOLVE HERE TOO. build-v2-spec.ps1 learned adjudicated aliases on 2026-08-16; this
  # engine did not, and the split was invisible in the worst possible way: the SPEC built fine (the
  # alias resolved, the bid was written in) while THIS file looked up the raw canon name, found no row,
  # and silently dropped the line as NO PRICE BASIS. sheet-pan-smoked-sausage-broccoli-cheddar came out
  # at $2.12 for the batch - 15 cents a serving for 3 lb of andouille and 5.25 lb of broccoli - because
  # "Broccoli" and "Andouille Smoked Sausage" are aliases and this lookup could not see them.
  # A resolver that exists in one half of a pipeline and not the other is not a resolver.
  if($row.PSObject.Properties.Name -contains 'aliases'){
    foreach($a in @($row.aliases)){ $an=[string]$a; if($an){ $ALIASES[$an]=$row } }
  }
}
function Resolve-ItemRow([string]$name){
  if($ITEMS.ContainsKey($name)){ return $ITEMS[$name] }
  if($ALIASES.ContainsKey($name)){ return $ALIASES[$name] }
  return $null
}
function Has($row,[string]$p){ $row.PSObject.Properties.Name -contains $p -and $null -ne $row.$p -and "$($row.$p)" -ne '' }

# ---- price boards (identical resolution order to the per-run engines) ----
$cmpFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison
$board=@{}
foreach($row in $cmp){
  $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  $p = $null; $src=''
  if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit; $src='walmart' }
  elseif($row.nomem_price -gt 0){ $p=[double]$row.nomem_price; $src=('nomem:'+$row.nomem_store) }
  if($p){ $board[$row.id] = @{ per_unit=$p; unit=[string]$row.unit; src=$src } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
function Resolve-Gpu([double]$gpu,[string]$mapUnit,[string]$rowUnit){
  if(-not $mapUnit -or -not $rowUnit -or $mapUnit -eq $rowUnit){ return $gpu }
  if($UNIT_G.ContainsKey($mapUnit) -and $UNIT_G.ContainsKey($rowUnit)){ return $gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$mapUnit]) }
  return -1.0
}
$rbFile = Join-Path $gout 'recipe-board.json'
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
$feed = (Get-Content (Join-Path $gout 'smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedMap=@{}
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.cheapest -gt 0){ $feedMap[$p.Name] = @{ per_unit=[double]$p.Value.cheapest; unit=$p.Value.unit } } } }

# ---- label package prices ----
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
# name folds live in db\label-folds.json (data, not code - 2026-07-26)
$labelFolds = @()
$lfFile = Join-Path $db 'label-folds.json'
if(Test-Path $lfFile){ $labelFolds = @((Get-Content $lfFile -Raw | ConvertFrom-Json).folds) }
foreach($r in (Get-Content (Join-Path $db 'label-prices.json') -Raw | ConvertFrom-Json)){
  $nm = $r.item
  foreach($fold in $labelFolds){ if($nm -match [string]$fold.match){ $nm = [string]$fold.to; break } }
  if($null -eq $r.package_price_usd -or $r.package_price_usd -le 0){ continue }
  $g = SizeToGrams ([string]$r.package_size)
  if(-not $g){ continue }
  if(-not $labels.ContainsKey($nm)){ $labels[$nm] = @{ pkg_g=$g; pkg_price=[double]$r.package_price_usd; desc=($r.brand + ' ' + $r.package_size) } }
  $rawNm = [string]$r.item
  if($rawNm -ne $nm -and -not $labels.ContainsKey($rawNm)){ $labels[$rawNm] = $labels[$nm] }
}

# ---- drained-basis items (derived from db: buy package net grams vs densities 'can' drained yield) ----
$dnm=@{}
foreach($p in ((Get-Content (Join-Path $db 'densities.json') -Raw | ConvertFrom-Json).items).PSObject.Properties){ $dnm[$p.Name]=$p.Value }
$DRAINED=@{}
foreach($name in $ITEMS.Keys){
  $row=$ITEMS[$name]
  if(-not (Has $row 'buy_pkg_g')){ continue }
  if(-not $dnm.ContainsKey($name)){ continue }
  if($dnm[$name].PSObject.Properties.Name -notcontains 'can'){ continue }
  $canG=[double]$dnm[$name].can
  if($canG -gt 0 -and $canG -lt ([double]$row.buy_pkg_g * 0.95)){ $DRAINED[$name]=@{ net=[double]$row.buy_pkg_g; drained=$canG } }
}
if($DRAINED.Count -gt 0){
  Write-Output ("drained-basis items: " + (($DRAINED.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Key + ' ' + $_.Value.drained + '/' + $_.Value.net + 'g' }) -join '; '))
}

# ---- CARRIAGE: does any Omaha store stock this food? ----
# Separate from pricing, deliberately. See lib\carriage-lib.ps1 for why conflating the two put four
# uncarried recipes on live paid pages. $FEEDCARRIED is the automatic tier (>=1 real store price in the
# feed); $CARRLEDGER is the adjudicated remainder.
$repoRoot = Split-Path $mp -Parent
. (Join-Path $repoRoot 'lib\carriage-lib.ps1')
$FEEDCARRIED = Get-FeedCarriedSet $feed
$CARRLEDGER  = Import-CarriageLedger (Join-Path $repoRoot 'grocery\carriage.json')

$noBoardOk=@{}
$nbFile = Join-Path $db 'no-board-price-ok.json'
if(Test-Path $nbFile){ foreach($b in (Get-Content $nbFile -Raw | ConvertFrom-Json).bids){ $noBoardOk[[string]$b]=1 } }

# THE ALLOWLIST IS NOT A PARDON. It answers "may this bid skip board pricing?" and nothing else. Until
# 2026-08-22 it was also silently answering "is it carried?", which is how doubanjiang - searched as
# "chili bean sauce", never once found - reached three live paid recipes. An allowlisted bid whose
# carriage is not CARRIED is a hard error, because the alternative is exactly the silence that failed.
$nbBad = @()
foreach($b in $noBoardOk.Keys){
  $c = Get-Carriage -Bid $b -Item '' -FeedCarried $FEEDCARRIED -Ledger $CARRLEDGER
  if($c.verdict -ne 'CARRIED'){ $nbBad += ($b + ' [' + $c.verdict + ': ' + $c.why + ']') }
}
if($nbBad.Count){
  throw ("no-board-price-ok.json lists bid(s) with no carriage evidence: " + ($nbBad -join '; ') +
         ". This list may only excuse BOARD PRICING for a food an Omaha store is proven to stock. " +
         "Either record store evidence in grocery\carriage.json or remove the bid.")
}
$script:registerEst=0
$out=@(); $costFlags=New-Object System.Collections.Generic.List[string]
foreach($r in $computed){
  $lines=@(); $batch=0.0; $trueCost=0.0; $bulkUtil=0.0; $starterOutlay=0.0
  $uncarried=@()   # item names whose carriage is not CARRIED; survives the `continue` paths below
  foreach($ing in $r.ingredients){
    $g=[double]$ing.grams
    if($g -le 0){ continue }
    $row = Resolve-ItemRow ([string]$ing.item)
    $ppg=$null; $basis=''
    # CARRIAGE is judged from the ITEM ROW's bid, not from the basis the line ends up with. That
    # distinction is the whole sumac case: Sumac carries bid=ground-sumac and still falls through to a
    # label: price, so a gate reading only the basis sees no bid at all and asks nothing.
    $lineBid = if($row -and (Has $row 'bid')){ [string]$row.bid } else { $null }
    $carr = Get-Carriage -Bid $lineBid -Item ([string]$ing.item) -FeedCarried $FEEDCARRIED -Ledger $CARRLEDGER
    if($carr.verdict -ne 'CARRIED'){ $uncarried += ([string]$ing.item + ' [' + $carr.verdict + ']') }
    if($row -and (Has $row 'bid')){
      $bid=[string]$row.bid; $gpu=[double]$row.gpu; $mu=if(Has $row 'unit'){ [string]$row.unit } else { '' }
      if($board.ContainsKey($bid)){
        $eg = Resolve-Gpu $gpu $mu $board[$bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $mu + ' vs ' + $board[$bid].unit)); continue }
        $ppg = $board[$bid].per_unit / $eg; $basis=('board:'+$bid+':'+$board[$bid].src)
      }
      elseif($feedMap.ContainsKey($bid)){
        $eg = Resolve-Gpu $gpu $mu $feedMap[$bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $mu + ' vs feed ' + $feedMap[$bid].unit)); continue }
        $ppg = $feedMap[$bid].per_unit / $eg; $basis=('feed:'+$bid)
      }
      elseif($noBoardOk.ContainsKey($bid)){ $script:registerEst++ }
      else { $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: MAPPED BID NOT ON ANY BOARD (' + $bid + ')')) }
    }
    # THE LABEL FALLBACK PRICES ONLY WHAT OMAHA IS PROVEN TO STOCK. Until 2026-08-22 these two
    # statements ran unconditionally, directly after the 'MAPPED BID NOT ON ANY BOARD' flag above - so
    # the engine noticed no store prices the ingredient, wrote an advisory line nothing gates on, and
    # then priced it from a hard-coded label anyway. A recipe costed out normally and published. That is
    # the exact route Sumac took, and doubanjiang after it.
    if($null -eq $ppg -and $labels.ContainsKey($ing.item)){
      if($carr.verdict -eq 'CARRIED'){
        $L=$labels[$ing.item]; $ppg = $L.pkg_price/$L.pkg_g; $basis=('label:'+$L.desc)
      } else {
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: LABEL PRICE REFUSED, CARRIAGE ' + $carr.verdict + ' (' + $carr.why + ')'))
      }
    }
    if($null -eq $ppg){
      $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: NO PRICE BASIS')); continue
    }
    if($DRAINED.ContainsKey($ing.item)){
      $dr=$DRAINED[$ing.item]
      $ppg = $ppg * ($dr.net/$dr.drained)
      $basis = $basis + '+drained'
    }
    $util = [Math]::Round($g*$ppg,2)
    $batch += $util
    $isBulk = ($row -and (Has $row 'bulk') -and $row.bulk)
    $buyN=$null; $buyCost=$null; $pkgLabel=$null; $stN=$null; $stCost=$null; $stPkg=$null; $pkgG=$null; $stPkgG=$null
    if($isBulk){
      $trueCost += $util
      if($row -and (Has $row 'pantry_pkg_g')){
        # NB: variable must NOT be any case-variant of $ppg (PowerShell names are case-insensitive)
        $pantG=[double]$row.pantry_pkg_g
        $stN=[Math]::Ceiling(($g/$pantG) - 0.02); if($stN -lt 1){ $stN=1 }
        $stCost=[Math]::Round($stN*$pantG*$ppg,2)
        if($stCost -lt $util){ $stCost=$util }
        $stPkg=[string]$row.pantry_pkg_label; $stPkgG=$pantG
        $bulkUtil += $util; $starterOutlay += $stCost
      } else {
        $bulkUtil += $util; $starterOutlay += $util
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: BULK ITEM WITHOUT PANTRY PACKAGE DEF'))
      }
    } else {
      $pg=$null
      if($row -and (Has $row 'buy_pkg_g')){ $pg=@{g=[double]$row.buy_pkg_g; label=[string]$row.buy_pkg_label} }
      elseif($labels.ContainsKey($ing.item)){ $pg=@{g=$labels[$ing.item].pkg_g; label=$labels[$ing.item].desc} }
      if($pg){
        $pgG = [double]$pg.g
        if($DRAINED.ContainsKey($ing.item)){ $pgG = $DRAINED[$ing.item].drained }
        $pkgG = $pgG
        $pkgPrice = $pgG*$ppg
        $buyN = [Math]::Ceiling(($g/$pgG) - 0.02)
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
    $lines += [pscustomobject]@{ item=$ing.item; grams=$g; util_cost=$util; basis=$basis; carriage=$carr.verdict; bulk=$isBulk; buy_n=$buyN; buy_cost=$buyCost; pkg=$pkgLabel; pkg_g=$pkgG; starter_n=$stN; starter_cost=$stCost; starter_pkg=$stPkg; starter_pkg_g=$stPkgG }
  }
  $batch=[Math]::Round($batch,2); $trueCost=[Math]::Round($trueCost,2)
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
    lines_uncarried=@($uncarried).Count; uncarried=@($uncarried)
    lines=@($lines)
  }
}
if($Slugs){
  $existingCost = Get-Content $costedPath -Raw | ConvertFrom-Json
  $newBySlug = @{}; foreach($r in $out){ $newBySlug[[string]$r.slug] = $r }
  $replaced = @{}
  $merged = @($existingCost | ForEach-Object {
    if($newBySlug.ContainsKey([string]$_.slug)){ $replaced[[string]$_.slug] = $true; $newBySlug[[string]$_.slug] } else { $_ }
  })
  # APPEND slugs that were costed but are not yet in costed.json. Without this a targeted recost could only
  # ever UPDATE an existing row: a brand-new recipe was costed correctly, found no row to replace, and was
  # silently dropped - which made build-v2-spec's documented -RunCost intake flow impossible for the very
  # case it exists for (2026-08-06, found while costing 29 new burrito specs; build-v2-spec threw
  # "cost-recipes ran but no costed row appeared" with an empty cost-flags.txt, because nothing was wrong
  # with the costing itself). Existing-row behaviour is unchanged.
  $appended = 0
  foreach($r in $out){ if(-not $replaced.ContainsKey([string]$r.slug)){ $merged += $r; $appended++ } }
  $out = $merged
  Write-Output ("targeted recost: spliced into {0} total ({1} replaced, {2} newly added)" -f $out.Count, $replaced.Count, $appended)
}
$out | ConvertTo-Json -Depth 7 | Out-File $costedPath -Encoding utf8
$costFlags | Out-File $flagsPath -Encoding utf8
if($script:registerEst -gt 0){ Write-Output ("register-estimate lines (allowlisted): " + $script:registerEst) }
Write-Output ("costed {0} recipes; flags {1}" -f @($out).Count, $costFlags.Count)