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
param([string[]]$Slugs,[string]$DbRoot,[string]$GroceryOut,[string]$OutFile,[string]$FlagsFile,[switch]$SelfTest,[int]$LedgerMaxAgeDays = 0)
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
    # THE PROJECTION IS THE CONTRACT: a field not copied here does not exist downstream, however
    # carefully a spec declares it. covered_by was first written onto ingredients_grams, which reads
    # like the ingredient list and is not the one this engine costs from - the run produced neither
    # the suppression nor a refusal flag, because the branch never saw the field at all.
    ingredients=@($s.scaler.ing | ForEach-Object {
      $key = if($_.PSObject.Properties.Name -contains 'canon' -and $_.canon){ [string]$_.canon } else { [string]$_.item }
      $cov = if($_.PSObject.Properties.Name -contains 'covered_by'){ [string]$_.covered_by } else { '' }
      [pscustomobject]@{ item=$key; grams=[double]$_.grams; covered_by=$cov }
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
# The WHOLE document, not just .comparison: built_at is what identifies this build of the board,
# and the filename cannot - a rebuild reuses it (2026-09-07).
$cmpDoc = (Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json)
$cmp = $cmpDoc.comparison
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
# THE QUARTER IS SUPPLIED BY THE CALLER, NOT REACHED FOR (2026-09-20, queue 2026-09-19-d240fd).
# The bound on a carriage-ledger price is Brad's standing rule - an everyday price is re-read about once
# every 90 days, at every store - and its ONE canonical copy is $QuarterDays in grocery\capture-policy-lib.ps1.
# This engine first dot-sourced that file directly and ops\audit-cross-module-reach.ps1 was right to refuse it:
# meal-prep reaching into grocery's internals is exactly what that ratchet exists to stop, and writing 90 here
# instead would be the hard-coded band the grocery rules forbid. So the policy stays where it lives and the
# CALLER hands it over: grocery\check-ad-cycles.ps1 already dot-sources capture-policy-lib in its own module
# and passes -LedgerMaxAgeDays $script:QuarterDays. Nobody crosses a module boundary and there is no second
# copy of the number.
# UNSET MEANS REFUSE, never guess: at 0 the ledger basis prices nothing and the line stays NO PRICE BASIS with
# its flag, so a hand run that forgets the flag UNDERSTATES nothing - it simply declines to use the ledger.
$script:LedgerMaxAgeDays = [int]$LedgerMaxAgeDays

function Get-LedgerBasis {
  <#
    THE CARRIAGE LEDGER AS A PRICE (2026-09-20, queue 2026-09-19-d240fd). Returns @{ ppg; basis } when a
    CARRIED ledger entry may price a line, else $null. PURE apart from Test-CarriageEvidence and
    SizeToGrams, so the cases below drive the same decision the engine takes - the whole reason this is a
    function and not five lines inside a 40-line loop body nothing can reach.

    The ledger is the ONE place a live in-store read of price + size + product id + date is recorded for an
    ingredient no capture reaches, and it was consulted for its VERDICT alone. So an ingredient PROVEN
    carried at a KNOWN price dropped out of the recipe and the cost read LOWER, while the same ingredient
    with a stale hand-typed label price would have priced.
    Test-CarriageEvidence is the estate's one rule for whether a CARRIED entry is supported; a ledger anyone
    can hand-edit into a pardon is not a gate, so the check is not re-implemented here.
  #>
  param($Entry, [string]$Bid, [double]$MaxAgeDays, [datetime]$Now)
  if ($null -eq $Entry -or -not $Bid) { return $null }
  if ($MaxAgeDays -le 0) { return $null }   # the quarter could not be read: refuse rather than guess a bound
  $ev = Test-CarriageEvidence -Entry $Entry
  if (-not $ev.ok) { return $null }
  if ([string]$Entry.verdict -ne 'CARRIED') { return $null }
  if (-not $Entry.size) { return $null }
  $g = SizeToGrams ([string]$Entry.size)
  if ($null -eq $g -or $g -le 0) { return $null }
  $ageDays = $null
  try { $ageDays = ($Now - [datetime]([string]$Entry.as_of)).TotalDays } catch { return $null }
  if ($null -eq $ageDays -or $ageDays -gt $MaxAgeDays) { return $null }
  return @{ ppg = ([double]$Entry.price / $g); basis = ('ledger:' + $Bid + ':' + [string]$Entry.store + ':' + [string]$Entry.as_of) }
}

if ($SelfTest) {
  # Nothing above this point writes a file; the engine's work starts below. This block EXITS on every path
  # (ops\audit-selftest-fallthrough.ps1), and its last line is its verdict and says it is a self-test
  # (lib\selftest-verdict.ps1) - exit 0 without that is scored 3, never ok.
  $cfail = 0
  function CChk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '   got: ' + $got); $script:cfail++ }
  }
  $now = [datetime]'2026-09-20T12:00:00'
  # THE FOUNDING ROW, FROZEN VERBATIM from grocery\carriage.json as read on 2026-09-20. Every number real.
  $wild = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Quality Wild Rice'; size = '16 oz (1 lb stand up bag)'; price = 8.99; product_id = '36825'; as_of = '2026-09-19' }
  $lb = Get-LedgerBasis -Entry $wild -Bid 'wild-rice' -MaxAgeDays 90 -Now $now
  # 8.99 / (16 * 28.3495) = 0.0198196.../g. 855 g of it is $16.94 a batch, $1.21 of the reader's serving.
  CChk 'MUST FIRE  the wild-rice ledger row prices at 8.99 / 453.592 g with a ledger: basis naming bid, store and date' (($null -ne $lb) -and ([math]::Abs($lb.ppg - (8.99 / (16 * 28.3495))) -lt 0.0000001) -and ($lb.basis -eq 'ledger:wild-rice:Hy-Vee:2026-09-19')) ("ppg=$(if($lb){$lb.ppg}else{'null'}) basis=$(if($lb){$lb.basis}else{'null'})")
  # $16.95, NOT the $16.94 the plan carried: 8.99 / 453.592 = 0.019819... and 855 g of it is 16.9489, which
  # rounds UP. The plan's figure came from the truncated 0.01982. Measured here, not transcribed.
  CChk 'MUST FIRE  855 g of that line is $16.95 a batch and $1.21 a serving over 14 - the money the recost dropped' (([math]::Round(855 * $lb.ppg, 2) -eq 16.95) -and ([math]::Round(855 * $lb.ppg / 14, 2) -eq 1.21)) ('batch=' + [string][math]::Round(855 * $lb.ppg, 2) + ' serving=' + [string][math]::Round(855 * $lb.ppg / 14, 2))
  # MUST NOT FIRE - each of the four ways an entry is not evidence for a price.
  $nc = [pscustomobject]@{ verdict = 'NOT-CARRIED'; store = 'Hy-Vee'; item = 'Quality Wild Rice'; size = '16 oz'; price = 8.99; as_of = '2026-09-19' }
  CChk 'MUST NOT FIRE a NOT-CARRIED entry never prices a line, whatever price it records' ($null -eq (Get-LedgerBasis -Entry $nc -Bid 'wild-rice' -MaxAgeDays 90 -Now $now)) 'priced'
  # AT THE BAR AND ONE STEP PAST IT (backlog I196). The bar is the quarter, 90 days; the resolution is a day.
  $atBar = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Quality Wild Rice'; size = '16 oz'; price = 8.99; as_of = $now.AddDays(-90).ToString('yyyy-MM-ddTHH:mm:ss') }
  CChk 'MUST NOT FIRE the case exactly AT the 90-day quarter still prices (the bar itself is inside it)' ($null -ne (Get-LedgerBasis -Entry $atBar -Bid 'wild-rice' -MaxAgeDays 90 -Now $now)) 'refused at the bar'
  $pastBar = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Quality Wild Rice'; size = '16 oz'; price = 8.99; as_of = $now.AddDays(-91).ToString('yyyy-MM-ddTHH:mm:ss') }
  CChk 'MUST NOT FIRE one day PAST the quarter is refused - a stale shelf read is not a price' ($null -eq (Get-LedgerBasis -Entry $pastBar -Bid 'wild-rice' -MaxAgeDays 90 -Now $now)) 'priced a 91-day-old read'
  $noSize = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Beef Stew Meat'; size = ''; price = 8.99; as_of = '2026-09-19' }
  CChk 'MUST NOT FIRE an entry with no size stays NO PRICE BASIS - a price with no size is not a rate' ($null -eq (Get-LedgerBasis -Entry $noSize -Bid 'beef-stew-meat' -MaxAgeDays 90 -Now $now)) 'priced'
  $unparse = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Beef'; size = 'priced per pound'; price = 8.99; as_of = '2026-09-19' }
  CChk 'MUST NOT FIRE a size that does not parse to grams is refused, never guessed' ($null -eq (Get-LedgerBasis -Entry $unparse -Bid 'beef' -MaxAgeDays 90 -Now $now)) 'priced'
  $noPrice = [pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'Quality Wild Rice'; size = '16 oz'; price = 0; as_of = '2026-09-19' }
  CChk 'MUST NOT FIRE a CARRIED entry with no price fails Test-CarriageEvidence and prices nothing' ($null -eq (Get-LedgerBasis -Entry $noPrice -Bid 'wild-rice' -MaxAgeDays 90 -Now $now)) 'priced'
  CChk 'MUST NOT FIRE an unreadable quarter (MaxAgeDays -1) refuses rather than guessing a bound' ($null -eq (Get-LedgerBasis -Entry $wild -Bid 'wild-rice' -MaxAgeDays -1 -Now $now)) 'priced with no bound'
  # CLEAN TWIN - the adjacent behaviour this change was most likely to break: the label fallback still runs
  # FIRST, so a line that prices from a label today keeps that basis. five-spice-powder is the real pair:
  # a McCormick Gourmet 1.75 oz label at $8.13 beside a Hy-Vee ledger read of $9.99 for the same size.
  # Ordering by POSITION, not by a regex window: the gap between the two blocks is prose, and a window wide
  # enough to span it proves nothing about order. The label fallback must come first in the engine's body.
  $srcSelf = (Get-Content $PSCommandPath -Raw) -replace "`r", ''
  $iLabel = $srcSelf.IndexOf('if($null -eq $ppg -and $labels.ContainsKey($ing.item)){')
  $iLedger = $srcSelf.IndexOf('$lb = Get-LedgerBasis -Entry $CARRLEDGER[$lineBid]')
  CChk 'CLEAN TWIN the ledger sits AFTER the label in the engine, so a label-priced line keeps its label basis' (($iLabel -gt 0) -and ($iLedger -gt 0) -and ($iLabel -lt $iLedger)) ("label@$iLabel ledger@$iLedger")
  CChk 'CLEAN TWIN SizeToGrams still reads the real ledger size text as 16 oz, not as the 1 lb inside its parenthesis' ([math]::Abs((SizeToGrams '16 oz (1 lb stand up bag)') - (16 * 28.3495)) -lt 0.0001) ([string](SizeToGrams '16 oz (1 lb stand up bag)'))
  if ($cfail -eq 0) { Write-Output 'cost-recipes self-test: PASS'; exit 0 } else { Write-Output ("cost-recipes self-test: FAIL ($cfail case(s))"); exit 1 }
}
$FEEDCARRIED = Get-FeedCarriedSet $feed
# THE LEDGER FOLLOWS -GroceryOut, exactly as the feed does. A fixture run supplies its own grocery-out and
# must get that fixture's carriage too: reading the LIVE ledger while costing FIXTURE prices mixes two
# worlds, and a golden test whose verdicts drift with production data is not a regression test. Falls back
# to the repo ledger for a normal run, where $gout IS grocery\out.
$CARRLEDGER  = Import-CarriageLedger (Join-Path $gout 'carriage.json')
if (-not $CARRLEDGER.Count) { $CARRLEDGER = Import-CarriageLedger (Join-Path (Split-Path $gout -Parent) 'carriage.json') }

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
# REFUSE THE BID, NOT THE CATALOGUE (2026-09-19). This used to throw, which was right about the bid and
# wrong about everything else: on 2026-09-19 the provenance contract withheld every guajillo cell (the
# Walmart and Sam's listings are ship-only, the Baker's and Family Fare ones hunter rows nothing re-reads),
# the feed stopped carrying it, and the throw took down the recost of all 580-odd recipes - while
# check-ad-cycles discarded the exit code, so db\costed.json silently stayed priced off yesterday's board.
# An unproven bid is now struck from the allowlist for this run and named in cost-flags.txt, which the chain
# alerts on. Nothing is pardoned: with no allowlist entry and no carriage, line 227 below refuses its label
# price for every recipe that uses it, exactly as it refuses any other uncarried food.
$script:NbRefused = @()
if($nbBad.Count){
  foreach($b in @($noBoardOk.Keys)){
    $c = Get-Carriage -Bid $b -Item '' -FeedCarried $FEEDCARRIED -Ledger $CARRLEDGER
    if($c.verdict -ne 'CARRIED'){ $noBoardOk.Remove($b); $script:NbRefused += $b }
  }
  Write-Warning ("no-board-price-ok.json lists bid(s) with no carriage evidence, refused for this run: " + ($nbBad -join '; ') +
         ". This list may only excuse BOARD PRICING for a food an Omaha store is proven to stock. " +
         "Either record store evidence in grocery\carriage.json or remove the bid.")
}
$script:registerEst=0
$out=@(); $costFlags=New-Object System.Collections.Generic.List[string]
foreach($b in $nbBad){ $costFlags.Add(('ALLOWLIST :: no-board-price-ok.json :: BID REFUSED, NO CARRIAGE EVIDENCE ' + $b)) }
foreach($r in $computed){
  $lines=@(); $batch=0.0; $trueCost=0.0; $bulkUtil=0.0; $starterOutlay=0.0
  $uncarried=@()   # item names whose carriage is not CARRIED; survives the `continue` paths below
  foreach($ing in $r.ingredients){
    $g=[double]$ing.grams
    if($g -le 0){ continue }
    # INITIALISED ON EVERY PATH, not just the branch that reads it. The emitted line below carries
    # covered_by for all lines, and there is no Set-StrictMode in this tree - so a variable set only
    # inside the non-bulk branch would leak the PREVIOUS ingredient's value onto a bulk line rather
    # than erroring. That is the quiet-wrong-answer shape this engine has been bitten by before.
    $coveredBy = ''
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
    # THE CARRIAGE LEDGER IS A PRICE, NOT JUST A VERDICT (2026-09-20, queue 2026-09-19-d240fd).
    # The ledger is the ONE place a live in-store read of price + size + product id + date is recorded for
    # an ingredient no capture reaches, and until today it was consulted for its verdict alone (line 215).
    # So an ingredient PROVEN carried at a KNOWN price dropped out of the recipe and the cost read LOWER,
    # while the same ingredient with a stale hand-typed label price would have priced. Measured that day:
    # turkey-wild-rice-casserole, a LIVE recipe, lost its TITLE ingredient - wild rice is CARRIED at Hy-Vee
    # ($8.99 / 16 oz, read 2026-09-19, productId 36825) but reaches no board and has no label entry, so the
    # engine dropped 855 g ($16.94 a batch, $1.21 a serving) and costed it at $2.21 a serving against $3.42.
    # AFTER THE LABEL FALLBACK, DELIBERATELY: placed here, exactly ONE line in the whole catalogue changes
    # basis and every currently-priced line keeps the basis it has today. Whether a fresh shelf read should
    # outrank a two-month-old label is a RULING, not a defect (Q1-2026-09-20-partial-cost), so nothing moves
    # until it is answered.
    # Test-CarriageEvidence is the estate's one rule for whether a CARRIED entry is supported: a ledger
    # anyone can hand-edit into a pardon is not a gate, so the check is not re-implemented here.
    if($null -eq $ppg -and $lineBid -and $CARRLEDGER.ContainsKey($lineBid)){
      $lb = Get-LedgerBasis -Entry $CARRLEDGER[$lineBid] -Bid $lineBid -MaxAgeDays $script:LedgerMaxAgeDays -Now (Get-Date)
      if($null -ne $lb){ $ppg = $lb.ppg; $basis = $lb.basis }
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
    $buyN=$null; $buyCost=$null; $pkgLabel=$null; $stN=$null; $stCost=$null; $stPkg=$null; $pkgG=$null; $stPkgG=$null; $pkgGrossG=$null
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
      # COVERED_BY: this line's material comes out of a unit ANOTHER line already buys.
      #
      # A lemon yields juice AND zest. The casserole used 70 g of juice and 5 g of zest, and the engine
      # - costing every line independently - told a reader to buy 2 lemons for the juice and a 3rd for
      # the zest, while the card's own prose said "zest of the same lemons". Two lemons cover both. The
      # card contradicted itself and overcharged by a lemon.
      #
      # OPT-IN AND VALIDATED, because the failure mode of getting this wrong is UNDER-buying, which
      # sends a reader home short of an ingredient - strictly worse than the over-buy it fixes. It
      # applies only where a spec line declares it, and only when the named coverer is in THIS recipe
      # and lands on the SAME basis. Anything else is refused with a flag rather than quietly honoured,
      # so it can never become a way to make a purchase disappear.
      #
      # NOT GENERALISED TO "same basis = one purchase", deliberately. Two lines can share a basis and
      # still be two purchases: slow-cooker-pork-green-chili-bowls buys a 450 g jar of Salsa Verde and
      # 680 g of Green Chile Sauce off one commodity, and ceil(1130/454) = 3 is exactly the 1 + 2 it
      # already pays. Summing there changes nothing; assuming it everywhere would under-buy.
      $coveredBy = if(Has $ing 'covered_by'){ [string]$ing.covered_by } else { '' }
      if($coveredBy){
        $peer = @($r.ingredients | Where-Object { [string]$_.item -eq $coveredBy })
        if($peer.Count -ne 1){
          $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: covered_by names "' + $coveredBy + '", which is not an ingredient of this recipe - buy NOT suppressed'))
          $coveredBy = ''
        } else {
          $peerRow = Resolve-ItemRow $coveredBy
          $peerBid = if($peerRow -and (Has $peerRow 'bid')){ [string]$peerRow.bid } else { '' }
          $myBid   = if($row -and (Has $row 'bid')){ [string]$row.bid } else { '' }
          if(-not $peerBid -or $peerBid -ne $myBid){
            $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: covered_by "' + $coveredBy + '" resolves to bid "' + $peerBid + '" not "' + $myBid + '" - buy NOT suppressed'))
            $coveredBy = ''
          }
        }
      }
      if($coveredBy){
        # The utilisation still counts - the material is used and the batch pays for it. Only the
        # separate PURCHASE is suppressed, because the coverer already bought the unit it comes from.
        $trueCost += $util
        $pkgLabel = $null
      }
      elseif($pg){
        $pgG = [double]$pg.g
        # THE PHYSICAL PACKAGE A READER PUTS IN THE CART, recorded beside the drained weight it becomes
        # (2026-09-02, corn04). pkg_g goes drained the moment an item gets a real yield, and every
        # downstream reader that pairs it with the ingredient row's GROSS grams-per-unit was then
        # mixing two bases with nothing to notice - a 15.25 oz can of corn priced as a 10.51 oz one.
        # This is the number that lets lib\package-cost-lib.ps1 Get-ScalerGpu put the card's data block
        # back on ONE basis, and lets build-card2 prove the block's fallback package is a real can.
        # Additive: nothing that read a costed line before reads it differently now.
        $pkgGrossG = [double]$pg.g
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
    $lines += [pscustomobject]@{ item=$ing.item; grams=$g; util_cost=$util; basis=$basis; carriage=$carr.verdict; bulk=$isBulk; buy_n=$buyN; buy_cost=$buyCost; pkg=$pkgLabel; pkg_g=$pkgG; pkg_gross_g=$pkgGrossG; starter_n=$stN; starter_cost=$stCost; starter_pkg=$stPkg; starter_pkg_g=$stPkgG; covered_by=$coveredBy }
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

# WHICH BOARD THIS RECOST PRICED FROM (2026-09-07). On 2026-09-06 guards blocked the 08:00 publish, so
# the run staged inputs only. Triage unblocked the guard and rebuilt the board at 11:55, the feed was
# re-exported to match - and the RECOST never re-ran, so db\costed.json stayed priced off the 09:51
# board for twenty hours with nothing able to say so. The feed half of that asymmetry was fixed the
# same day; this is the half that was left.
#
# A SIDECAR, NOT A HEADER. costed.json is a bare LIST that many readers consume positionally; adding a
# header would break every one of them.
#
# A PARTIAL RECOST DOES NOT ADVANCE THE BOARD STAMP, and that is the point rather than an omission.
# -Slugs re-prices a handful of recipes and splices them in; claiming the whole catalog is now priced
# off today's board because three slugs are would be a guard that lies in the reassuring direction.
try {
  $stampPath = (Join-Path (Split-Path $costedPath -Parent) 'costed.stamp.json')
  $prior = $null
  if (Test-Path $stampPath) { try { $prior = Get-Content $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prior = $null } }
  $isPartial = ($Slugs -and $Slugs.Count -gt 0)
  $stamp = [ordered]@{
    generated       = (Get-Date).ToString('s')
    scope           = $(if ($isPartial) { 'partial' } else { 'full' })
    board_file      = $cmpFile.Name
    board_built_at  = $(if ($isPartial -and $prior) { [string]$prior.board_built_at } else { [string]$cmpDoc.built_at })
    board_week_of   = $(if ($isPartial -and $prior) { [string]$prior.board_week_of } else { [string]$cmpDoc.week_of })
    recipes_costed  = @($out).Count
    note            = 'board_built_at is the build of the board the WHOLE catalog was priced from. A -Slugs recost splices a few recipes and deliberately leaves it where it was: the catalog is not fresher because three of its rows are.'
  }
  if ($isPartial) {
    $stamp['partial_slugs'] = @($Slugs)
    $stamp['partial_priced_from'] = [string]$cmpDoc.built_at
  }
  ($stamp | ConvertTo-Json -Depth 5) | Set-Content $stampPath -Encoding UTF8
} catch {
  # Never kill a cost run over its own stamp. A recost with no stamp is degraded; a recost KILLED BY
  # its stamp is a lost board - the same rule run-log-lib states for logging.
  Write-Output ('cost-recipes: could not write the board stamp (not fatal): ' + $_.Exception.Message)
}
$costFlags | Out-File $flagsPath -Encoding utf8
if($script:registerEst -gt 0){ Write-Output ("register-estimate lines (allowlisted): " + $script:registerEst) }
Write-Output ("costed {0} recipes; flags {1}" -f @($out).Count, $costFlags.Count)