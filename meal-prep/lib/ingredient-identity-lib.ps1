# ingredient-identity-lib.ps1 - does a recipe ingredient's commodity id name the SAME FOOD the board prices?
#
# WHY (2026-09-22, grocery/triage-plans/plan-2026-09-22-9.json, discovered:recipe-ingredient-identity).
# The recipe vocabulary (db\ingredients.json `bid`, and the mapper's ingredient-resolutions `item_id`) is a
# SECOND, hand-written statement of what a commodity IS, and nothing reconciled it with the first (the
# commodity's rules and the row that wins its cell). Three shapes were live on 8 paid recipes:
#   - a DIFFERENT FOOD whose own commodity exists: Shallots bid onions, Pork Chorizo bid ground-pork;
#   - a DERIVED yield row whose buy package was in the parent's grams: Orange Zest bought as 6.3 lb of oranges;
#   - a UNION commodity whose winning row is the other member: a thigh line priced by a drumstick bag.
# Brad's rulings the same day: every ingredient is carried in Omaha with a pipeline-fetched price or the
# recipe is not live; NO substitute food, labelled or silent; a yield from a parent food (zest by the
# orange's real weight) is the same food.
#
# THE RELATION VOCABULARY. A row's `relation` is `same` (the default, and what an absent field means) or
# `derived` (a yield of the parent food named by its bid: `parent_units_per_purchase` and
# `yield_g_per_parent_unit` are required, and buy_pkg_g must equal their product). Anything else is a
# finding, and `substitute` is named as one on purpose: Brad ruled it out. A row whose bid is deliberately
# MORE specific than the matcher (High Fiber Tortilla and the like) carries `identity_reviewed` with the reason.
#
# Dot-sourced. No param() block (a dot-sourced param() block resets the caller's parameters under PS 5.1).

# A PLURAL IS THE SAME WORD WHEN LOOKING (2026-09-22). Naive on purpose, the same rule knowledge-search
# applies: strip a regular trailing -s (-ies to -y, -oes to -o) and keep ss/us/is/as endings (and -os on a word of 4 or fewer letters). Used by
# ingredient-vocab's candidate search too, so there is one copy of the rule.
function Get-TokenStem {
  param([string]$Token)
  $t = [string]$Token
  if ($t.Length -le 3) { return $t }
  if ($t.EndsWith('ies')) { return $t.Substring(0, $t.Length - 3) + 'y' }
  if ($t.EndsWith('oes')) { return $t.Substring(0, $t.Length - 2) }
  foreach ($keep in @('ss', 'us', 'is', 'as')) { if ($t.EndsWith($keep)) { return $t } }
  # -os is a plural on food words (jalapenos, avocados, tacos); a 4-letter -os word (kudos-short forms) is kept.
  if ($t.EndsWith('os') -and $t.Length -le 4) { return $t }
  if ($t.EndsWith('s')) { return $t.Substring(0, $t.Length - 1) }
  return $t
}

# Words that describe a FORM or a CUT QUALITY, never the food. Dropping them is what lets
# "Boneless Skinless Chicken Breast" be asked about `breast`.
$script:IdentityQualifierWords = @('fresh','raw','large','small','medium','whole','boneless','skinless','bone','skin','in','on',
  'of','and','the','a','with','chopped','diced','sliced','minced','organic','plain','low','reduced','sodium','fat','lean',
  'extra','virgin','uncooked','style','lb','oz','each','free','no','salt','added','light','unsalted','salted')
# A generic class word as the HEAD asks the word before it instead: "Mozzarella Cheese" is asked about
# `mozzarella`, "Soy Sauce" about `soy`, "Chicken Broth" about `chicken`.
$script:IdentityGenericHeads = @('cheese','sauce','seasoning','spice','mix','oil','juice','broth','stock','paste','powder','blend')

function ConvertTo-IdentityFoldedText {
  <# The text with its diacritics folded (e-grave -> e, n-tilde -> n): FormD, drop NonSpacingMark, back to FormC.
     The same shape as grocery/pull-regular-bakers-api.ps1's transliteration. Without it the ASCII strip below turned
     'Gruyere' spelled with an e-grave into 'gruy re', which never names gruyere (2026-09-27-8161ce). Used by the
     NAME TESTS only: ConvertTo-IdentityStoreKey and ConvertTo-IdentityProductKey stay unfolded so no mark key moves. #>
  param([string]$Text)
  if (-not $Text) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $Text.Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
  }
  return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-IdentityTokens {
  param([string]$Text)
  if (-not $Text) { return @() }
  $t = ((ConvertTo-IdentityFoldedText $Text).ToLower() -replace '[^a-z0-9 ]', ' ')
  $out = @()
  foreach ($w in ($t -split '\s+')) { if ($w) { $out += (Get-TokenStem $w) } }
  return $out
}

