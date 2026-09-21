# cost-recipes.ps1 - THE unified, run-agnostic cost engine (2026-07-26 consolidation).
# Exact computational port of the per-run engines (r100/r300/orig cost-engine.ps1, whose cores were
# identical); ALL data now comes from canonical stores instead of per-run copies/hardcoded tables:
#   recipes ............ db\recipes\<slug>.json specs (scaler.ing: canon||item + grams)
#   item knowledge ..... db\ingredients.json (bid/gpu/unit, buy + pantry packages, bulk flag, macros)
#   drained yields ..... db\densities.json ('can' = drained grams; drained basis derived, not hardcoded)
#   label macros ....... db\label-prices.json - MACROS ONLY since 2026-09-21 (Brad's ruling); no price is read from it
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
# ---- db\label-prices.json: MACROS ONLY. NO PRICE IS READ FROM IT (2026-09-21) ----
# Brad's standing ruling, 2026-09-21: "We should never have hand-typed pricing. The pricing must be fetched from a
# store always." and "Pricing should always come from Ads or websites from stores directly." This file's 59 prices
# were read ONCE, by an agent in a browser, off walmart.com in July, riding along with the NUTRITION label it was
# really capturing; 13 of them were walmart.com MARKETPLACE third-party sellers the board had already stripped under
# the in-store rule, and the file was never refreshed. Until 2026-09-21 its price was this engine's fallback after
# the board and the feed. It is not any more: the file stays because its macros are real (calories, protein_g,
# carbs_g, fat_g, the label image they were read from), and Import-LabelMacros copies ONLY those fields, so nothing
# below can price from a label because no label price is ever loaded. An ingredient the board, the feed and the
# carriage ledger cannot price stays NO PRICE BASIS and pages: the repair is a store fetch, never a label.
# (db\label-folds.json only ever mapped label NAMES onto recipe names for that price lookup, so it is not read.)
# The engine also REFUSES to write costed.json while any line carries a label: basis (Get-LabelBasisLines).
function Import-LabelMacros($Rows) {
  $m = [ordered]@{}   # file order, so the package map below keeps first-row-wins exactly as it did
  foreach ($r in @($Rows)) {
    if ($null -eq $r -or -not [string]$r.item) { continue }
    $nm = [string]$r.item
    if ($m.Contains($nm)) { continue }
    $m[$nm] = [pscustomobject]@{
      item = $nm; brand = [string]$r.brand; package_size = [string]$r.package_size
      serving_grams = $r.serving_grams; calories = $r.calories; protein_g = $r.protein_g; carbs_g = $r.carbs_g; fat_g = $r.fat_g
      label_source_url = [string]$r.label_source_url
    }
  }
  return $m
}
$LABELMACROS = Import-LabelMacros (Get-Content (Join-Path $db 'label-prices.json') -Raw | ConvertFrom-Json)
if (-not $SelfTest) { Write-Output ('label-prices.json: ' + $LABELMACROS.Count + ' label row(s) loaded for MACROS ONLY; no price read from it (Brad''s ruling, 2026-09-21)') }
# THE LABEL'S PACKAGE SIZE IS STILL A PURCHASE PACKAGE, NEVER A PRICE. An item with no buy package in
# db\ingredients.json is still told to buy the label's package (its grams and its brand + size text) further down,
# exactly as before; the price of that package comes from the store like every other line. Name folds from
# db\label-folds.json apply to this lookup as they always did.
$LABELPKG = @{}
$labelFolds = @()
$lfFile = Join-Path $db 'label-folds.json'
if(Test-Path $lfFile){ $labelFolds = @((Get-Content $lfFile -Raw | ConvertFrom-Json).folds) }
foreach($lmRow in $LABELMACROS.Values){
  $nm = [string]$lmRow.item
  foreach($fold in $labelFolds){ if($nm -match [string]$fold.match){ $nm = [string]$fold.to; break } }
  $g = SizeToGrams ([string]$lmRow.package_size)
  if(-not $g){ continue }
  if(-not $LABELPKG.ContainsKey($nm)){ $LABELPKG[$nm] = @{ pkg_g=$g; desc=($lmRow.brand + ' ' + $lmRow.package_size) } }
  $rawNm = [string]$lmRow.item
  if($rawNm -ne $nm -and -not $LABELPKG.ContainsKey($rawNm)){ $LABELPKG[$rawNm] = $LABELPKG[$nm] }
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

function Split-CostFlags {
  <#
    WHICH FLAG LINES PAGE (2026-09-21, queue 2026-09-20-6c14f6). db\cost-flags.txt is the file the chain pages
    on, and until today every line in it paged alike: on 2026-09-19 it held 28 lines, 1 of them on a live page,
    and the reader had to cross it against db\held-recipes.json by hand to learn that. Hold and publication
    state live in THIS module (db\held-recipes.json, db\published-hashes.json), so the split is made here, where
    the lines are written. The chain cannot read either file without a new cross-module reach, which
    ops\audit-cross-module-reach.ps1 refused on 2026-09-20 (118 -> 119), correctly.
    PURE: $Entries is @{ slug; line } in engine order (slug '' for a catalogue-level line such as a refused
    allowlist bid), so the cases below drive the same decision the engine takes.
      * a HELD recipe's lines leave the paging file. It was taken down by design; it is still costed (its
        costed.json row stays current for a release) and it is reported as a count, never silently dropped;
      * an ADVISORY line leaves it: the bid is on no board but the line still PRICED from a label or the
        carriage ledger, so it is not an unpriced line, and calling it one is how 8 of the 26 lines on
        2026-09-21 read as money a reader was missing when none was;
      * a LIVE recipe's lines LEAD the file with a 'LIVE :: ' prefix: the one kind a reader can act on;
      * every other line keeps its bytes and its order, so a catalogue with nothing held, nothing published and
        nothing advisory writes exactly what it wrote before (the golden fixture is that catalogue).
  #>
  param([object[]]$Entries, [hashtable]$Held, [hashtable]$Live)
  $liveL = New-Object System.Collections.Generic.List[string]
  $restL = New-Object System.Collections.Generic.List[string]
  $heldL = New-Object System.Collections.Generic.List[string]
  $advL  = New-Object System.Collections.Generic.List[string]
  foreach ($e in $Entries) {
    if ($null -eq $e) { continue }
    $s = [string]$e.slug; $ln = [string]$e.line
    if ($s -and $Held.ContainsKey($s)) { $heldL.Add($ln) }
    elseif ($ln -like '* :: ADVISORY, *') { $advL.Add($ln) }
    elseif ($s -and $Live.ContainsKey($s)) { $liveL.Add('LIVE :: ' + $ln) }
    else { $restL.Add($ln) }
  }
  $page = New-Object System.Collections.Generic.List[string]
  foreach ($x in $liveL) { $page.Add($x) }
  foreach ($x in $restL) { $page.Add($x) }
  return [pscustomobject]@{ lines = $page.ToArray(); held = $heldL.ToArray(); advisory = $advL.ToArray(); live = $liveL.Count }
}

