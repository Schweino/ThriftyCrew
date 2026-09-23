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

function Get-IdentityTokens {
  param([string]$Text)
  if (-not $Text) { return @() }
  $t = ($Text.ToLower() -replace '[^a-z0-9 ]', ' ')
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
  $joined = (([string]$ProductName).ToLower() -replace '[^a-z0-9]', '')
  return ($ask.Length -ge 5 -and $joined.Contains($ask))
}

function ConvertTo-IdentityStoreKey { param([string]$S) return (([string]$S).ToLower() -replace '[^a-z0-9]', '') }

function Get-IdentityBoardIndex {
  <# id -> (store key -> product name) over a comparison board's rows. #>
  param($Board)
  $ix = @{}
  foreach ($r in @($Board.comparison)) {
    $m = @{}
    foreach ($s in @($r.stores)) {
      $nm = [string]$s.item; if (-not $nm) { $nm = [string]$s.name }
      $m[(ConvertTo-IdentityStoreKey ([string]$s.store))] = $nm
    }
    $ix[[string]$r.id] = [pscustomobject]@{ stores = $m; crown_store = [string]$r.cheapest_store }
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
  <# Every finding over the vocabulary, the live rules and (optionally) the newest board and costed lines.
     $Resolve is a scriptblock name -> commodity id or $null (the live matcher in production, a frozen one in
     the self-test). $WeeklyIds is the set of ids the weekly rules can route to. Returns objects with a stable
     `key` (what the ratchet counts), `kind`, `item` and `detail`. #>
  param($Rows, [scriptblock]$Resolve, $WeeklyIds, $BoardIndex = $null, $Costed = $null)
  $out = New-Object System.Collections.ArrayList
  $byItem = @{}
  foreach ($r in @($Rows)) {
    if (-not $r.PSObject.Properties['item']) { continue }
    $item = [string]$r.item; $byItem[$item] = $r
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
  if ($null -ne $BoardIndex -and $null -ne $Costed) {
    foreach ($rec in @($Costed)) {
      foreach ($ln in @($rec.lines)) {
        $basis = [string]$ln.basis
        if ($basis -notmatch '^board:([^:]+):(.+)$') { continue }
        $id = $Matches[1]; $sk = ConvertTo-IdentityStoreKey $Matches[2]
        $prod = Find-IdentityBoardProduct $BoardIndex $id $sk
        if (-not $prod) { continue }
        $row = $byItem[[string]$ln.item]
        $rel = if ($row) { Get-IdentityRelation $row } else { 'same' }
        if ($row -and $null -ne $row.PSObject.Properties['identity_reviewed'] -and [string]$row.identity_reviewed -ne '') { continue }
        if (-not (Test-PricingRowNamesIngredient -Ingredient ([string]$ln.item) -ProductName $prod -Relation $rel -Bid $id)) {
          [void]$out.Add([pscustomobject]@{ key = ('union|' + [string]$rec.slug + '|' + [string]$ln.item + '|' + $id); kind = 'UNION-ROW'; item = [string]$ln.item; detail = ([string]$rec.slug + ': "' + [string]$ln.item + '" is priced by "' + $prod + '" (' + $basis + '), which does not name ' + (Get-IdentityHeadWord ([string]$ln.item))) })
        }
      }
    }
  }
  return $out.ToArray()
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