function Get-IdentityHeadWord {
  <# The word a pricing row MUST carry for an ingredient: its last non-qualifier word, or the word before a
     generic class head. '' when the name has no such word. #>
  param([string]$Name)
  $core = @()
  foreach ($w in (Get-IdentityTokens $Name)) { if ($script:IdentityQualifierWords -notcontains $w -and $w -notmatch '^\d+$') { $core += $w } }
  if ($core.Count -eq 0) { return '' }
  $head = [string]$core[$core.Count - 1]
  # Walk back past EVERY generic class word: 'Ranch Seasoning Mix' is asked about ranch.
  $i = $core.Count - 1
  while ($i -gt 0 -and $script:IdentityGenericHeads -contains [string]$core[$i]) { $i-- }
  return [string]$core[$i]
}

function Get-IdentityRelation {
  param($Row)
  $p = $Row.PSObject.Properties['relation']
  if ($null -eq $p -or $null -eq $p.Value -or [string]$p.Value -eq '') { return 'same' }
  return ([string]$p.Value).ToLower()
}

function Test-DerivedBasis {
  <# $null when a derived row's buy package is one purchase of the parent's yield; otherwise the reason.
     The comparison is exact to 1e-9: every field here is a small decimal the file states, and the rule is
     equality, not a tolerance (buy_pkg_g 6 against 6.0 x 1 is clean; 6.5 is a finding). #>
  param($Row)
  foreach ($f in 'parent_units_per_purchase', 'yield_g_per_parent_unit', 'buy_pkg_g') {
    $p = $Row.PSObject.Properties[$f]
    if ($null -eq $p -or $null -eq $p.Value -or [string]$p.Value -eq '') { return ('derived row has no ' + $f) }
  }
  $want = [double]$Row.parent_units_per_purchase * [double]$Row.yield_g_per_parent_unit
  $have = [double]$Row.buy_pkg_g
  if ([Math]::Abs($have - $want) -gt 1e-9) {
    return ('buy_pkg_g ' + $have + ' is not yield ' + [double]$Row.yield_g_per_parent_unit + ' g x ' + [double]$Row.parent_units_per_purchase + ' parent unit(s) = ' + $want + ': one purchase is priced as ' + [Math]::Round($have / [Math]::Max($want, 1e-9), 2) + ' parents')
  }
  return $null
}

function Test-PricingRowNamesIngredient {
  <# $true when a board row that prices an ingredient line names the ingredient's own head word. A derived
     row is asked about its PARENT (the bid), because zest is priced by the orange. #>
  param([string]$Ingredient, [string]$ProductName, [string]$Relation = 'same', [string]$Bid = '')
  $ask = if ($Relation -eq 'derived' -and $Bid) { Get-IdentityHeadWord ($Bid -replace '-', ' ') } else { Get-IdentityHeadWord $Ingredient }
  if (-not $ask) { return $true }
  $toks = @(Get-IdentityTokens $ProductName)
  if ($toks -contains $ask) { return $true }
  # A compound the store splits ('Cornstarch' against 'Corn Starch') is the same word: look in the joined name.
  $joined = ((ConvertTo-IdentityFoldedText ([string]$ProductName)).ToLower() -replace '[^a-z0-9]', '')
  return ($ask.Length -ge 5 -and $joined.Contains($ask))
}

function Test-IdentitySameAs {
  <# A REVIEWED same-food record scoped to ONE product spelling (2026-09-25, queue 2026-09-23-9999c0). A row's
     `identity_same_as` is an array of { product, reason }: `product` a case-insensitive regex over the pricing
     product's name, `reason` why that spelling is the ingredient's own food ("Crushed Red Pepper" IS red pepper
     flakes). Unlike `identity_reviewed`, which silences every product for the row, this silences only the
     spellings it names, so the next wrong product on the same cell is still a UNION-ROW. An entry with no
     reason, no product, or a pattern that does not parse silences nothing. #>
  param($Row, [string]$ProductName)
  if (-not $Row -or $null -eq $Row.PSObject.Properties['identity_same_as']) { return $false }
  foreach ($e in @($Row.identity_same_as)) {
    if (-not $e -or [string]::IsNullOrWhiteSpace([string]$e.product) -or [string]::IsNullOrWhiteSpace([string]$e.reason)) { continue }
    try { if ([regex]::IsMatch([string]$ProductName, [string]$e.product, 'IgnoreCase', [TimeSpan]::FromSeconds(1))) { return $true } } catch { continue }
  }
  return $false
}