function Get-LabelBasisLines($Recipes) {
  # Every costed line priced from a label, as '<slug> :: <item> :: <basis>'. The engine refuses to write
  # costed.json while this is non-empty (2026-09-21, Brad's ruling): a label price reaching a recipe again is a
  # regression, never a fallback. Returned with a leading comma so an EMPTY answer is an empty array, not $null
  # (@($null).Count is 1): callers assign first, then count.
  $hits = New-Object System.Collections.Generic.List[string]
  foreach ($r in @($Recipes)) {
    if ($null -eq $r) { continue }
    foreach ($l in @($r.lines)) {
      if ($null -eq $l) { continue }
      if (([string]$l.basis).StartsWith('label:', [StringComparison]::Ordinal)) { $hits.Add(([string]$r.slug + ' :: ' + [string]$l.item + ' :: ' + [string]$l.basis)) }
    }
  }
  return ,$hits.ToArray()
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
  # ---- NO LINE PRICES FROM A LABEL (2026-09-21, Brad's ruling) ----------------------------------------------
  # These replace the 2026-09-20 CLEAN TWIN that held the label fallback AHEAD of the ledger. That ordering was
  # Q1-2026-09-20-partial-cost, and Brad answered it on 2026-09-21 by retiring the label as a price altogether.
  # FROZEN: the real Five-Spice row of db\label-prices.json, and the real costed lines of 2026-09-21 before and
  # after the board priced five spice from Hy-Vee.
  $fsLabelRows = ConvertFrom-Json '[{"item":"Five-Spice Powder","brand":"McCormick Gourmet","product":"McCormick Gourmet Chinese Five Spice Blend, 1.75 oz bottle","package_size":"1.75 oz","package_price_usd":8.13,"serving_grams":0.5,"calories":0,"protein_g":0,"carbs_g":0,"fat_g":0,"label_source_url":"https://www.mccormick.com/cdn/shop/files/25_MKC_GOURMET_GENERIC_NUTRITIONAL_FACTS-2026-04-06.png"}]'
  $lm = Import-LabelMacros $fsLabelRows
  $lmFs = $lm['Five-Spice Powder']
  CChk 'CLEAN TWIN macros still load from label-prices.json: the real Five-Spice row gives calories 0, protein 0, a 0.5 g serving and its McCormick label URL' (($null -ne $lmFs) -and ($lmFs.calories -eq 0) -and ($lmFs.protein_g -eq 0) -and ($lmFs.serving_grams -eq 0.5) -and ($lmFs.label_source_url -like 'https://www.mccormick.com/*')) ((@($lm.Keys)) -join ',')
  $lmPriceProps = @(@($lmFs.PSObject.Properties.Name) | Where-Object { $_ -like '*price*' })
  CChk 'MUST NOT FIRE the loaded label carries NO price field, so nothing below can price from it' (($null -ne $lmFs) -and ($lmPriceProps.Count -eq 0)) ($lmPriceProps -join ',')
  $lblRecipe = [pscustomobject]@{ slug = 'five-spice-turkey-noodle-bowls'; lines = @([pscustomobject]@{ item = 'Five-Spice Powder'; basis = 'label:McCormick Gourmet 1.75 oz' }, [pscustomobject]@{ item = 'Ground Turkey'; basis = 'board:ground-turkey:walmart' }) }
  $lblHits = Get-LabelBasisLines @($lblRecipe)
  CChk 'MUST FIRE  the engine refuses the real 2026-09-21 label line (Five-Spice Powder, label:McCormick Gourmet 1.75 oz) and only that line' ((@($lblHits).Count -eq 1) -and (@($lblHits)[0] -eq 'five-spice-turkey-noodle-bowls :: Five-Spice Powder :: label:McCormick Gourmet 1.75 oz')) (@($lblHits) -join ' | ')
  $okRecipe = [pscustomobject]@{ slug = 'turkey-wild-rice-casserole'; lines = @([pscustomobject]@{ item = 'Five-Spice Powder'; basis = 'board:five-spice-powder:nomem:Hy-Vee' }, [pscustomobject]@{ item = 'Wild Rice'; basis = 'ledger:wild-rice:Hy-Vee:2026-09-19' }, [pscustomobject]@{ item = 'Salt'; basis = 'feed:salt' }) }
  $okHits = Get-LabelBasisLines @($okRecipe)
  CChk 'MUST NOT FIRE a board-priced, a ledger-priced and a feed-priced line are not refused' (@($okHits).Count -eq 0) (@($okHits) -join ' | ')
  CChk 'CLEAN TWIN SizeToGrams still reads the real ledger size text as 16 oz, not as the 1 lb inside its parenthesis' ([math]::Abs((SizeToGrams '16 oz (1 lb stand up bag)') - (16 * 28.3495)) -lt 0.0001) ([string](SizeToGrams '16 oz (1 lb stand up bag)'))
  # ---- WHICH FLAG LINES PAGE (2026-09-21, queue 2026-09-20-6c14f6) -------------------------------------------
  # The four real shapes of 2026-09-21's db\cost-flags.txt, one line each: a catalogue-level allowlist refusal, a
  # HELD recipe's refused label, a LIVE recipe's unpriced title ingredient (turkey-wild-rice-casserole on 09-19,
  # before the ledger priced it) and a priced five-spice line marked ADVISORY.
  $sfLive = 'Turkey Wild Rice Casserole :: Wild Rice :: NO PRICE BASIS'
  $sfHeld = 'Harissa Chicken Rice Bowls :: Harissa Paste :: NO PRICE BASIS'
  $sfAdv  = 'Hong Kong-Style Baked Pork Chop Rice :: Five-Spice Powder :: MAPPED BID NOT ON ANY BOARD (five-spice-powder) :: ADVISORY, the line priced from label:McCormick Gourmet 1.75 oz'
  $sfCat  = 'ALLOWLIST :: no-board-price-ok.json :: BID REFUSED, NO CARRIAGE EVIDENCE x-bid [UNKNOWN: none]'
  $sfEntries = @(
    [pscustomobject]@{ slug = ''; line = $sfCat },
    [pscustomobject]@{ slug = 'harissa-chicken-rice-bowls'; line = $sfHeld },
    [pscustomobject]@{ slug = 'turkey-wild-rice-casserole'; line = $sfLive },
    [pscustomobject]@{ slug = 'hong-kong-style-baked-pork-chop-rice'; line = $sfAdv }
  )
  $sf = Split-CostFlags -Entries $sfEntries -Held @{ 'harissa-chicken-rice-bowls' = $true } -Live @{ 'turkey-wild-rice-casserole' = $true; 'hong-kong-style-baked-pork-chop-rice' = $true }
  CChk 'MUST FIRE  a LIVE recipe''s unpriced line still pages, FIRST and labelled LIVE (the line that must never go quiet)' ((@($sf.lines).Count -ge 1) -and ($sf.lines[0] -eq ('LIVE :: ' + $sfLive)) -and ($sf.live -eq 1)) ($sf.lines -join ' | ')
  CChk 'MUST NOT FIRE a HELD recipe''s unpriced line does not page' (@($sf.lines | Where-Object { $_ -like '*Harissa Chicken*' }).Count -eq 0) ($sf.lines -join ' | ')
  CChk 'MUST NOT FIRE an ADVISORY line (the bid is on no board but the line PRICED) does not page as unpriced' (@($sf.lines | Where-Object { $_ -like '*ADVISORY*' }).Count -eq 0) ($sf.lines -join ' | ')
  CChk 'CLEAN TWIN the held line and the advisory line are each KEPT, word for word, in their own set-aside list' ((@($sf.held).Count -eq 1) -and ($sf.held[0] -eq $sfHeld) -and (@($sf.advisory).Count -eq 1) -and ($sf.advisory[0] -eq $sfAdv)) ("held=$(@($sf.held) -join ' | ') advisory=$(@($sf.advisory) -join ' | ')")
  CChk 'CLEAN TWIN a catalogue-level line with no recipe keeps its exact bytes and still pages, after the LIVE lines' ((@($sf.lines).Count -eq 2) -and ($sf.lines[1] -eq $sfCat)) ($sf.lines -join ' | ')

  # END TO END. A pure split proves nothing about what reaches the file the chain pages on, so the REAL engine runs
  # as a child over a temp copy of the golden fixture (never the live db, never the fixture in place), twice.
  $gfx = Join-Path $here 'regression-inputs\golden'
  $e2e = Join-Path $env:TEMP ('crst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $null = New-Item -ItemType Directory $e2e -ErrorAction Stop
    Copy-Item (Join-Path $gfx 'inputs') (Join-Path $e2e 'inputs') -Recurse -Force -ErrorAction Stop
    $edb = Join-Path $e2e 'inputs\db'; $egout = Join-Path $e2e 'inputs\grocery-out'
    $eOut = Join-Path $e2e 'costed.json'; $eFlags = Join-Path $e2e 'cost-flags.txt'; $eStamp = Join-Path $e2e 'costed.stamp.json'
    $noBom = New-Object Text.UTF8Encoding($false)
    # RUN 1: zz-synthetic-flag-cases HELD (6 flag lines), ants-climbing-a-tree-pork-noodles PUBLISHED (unpriced Doubanjiang)
    [IO.File]::WriteAllText((Join-Path $edb 'held-recipes.json'), '{"held":[{"slug":"zz-synthetic-flag-cases","reason":"self-test"}]}', $noBom)
    [IO.File]::WriteAllText((Join-Path $edb 'published-hashes.json'), '{"ants-climbing-a-tree-pork-noodles":"SELFTEST"}', $noBom)
    $eLog = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DbRoot $edb -GroceryOut $egout -OutFile $eOut -FlagsFile $eFlags | ForEach-Object { [string]$_ })
    $eRc = $LASTEXITCODE
    $eF = @(); if (Test-Path $eFlags) { $eF = @(Get-Content $eFlags | Where-Object { $_ }) }
    $eS = $null; if (Test-Path $eStamp) { $eS = Get-Content $eStamp -Raw | ConvertFrom-Json }
    CChk 'END-TO-END MUST FIRE  a PUBLISHED recipe''s unpriced Doubanjiang line is in cost-flags.txt, first, labelled LIVE' (($eRc -eq 0) -and ($eF.Count -ge 1) -and ($eF[0] -like 'LIVE :: Ants Climbing a Tree Pork Noodles :: Doubanjiang :: *') -and ($eF -contains 'LIVE :: Ants Climbing a Tree Pork Noodles :: Doubanjiang :: NO PRICE BASIS')) ("rc=$eRc first=$(if($eF.Count){$eF[0]}else{'(empty)'})")
    CChk 'END-TO-END MUST NOT FIRE a HELD recipe''s six flag lines are not in cost-flags.txt' (@($eF | Where-Object { $_ -like '*ZZ Synthetic Flag Cases*' }).Count -eq 0) ($eF -join ' | ')
    CChk 'END-TO-END CLEAN TWIN the held recipe is REPORTED: a HELD count line, and its 6 lines kept in costed.stamp.json' ((@($eLog | Where-Object { $_ -like 'cost-recipes: HELD 1 recipe(s)*' }).Count -eq 1) -and ($null -ne $eS) -and ([int]$eS.flags_set_aside.held_recipes -eq 1) -and (@($eS.flags_set_aside.held_lines).Count -eq 6)) ("held-lines=$(if($eS){@($eS.flags_set_aside.held_lines).Count}else{'no stamp'}) log=$((@($eLog | Where-Object { $_ -like 'cost-recipes: HELD*' })) -join ' | ')")
    CChk 'END-TO-END CLEAN TWIN the held recipe is still COSTED: costed.json is byte-identical to the frozen golden baseline' ((Test-Path $eOut) -and ((Get-FileHash $eOut).Hash -eq (Get-FileHash (Join-Path $gfx 'expected\costed.json')).Hash)) 'costed.json moved'
    # The fixture's db\label-prices.json still carries PRICED rows (it is frozen), so this is the end-to-end proof that
    # the engine reads none of them: not one costed line may carry a label: basis, and the run must still exit 0.
    $fxLab = Get-Content (Join-Path $edb 'label-prices.json') -Raw | ConvertFrom-Json
    $fxPriced = @(@($fxLab) | Where-Object { $null -ne $_ -and $_.package_price_usd -gt 0 }).Count
    $eDoc = $null; if (Test-Path $eOut) { $eDoc = Get-Content $eOut -Raw | ConvertFrom-Json }
    $eLbl = Get-LabelBasisLines @($eDoc)
    CChk ('END-TO-END MUST FIRE  with ' + $fxPriced + ' priced label row(s) in the fixture, not one costed line carries a label: basis') (($fxPriced -gt 0) -and ($eRc -eq 0) -and ($null -ne $eDoc) -and (@($eLbl).Count -eq 0)) (@($eLbl) -join ' | ')
    # RUN 2: nothing held or published; a CARRIED ledger read prices the synthetic off-board bid, so its MAPPED BID
    # line becomes ADVISORY while a genuinely unpriced line of the same recipe keeps paging.
    Remove-Item (Join-Path $edb 'held-recipes.json'), (Join-Path $edb 'published-hashes.json') -Force
    $cj = Join-Path $egout 'carriage.json'
    $cdoc = Get-Content $cj -Raw | ConvertFrom-Json
    $cdoc.bids | Add-Member -NotePropertyName 'zz-not-on-any-board' -NotePropertyValue ([pscustomobject]@{ verdict = 'CARRIED'; store = 'Hy-Vee'; item = 'ZZ self-test shelf read'; size = '16 oz'; price = 1.6; product_id = '0'; as_of = (Get-Date).ToString('yyyy-MM-dd') })
    [IO.File]::WriteAllText($cj, ($cdoc | ConvertTo-Json -Depth 10), $noBom)
    $eLog2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DbRoot $edb -GroceryOut $egout -OutFile $eOut -FlagsFile $eFlags -LedgerMaxAgeDays 90 | ForEach-Object { [string]$_ })
    $eRc2 = $LASTEXITCODE
    $eF2 = @(); if (Test-Path $eFlags) { $eF2 = @(Get-Content $eFlags | Where-Object { $_ }) }
    $eS2 = $null; if (Test-Path $eStamp) { $eS2 = Get-Content $eStamp -Raw | ConvertFrom-Json }
    CChk 'END-TO-END MUST FIRE  a genuinely unpriced line on that recipe still pages, unlabelled (nothing is published this run)' (($eRc2 -eq 0) -and ($eF2 -contains 'ZZ Synthetic Flag Cases :: ZZ Unpriced Item :: NO PRICE BASIS') -and (@($eF2 | Where-Object { $_ -like 'LIVE :: *' }).Count -eq 0)) ("rc=$eRc2 " + ($eF2 -join ' | '))
    CChk 'END-TO-END MUST NOT FIRE the MAPPED BID line of a bid the ledger PRICED does not page' (@($eF2 | Where-Object { $_ -like '*ZZ Offboard Bid :: MAPPED BID*' }).Count -eq 0) ($eF2 -join ' | ')
    $advKept = @(); if ($eS2) { $advKept = @($eS2.flags_set_aside.advisory_lines) }
    CChk 'END-TO-END CLEAN TWIN that line is KEPT as ADVISORY in the stamp, naming the ledger basis that priced it' (($advKept.Count -eq 1) -and ($advKept[0] -like 'ZZ Synthetic Flag Cases :: ZZ Offboard Bid :: MAPPED BID NOT ON ANY BOARD (zz-not-on-any-board) :: ADVISORY, the line priced from ledger:zz-not-on-any-board:Hy-Vee:*')) ($advKept -join ' | ')
  } catch {
    CChk 'END-TO-END the engine child runs completed' $false $_.Exception.Message
  } finally {
    if (Test-Path $e2e) { Remove-Item $e2e -Recurse -Force -ErrorAction SilentlyContinue }
  }
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
# HELD AND LIVE, read where they are owned (2026-09-21, queue 2026-09-20-6c14f6). Both files belong to this
# module - engine\publish.ps1 writes published-hashes.json and refuses any slug held-recipes.json names - so the
# engine reads them to label its own flag lines (Split-CostFlags above). A file that cannot be parsed is not an
# empty one: an unreadable held list treats NOTHING as held, so every line pages (the loud direction), and says so.
$HELDSLUGS = @{}; $LIVESLUGS = @{}
$heldPath = Join-Path $db 'held-recipes.json'
if(Test-Path $heldPath){
  try { foreach($h in @((Get-Content $heldPath -Raw | ConvertFrom-Json).held)){ if($h -and $h.slug){ $HELDSLUGS[[string]$h.slug] = $true } } }
  catch { $HELDSLUGS = @{}; Write-Output 'cost-recipes: WARNING - db\held-recipes.json could not be parsed, so NO recipe is treated as held this run and every flag line pages' }
}
$livePath = Join-Path $db 'published-hashes.json'
if(Test-Path $livePath){
  try { foreach($lp in (Get-Content $livePath -Raw | ConvertFrom-Json).PSObject.Properties){ $LIVESLUGS[[string]$lp.Name] = $true } }
  catch { $LIVESLUGS = @{}; Write-Output 'cost-recipes: WARNING - db\published-hashes.json could not be parsed, so no flag line is labelled LIVE this run' }
}
$script:registerEst=0
$out=@(); $costFlags=New-Object System.Collections.Generic.List[string]
$flagOwner = @{}   # index into $costFlags -> the slug of the recipe that wrote it; catalogue-level lines have none
foreach($b in $nbBad){ $costFlags.Add(('ALLOWLIST :: no-board-price-ok.json :: BID REFUSED, NO CARRIAGE EVIDENCE ' + $b)) }
foreach($r in $computed){
  $flagStart = $costFlags.Count   # every flag this recipe writes lands at or after here; tagged at the end of the body
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
    $mappedIdx = -1   # where THIS ingredient's MAPPED BID flag sits, if it wrote one (same every-path rule as above)
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
      else { $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: MAPPED BID NOT ON ANY BOARD (' + $bid + ')')); $mappedIdx = $costFlags.Count - 1 }
    }
    # THE LABEL FALLBACK IS RETIRED (2026-09-21, Brad's ruling; see Import-LabelMacros). It stood here, after the
    # feed and before the carriage ledger, and priced a line from db\label-prices.json when Omaha was proven to
    # stock the item. On the day it was retired exactly 7 live lines used it, all Five-Spice Powder at a July
    # walmart.com $8.13, and all 7 had moved to the board's store-fetched Hy-Vee cell ($9.99 / 1.75 oz, read
    # 2026-09-21) before this line was removed: plan-2026-09-21-2.json measured zero live label lines first.
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
    # ADVISORY, NOT UNPRICED (2026-09-21, queue 2026-09-20-6c14f6). The MAPPED BID flag is written before the label
    # and ledger fallbacks run, so it cannot know whether the line went on to price. When it did, the flag is kept
    # WITH the basis that priced it, and Split-CostFlags sets it aside rather than paging it as an unpriced line:
    # on 2026-09-21 eight such lines (seven five-spice, one wild rice) read as unpriced, and every one had priced.
    if($null -ne $ppg -and $mappedIdx -ge 0){ $costFlags[$mappedIdx] = $costFlags[$mappedIdx] + ' :: ADVISORY, the line priced from ' + $basis }
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
      elseif($LABELPKG.ContainsKey($ing.item)){ $pg=@{g=$LABELPKG[$ing.item].pkg_g; label=$LABELPKG[$ing.item].desc} }
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
  for($fk = $flagStart; $fk -lt $costFlags.Count; $fk++){ $flagOwner[$fk] = [string]$r.slug }
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
# NO LINE PRICES FROM A LABEL, EVER AGAIN (2026-09-21, Brad's ruling). Nothing above loads a label price, so this
# can only fire if a label fallback creeps back in, or a -Slugs splice carries an old row forward. Either way the
# costs are NOT written: a recipe page priced off a July walmart.com read is the defect this closes, and failing
# loud here pages the chain ("Recipe recost failed") instead of publishing it.
$labelBased = Get-LabelBasisLines $out
if (@($labelBased).Count -gt 0) {
  Write-Output ('cost-recipes: REFUSED - ' + @($labelBased).Count + ' line(s) priced from a label: basis, which Brad ruled out on 2026-09-21 ("The pricing must be fetched from a store always"). costed.json was NOT written:')
  foreach ($x in @($labelBased)) { Write-Output ('  ' + $x) }
  exit 2
}
$out | ConvertTo-Json -Depth 7 | Out-File $costedPath -Encoding utf8

# WHICH FLAG LINES PAGE (2026-09-21, queue 2026-09-20-6c14f6). Each line carries the recipe that wrote it, and
# Split-CostFlags decides: HELD and ADVISORY lines are set aside (kept in the stamp below, counted here), LIVE lines
# lead cost-flags.txt. The counts print on every run that has any, so nothing set aside can vanish silently.
$flagEntries = @()
for($fk = 0; $fk -lt $costFlags.Count; $fk++){
  $flagEntries += [pscustomobject]@{ slug = $(if($flagOwner.ContainsKey($fk)){ $flagOwner[$fk] } else { '' }); line = $costFlags[$fk] }
}
$flagSplit = Split-CostFlags -Entries $flagEntries -Held $HELDSLUGS -Live $LIVESLUGS
$heldInRun = @($computed | Where-Object { $HELDSLUGS.ContainsKey([string]$_.slug) }).Count
if($HELDSLUGS.Count -gt 0){ Write-Output ("cost-recipes: HELD {0} recipe(s) not costed as live, by design (db\held-recipes.json) - still costed, and their {1} flag line(s) are set aside in costed.stamp.json, not paged" -f $heldInRun, @($flagSplit.held).Count) }
if(@($flagSplit.advisory).Count -gt 0){ Write-Output ("cost-recipes: ADVISORY {0} flag line(s) set aside - the bid is on no board but the line priced from a label or the carriage ledger" -f @($flagSplit.advisory).Count) }
if($flagSplit.live -gt 0){ Write-Output ("cost-recipes: LIVE {0} flag line(s) on published recipe(s) lead cost-flags.txt" -f $flagSplit.live) }

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
  $stamp['flags_set_aside'] = [ordered]@{
    held_recipes   = $heldInRun
    held_lines     = @($flagSplit.held)
    advisory_lines = @($flagSplit.advisory)
    live_lines     = $flagSplit.live
    note           = 'Flag lines this recost wrote and deliberately kept OUT of cost-flags.txt, the file the chain pages on: a HELD recipe''s lines (taken down by design, still costed) and ADVISORY lines (bid on no board, the line still priced). The rule is Split-CostFlags in engine\cost-recipes.ps1.'
  }
  ($stamp | ConvertTo-Json -Depth 5) | Set-Content $stampPath -Encoding UTF8
} catch {
  # Never kill a cost run over its own stamp. A recost with no stamp is degraded; a recost KILLED BY
  # its stamp is a lost board - the same rule run-log-lib states for logging.
  Write-Output ('cost-recipes: could not write the board stamp (not fatal): ' + $_.Exception.Message)
}
$flagSplit.lines | Out-File $flagsPath -Encoding utf8
if($script:registerEst -gt 0){ Write-Output ("register-estimate lines (allowlisted): " + $script:registerEst) }
Write-Output ("costed {0} recipes; flags {1}" -f @($out).Count, $costFlags.Count)