function ConvertTo-IdentityStoreKey { param([string]$S) return (([string]$S).ToLower() -replace '[^a-z0-9]', '') }

function Get-IdentityBoardIndex {
  <# id -> (store key -> product name) over a comparison board's rows (the recipe board has the same shape).
     `cells` keeps EVERY (store key, product) the row lists, in order, because a store can list two products
     and the map above keeps only the last: check (d) asks about each one. #>
  param($Board)
  $ix = @{}
  foreach ($r in @($Board.comparison)) {
    $m = @{}
    $cells = New-Object System.Collections.ArrayList
    foreach ($s in @($r.stores)) {
      $nm = [string]$s.item; if (-not $nm) { $nm = [string]$s.name }
      $sk = ConvertTo-IdentityStoreKey ([string]$s.store)
      $m[$sk] = $nm
      if ($nm) { [void]$cells.Add([pscustomobject]@{ store = [string]$s.store; key = $sk; product = $nm }) }
    }
    $ix[[string]$r.id] = [pscustomobject]@{ stores = $m; crown_store = [string]$r.cheapest_store; cells = $cells.ToArray() }
  }
  return $ix
}

function Find-IdentityBoardProduct {
  param($BoardIndex, [string]$Id, [string]$StoreKey)
  if (-not $BoardIndex.ContainsKey($Id)) { return $null }
  $m = $BoardIndex[$Id].stores
  if ($m.ContainsKey($StoreKey)) { return [string]$m[$StoreKey] }
  foreach ($k in $m.Keys) { if ($k.StartsWith($StoreKey) -or $StoreKey.StartsWith($k)) { return [string]$m[$k] } }
  return $null
}

function Get-IngredientIdentityFindings {
  <# Checks (a) and (b) over the vocabulary and the live rules; the board half is Get-IngredientCellFindings (check d).
     $Resolve is a scriptblock name -> commodity id or $null (the live matcher in production, a frozen one in
     the self-test). $WeeklyIds is the set of ids the weekly rules can route to. Returns objects with a stable
     `key` (what the ratchet counts), `kind`, `item` and `detail`. #>
  param($Rows, [scriptblock]$Resolve, $WeeklyIds)
  $out = New-Object System.Collections.ArrayList
  foreach ($r in @($Rows)) {
    if (-not $r.PSObject.Properties['item']) { continue }
    $item = [string]$r.item
    $bidP = $r.PSObject.Properties['bid']; if ($null -eq $bidP -or -not $bidP.Value) { continue }
    $bid = [string]$bidP.Value
    $rel = Get-IdentityRelation $r
    $reviewed = ($null -ne $r.PSObject.Properties['identity_reviewed'] -and [string]$r.identity_reviewed -ne '')
    switch ($rel) {
      'same' {
        if (-not $WeeklyIds.Contains($bid)) { break }   # recipe-board-only id: not routable against the weekly rules
        $hit = & $Resolve $item
        if ($reviewed) { break }
        if (-not $hit) { [void]$out.Add([pscustomobject]@{ key = ('unrouted|' + $item + '|' + $bid); kind = 'UNROUTED'; item = $item; detail = ('"' + $item + '" routes to no weekly commodity; bid ' + $bid + ' is unverified') }) }
        elseif ([string]$hit -ne $bid) { [void]$out.Add([pscustomobject]@{ key = ('proxy|' + $item + '|' + $bid + '|' + $hit); kind = 'PROXY'; item = $item; detail = ('"' + $item + '" is bid ' + $bid + ' but its own name routes to ' + $hit + ': priced as a different food') }) }
      }
      'derived' {
        $why = Test-DerivedBasis $r
        if ($why) { [void]$out.Add([pscustomobject]@{ key = ('derived|' + $item); kind = 'DERIVED-BASIS'; item = $item; detail = ('"' + $item + '" ' + $why) }) }
      }
      'substitute' { [void]$out.Add([pscustomobject]@{ key = ('substitute|' + $item + '|' + $bid); kind = 'SUBSTITUTE'; item = $item; detail = ('"' + $item + '" is declared a substitute for ' + $bid + '; Brad ruled no substitute of any kind (2026-09-22): bring the food onto the board or hold the recipe') }) }
      default { [void]$out.Add([pscustomobject]@{ key = ('relation|' + $item); kind = 'UNKNOWN-RELATION'; item = $item; detail = ('"' + $item + '" relation "' + $rel + '" is not same or derived') }) }
    }
  }
  # Check (c), the one-store-per-line UNION-ROW test, was RETIRED on 2026-09-26 (queue 2026-09-22-5a9676): it read
  # only the costed basis store, skipped the recipe-board and nomem lines, never read the alias-priced lines and keyed
  # without the product. Get-IngredientCellFindings (check d) replaces it; every cell it reads includes the basis cell.
  return $out.ToArray()
}

function Resolve-IdentityPricedId {
  <# The board id a costed line is priced from, or $null for a basis no board prices (label:, ledger:, none).
     board:<id>:<anything> is that id on a board (the store part, recipeboard-* or nomem:* included, is ignored:
     check (d) reads every store of the cell). feed:<id> prices through grocery/recipe-floor-id-map.json, so it is
     resolved through $AliasMap (id -> board id; an id with no entry prices as itself). With no map a feed: line
     cannot be resolved and comes back with via 'feed-unmapped', which the caller counts BLIND. #>
  param([string]$Basis, $AliasMap)
  if ($Basis -match '^board:([^:]+):') { return [pscustomobject]@{ id = $Matches[1]; via = 'board' } }
  if ($Basis -match '^feed:([^:]+)$') {
    # A pack-form suffix ('feed:cannellini-beans+drained') is a costing note, not part of the id.
    $fid = $Matches[1] -replace '\+.*$', ''
    if ($null -eq $AliasMap) { return [pscustomobject]@{ id = $fid; via = 'feed-unmapped' } }
    if ($AliasMap.ContainsKey($fid)) { return [pscustomobject]@{ id = [string]$AliasMap[$fid]; via = 'feed-alias' } }
    return [pscustomobject]@{ id = $fid; via = 'feed' }
  }
  return $null
}

function ConvertTo-IdentityProductKey { param([string]$S) return (([string]$S).ToLower() -replace '[^a-z0-9]', '') }

function Get-IngredientCellFindings {
  <# CHECK (d), 2026-09-26 (queue 2026-09-22-5a9676, grocery/triage-plans/plan-2026-09-26-2.json). The recipe card and
     compute-v2's cheapest_ps take the cheapest whole package across EVERY store cell of a line's priced id, so the
     question is asked of every cell, not of the one store the engine costed. For each distinct (item, priced id) over
     the costed lines: the cell is the comparison row, else the recipe-board row; for EVERY store product in it,
     identity_reviewed, identity_same_as and the head-word test apply exactly as check (c) applied them (a derived row
     is asked about its parent, the priced id). The key carries the product, so a standing key never hides the NEXT
     wrong product at the same cell: 'cell|<item>|<priced id>|<store key>|<product key>'.
     BLIND, never ok: a pair whose id is on neither board, a recipe-board line when no recipe board was passed, and a
     feed: line when no alias map was passed. $RecipeBoardIndex / $AliasMap are $null when not passed.
     Returns { findings; pairs; lines; cells; reviewed; blind (item, id, why); by_via (hashtable) }. #>
  param($Rows, $Costed, $BoardIndex, $RecipeBoardIndex = $null, $AliasMap = $null)
  $byItem = @{}
  foreach ($r in @($Rows)) { if ($r.PSObject.Properties['item']) { $byItem[[string]$r.item] = $r } }
  $pairs = [ordered]@{}
  $nLines = 0
  foreach ($rec in @($Costed)) {
    foreach ($ln in @($rec.lines)) {
      $basis = [string]$ln.basis
      $p = Resolve-IdentityPricedId -Basis $basis -AliasMap $AliasMap
      if ($null -eq $p) { continue }
      $nLines++
      $item = [string]$ln.item
      $pk = if ($p.via -eq 'feed-unmapped') { $item + '|feed:' + $p.id } else { $item + '|' + $p.id }
      if (-not $pairs.Contains($pk)) { $pairs[$pk] = [pscustomobject]@{ item = $item; id = [string]$p.id; via = [string]$p.via; basis = $basis; lines = 0; slugs = New-Object 'System.Collections.Generic.HashSet[string]' } }
      $pairs[$pk].lines++
      [void]$pairs[$pk].slugs.Add([string]$rec.slug)
    }
  }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $out = New-Object System.Collections.ArrayList
  $blind = New-Object System.Collections.ArrayList
  $byVia = @{}
  $nCells = 0; $nReviewed = 0
  foreach ($pr in $pairs.Values) {
    if (-not $byVia.ContainsKey($pr.via)) { $byVia[$pr.via] = 0 }
    $byVia[$pr.via]++
    if ($pr.via -eq 'feed-unmapped') { [void]$blind.Add([pscustomobject]@{ item = $pr.item; id = $pr.id; why = 'feed: line and no -AliasMapFile to resolve it' }); continue }
    $cell = $null
    if ($BoardIndex.ContainsKey($pr.id)) { $cell = $BoardIndex[$pr.id] }
    elseif ($null -ne $RecipeBoardIndex -and $RecipeBoardIndex.ContainsKey($pr.id)) { $cell = $RecipeBoardIndex[$pr.id] }
    if ($null -eq $cell) {
      $why = if ($null -eq $RecipeBoardIndex) { 'not on the comparison board and no -RecipeBoardFile' } else { 'on neither board' }
      [void]$blind.Add([pscustomobject]@{ item = $pr.item; id = $pr.id; why = $why }); continue
    }
    $row = $byItem[$pr.item]
    if ($row -and $null -ne $row.PSObject.Properties['identity_reviewed'] -and [string]$row.identity_reviewed -ne '') { $nReviewed++; continue }
    $rel = if ($row) { Get-IdentityRelation $row } else { 'same' }
    foreach ($c in @($cell.cells)) {
      $nCells++
      if (Test-IdentitySameAs -Row $row -ProductName $c.product) { continue }
      if (Test-PricingRowNamesIngredient -Ingredient $pr.item -ProductName $c.product -Relation $rel -Bid $pr.id) { continue }
      $key = 'cell|' + $pr.item + '|' + $pr.id + '|' + $c.key + '|' + (ConvertTo-IdentityProductKey $c.product)
      if (-not $seen.Add($key)) { continue }
      $ask = if ($rel -eq 'derived') { Get-IdentityHeadWord ($pr.id -replace '-', ' ') } else { Get-IdentityHeadWord $pr.item }
      [void]$out.Add([pscustomobject]@{ key = $key; kind = 'CELL'; item = $pr.item; detail = ('"' + $pr.item + '" (' + $pr.lines + ' line(s), ' + $pr.slugs.Count + ' recipe(s), ' + $pr.basis + ') can be priced at ' + $c.store + ' by "' + $c.product + '" in cell ' + $pr.id + ', which does not name ' + $ask) })
    }
  }
  return [pscustomobject]@{ findings = $out.ToArray(); pairs = $pairs.Count; lines = $nLines; cells = $nCells; reviewed = $nReviewed; blind = $blind.ToArray(); by_via = $byVia }
}

function Test-ReuseIdentity {
  <# The mapper's write-time check for ONE term -> commodity id. Returns $null when it may be recorded, or
     the reason it may not: the term's own name routes to a DIFFERENT live commodity, or the row that wins
     that commodity's cell does not name the term's food. $BoardIndex may be $null (no board to read): then
     only the routing half runs, and the caller says so. #>
  param([string]$Term, [string]$Id, [scriptblock]$Resolve, $WeeklyIds, $BoardIndex = $null)
  if (-not $WeeklyIds.Contains($Id)) { return $null }
  $hit = & $Resolve $Term
  if ($hit -and [string]$hit -ne $Id) { return ('"' + $Term + '" routes to ' + $hit + ', not ' + $Id + ': that would price it as a different food') }
  if ($null -ne $BoardIndex -and $BoardIndex.ContainsKey($Id)) {
    $b = $BoardIndex[$Id]
    $prod = Find-IdentityBoardProduct $BoardIndex $Id (ConvertTo-IdentityStoreKey $b.crown_store)
    if ($prod -and -not (Test-PricingRowNamesIngredient -Ingredient $Term -ProductName $prod)) {
      return ('the row that wins ' + $Id + ' today is "' + $prod + '" (' + $b.crown_store + '), which does not name ' + (Get-IdentityHeadWord $Term) + ': ' + $Id + ' is a union and "' + $Term + '" is one member of it')
    }
  }
  return $null
}

function Get-IdentityRouteChanges {
  <# THE PUSH-TIME ROUTE CHECK (-RoutesOnly; queue 2026-09-26-177835, plan-2026-09-26-2). Check (a) only, over the
     vocabulary and the rules, with no board and no costed lines, compared per (item, bid) PAIR with the proxy| and
     unrouted| keys of the committed mark. A commodity registration and the vocabulary row naming the same food are
     two records written by two tools on two days (4880ebc98 registered lo-mein-noodles while 'Lo Mein Noodles' still
     bid egg-noodles), so the pair comparison is what lets a push that moves a row off its bid carry its rebid.
       REFUSE  a pair with no mark key now has one (on-bid -> off-bid, or on-bid -> routes nowhere)
       REFUSE  a pair marked unrouted now routes to another id (unrouted -> proxy)
       REFUSE  a pair marked proxy now routes to a DIFFERENT other id (a new commodity took the name again)
       SPEAK   a pair marked proxy now routes nowhere (proxy -> unrouted): weaker, never a refusal
       silent  a pair whose mark key is unchanged, and every fall
     Returns objects { verdict; item; bid; route; detail }. $MarkKeys is the mark's key list; keys of other kinds
     (union|, derived|, substitute|) are ignored here, so the daily RISE semantics are untouched. #>
  param($Rows, [scriptblock]$Resolve, $WeeklyIds, [string[]]$MarkKeys)
  $mark = @{}
  foreach ($k in @($MarkKeys)) {
    $p = ([string]$k) -split '\|'
    if ($p[0] -eq 'unrouted' -and $p.Count -ge 3) { $mark[$p[1] + '|' + $p[2]] = [pscustomobject]@{ kind = 'UNROUTED'; hit = '' } }
    elseif ($p[0] -eq 'proxy' -and $p.Count -ge 4) { $mark[$p[1] + '|' + $p[2]] = [pscustomobject]@{ kind = 'PROXY'; hit = [string]$p[3] } }
  }
  $found = Get-IngredientIdentityFindings -Rows $Rows -Resolve $Resolve -WeeklyIds $WeeklyIds
  $out = New-Object System.Collections.ArrayList
  foreach ($x in @($found | Where-Object { $null -ne $_ })) {
    if ($x.kind -ne 'PROXY' -and $x.kind -ne 'UNROUTED') { continue }
    $p = ([string]$x.key) -split '\|'
    $item = [string]$p[1]; $bid = [string]$p[2]
    $route = if ($x.kind -eq 'PROXY') { [string]$p[3] } else { '' }
    $was = $mark[$item + '|' + $bid]
    $fix = if ($route) { 'meal-prep/pipeline/rebid-ingredient.ps1 -Item ''' + $item + ''' -ToBid ' + $route + ' (in the same push)' } else { 'give the commodity an include that names it, or rebid the row, in the same push' }
    $verdict = ''; $why = ''
    if ($null -eq $was) {
      $verdict = 'REFUSE'
      $why = if ($route) { 'was on its bid, now routes to ' + $route } else { 'was on its bid, now routes to no weekly commodity' }
    } elseif ($was.kind -eq 'UNROUTED' -and $x.kind -eq 'PROXY') {
      $verdict = 'REFUSE'; $why = 'was unrouted, now routes to ' + $route + ' (a commodity now claims this name)'
    } elseif ($was.kind -eq 'PROXY' -and $x.kind -eq 'PROXY' -and $was.hit -ne $route) {
      $verdict = 'REFUSE'; $why = 'routed to ' + $was.hit + ', now routes to ' + $route
    } elseif ($was.kind -eq 'PROXY' -and $x.kind -eq 'UNROUTED') {
      $verdict = 'SPEAK'; $why = 'routed to ' + $was.hit + ', now routes nowhere'
    }
    if (-not $verdict) { continue }
    $detail = '"' + $item + '" bid ' + $bid + ': ' + $why + $(if ($verdict -eq 'REFUSE') { '. Repair: ' + $fix } else { '' })
    [void]$out.Add([pscustomobject]@{ verdict = $verdict; item = $item; bid = $bid; route = $route; detail = $detail })
  }
  return $out.ToArray()
}
