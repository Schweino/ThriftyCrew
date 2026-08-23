# carriage-lib.ps1 - THE one derivation of "does any Omaha store carry this food?"
#
# WHY THIS EXISTS (2026-08-22). Four live paid recipes were found whose defining ingredient no Omaha
# store is known to carry (doubanjiang x3, Korean rice cakes x1). The rule - one uncarried ingredient
# and we cannot use the recipe - was already implemented in grocery\ingredient-queue.ps1 (Rule B) and
# read by hunt-run.ps1. It was never shown these ingredients, because every gate in the estate was
# answering a DIFFERENT question:
#
#   CARRIAGE - does any Omaha store stock this food?          <- Brad's rule. A store-evidence fact.
#   PRICING  - does our board have a matched price for it?    <- a matcher fact.
#
# Those are not the same. ground-sumac is CARRIED (Baker's stocks it) but UNPRICED (the matcher never
# lands it in the feed) - legitimate, and it must not take a recipe down. doubanjiang was UNPRICED
# because it was never found - and it must. Because nothing separated the two, db\no-board-price-ok.json
# ("may this bid skip board pricing?") was silently also answering "is this carried?", and cost-recipes
# flagged 'MAPPED BID NOT ON ANY BOARD' and then priced the line from a hard-coded label on the very
# next statement.
#
# THE PRINCIPLE: carriage is a fact about a commodity, proven by EVIDENCE, never by EXISTENCE.
# The existence of a commodity id, an ingredient-map row, or a label price proves nothing about a shelf.
#
# EVERY gate calls THIS function. A second implementation is how the two questions got confused the
# first time.
#
# THE VERDICTS:
#   CARRIED      >=1 real store price in the live feed, OR an adjudicated ledger entry with evidence.
#   NOT-CARRIED  a ledger entry recording all seven stores CHECKED (not blocked, not errored) and none
#                carrying it. Rule B, same as ingredient-queue.ps1.
#   UNKNOWN      anything else. NOT a synonym for NOT-CARRIED - see below.
#
# UNKNOWN IS NOT NOT-CARRIED. Every "absence" this estate has ever found was a wrong search term:
# doubanjiang was searched as "chili bean sauce" (237 rows of Bush's chili beans, zero doubanjiang) and
# Korean rice cakes as "rice cakes" (650 Quaker snack rows, zero tteok). A store that was never asked
# the right question has not answered it. Callers decide what to do with UNKNOWN; this library only
# refuses to call it proof.

$script:CARRIAGE_STORES = @('Walmart', "Sam's Club", 'Aldi', "Baker's", 'Family Fare', 'Fareway', 'Hy-Vee')

# A store only counts as CHECKED when it actually answered. A bot wall, a timeout, a wrong-store session
# or a store nobody reached is not evidence of absence - the same distinction ingredient-queue.ps1 makes,
# and the reason its self-test asserts "six not-carried + one unchecked must be PENDING".
$script:CARRIAGE_CHECKED_STATES = @('carried', 'not-carried')

# ---------------------------------------------------------------------------------------------------
# THE KEY. A commodity id when the ingredient has one; otherwise the item name.
#
# Bid-less items are NOT an edge case: 'Keto Bun' and 'Korean Rice Cakes' both carry bid=null in
# db\ingredients.json, and Korean Rice Cakes is one of the four recipes that got through. An ingredient
# with no commodity id is precisely the one no board gate can see, so it needs a carriage key most.
# ---------------------------------------------------------------------------------------------------
function Get-CarriageKey {
  param([string]$Bid, [string]$Item)
  if ($Bid) { return [string]$Bid }
  if ($Item) { return ('item:' + [string]$Item) }
  return $null
}

# basis -> bid. 'board:<id>:<src>' and 'feed:<id>' carry one; 'label:<desc>' does not.
# The '+drained' suffix is appended AFTER the price lookup (cost-recipes.ps1), so it must be stripped
# before any bid comparison - reading it as part of the id is how 'cannellini-beans+drained' looked
# absent from the feed in the 2026-08-22 audit.
function Get-BidFromBasis {
  param([string]$Basis)
  if (-not $Basis) { return $null }
  $b = [string]$Basis
  $plus = $b.IndexOf('+')
  if ($plus -ge 0) { $b = $b.Substring(0, $plus) }
  if ($b -like 'board:*') { return ($b -split ':')[1] }
  if ($b -like 'feed:*')  { return ($b -split ':')[1] }
  return $null
}

# ---------------------------------------------------------------------------------------------------
# THE FEED TIER. Automatic, covers 273 of the 275 bids in live use with no human in the loop.
#
# Feed rows are trustworthy because they have already passed the matcher's include/exclude rules. RAW
# CAPTURE ROWS ARE NOT AND MUST NEVER BE USED HERE: found_by_term proves only that a search returned
# SOMETHING. Searching "chili bean sauce" returned 237 rows - every one of them chili beans. Raw
# captures are hints for a human pricer to adjudicate, never a verdict.
# ---------------------------------------------------------------------------------------------------
function Get-FeedCarriedSet {
  param($FeedIngredients)
  $set = @{}
  if (-not $FeedIngredients) { return $set }
  foreach ($p in $FeedIngredients.PSObject.Properties) {
    $v = $p.Value
    $carried = $false
    if ($v.PSObject.Properties.Name -contains 'stores' -and $v.stores) {
      foreach ($s in $v.stores.PSObject.Properties) { if ([double]$s.Value -gt 0) { $carried = $true; break } }
    }
    if (-not $carried -and ($v.PSObject.Properties.Name -contains 'cheapest') -and [double]$v.cheapest -gt 0) { $carried = $true }
    if ($carried) { $set[[string]$p.Name] = $true }
  }
  return $set
}

function Import-CarriageLedger {
  param([string]$Path)
  $led = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $led }
  $doc = Get-Content $Path -Raw | ConvertFrom-Json
  if (-not $doc -or -not ($doc.PSObject.Properties.Name -contains 'bids')) { return $led }
  foreach ($p in $doc.bids.PSObject.Properties) { $led[[string]$p.Name] = $p.Value }
  return $led
}

# A ledger entry only means what its evidence supports. An unsupported claim degrades to UNKNOWN rather
# than being honoured - a ledger anyone can hand-edit into a pardon is not a gate.
function Test-CarriageEvidence {
  param($Entry)
  if (-not $Entry) { return @{ ok = $false; why = 'no entry' } }
  $v = [string]$Entry.verdict
  if ($v -eq 'CARRIED') {
    if (-not $Entry.store)  { return @{ ok = $false; why = 'CARRIED without a store' } }
    if (-not $Entry.item)   { return @{ ok = $false; why = 'CARRIED without a product name' } }
    if (-not $Entry.as_of)  { return @{ ok = $false; why = 'CARRIED without a date' } }
    if ($null -eq $Entry.price -or [double]$Entry.price -le 0) { return @{ ok = $false; why = 'CARRIED without a price' } }
    return @{ ok = $true; why = '' }
  }
  if ($v -eq 'NOT-CARRIED') {
    # RULE B. Every one of the seven must have ANSWERED. Anything less is PENDING/UNKNOWN, never absence.
    if (-not $Entry.stores) { return @{ ok = $false; why = 'NOT-CARRIED without per-store evidence' } }
    $checked = @()
    foreach ($s in $Entry.stores.PSObject.Properties) {
      if ($script:CARRIAGE_CHECKED_STATES -contains ([string]$s.Value.state)) { $checked += $s.Name }
      if ([string]$s.Value.state -eq 'carried') { return @{ ok = $false; why = ('NOT-CARRIED but ' + $s.Name + ' is recorded carried') } }
    }
    $missing = @($script:CARRIAGE_STORES | Where-Object { $checked -notcontains $_ })
    if ($missing.Count) { return @{ ok = $false; why = ('only ' + $checked.Count + '/7 stores answered; missing ' + ($missing -join ', ')) } }
    # A verdict of absence that only ever tried one spelling is the doubanjiang failure exactly.
    $tried = 0
    foreach ($s in $Entry.stores.PSObject.Properties) { if ($s.Value.terms_tried) { $tried += @($s.Value.terms_tried).Count } }
    if ($tried -lt 1) { return @{ ok = $false; why = 'NOT-CARRIED without recording any search term tried' } }
    return @{ ok = $true; why = '' }
  }
  return @{ ok = $false; why = ('unrecognised verdict "' + $v + '"') }
}

# ---------------------------------------------------------------------------------------------------
# THE DERIVATION. Feed first (automatic, cheap, already matched), then the adjudicated ledger.
# ---------------------------------------------------------------------------------------------------
function Get-Carriage {
  param([string]$Bid, [string]$Item, $FeedCarried, $Ledger)
  $key = Get-CarriageKey -Bid $Bid -Item $Item
  if (-not $key) { return [pscustomobject]@{ verdict = 'UNKNOWN'; source = 'none'; key = $null; why = 'no bid and no item name' } }

  if ($Bid -and $FeedCarried -and $FeedCarried.ContainsKey([string]$Bid)) {
    return [pscustomobject]@{ verdict = 'CARRIED'; source = 'feed'; key = $key; why = 'priced by >=1 store in the live feed' }
  }
  if ($Ledger -and $Ledger.ContainsKey($key)) {
    $e = $Ledger[$key]
    # An explicit UNKNOWN is a first-class record, not a missing one: it is where the history of a failed
    # search lives (doubanjiang was hunted as "chili bean sauce" and never found). Keeping it in the
    # ledger is what stops the next run repeating the same wrong term and calling the silence an answer.
    if ([string]$e.verdict -eq 'UNKNOWN') {
      return [pscustomobject]@{ verdict = 'UNKNOWN'; source = 'ledger'; key = $key; why = ([string]$e.why) }
    }
    $ev = Test-CarriageEvidence -Entry $e
    if ($ev.ok) {
      return [pscustomobject]@{ verdict = [string]$e.verdict; source = 'ledger'; key = $key
                                why = ([string]$e.why) }
    }
    return [pscustomobject]@{ verdict = 'UNKNOWN'; source = 'ledger-insufficient'; key = $key
                              why = ('ledger says ' + [string]$e.verdict + ' but ' + $ev.why) }
  }
  return [pscustomobject]@{ verdict = 'UNKNOWN'; source = 'none'; key = $key; why = 'no feed price and no ledger entry' }
}

# Convenience for the gates: carriage for one costed LINE. Prefers the item row's bid (which exists even
# when the line ended up label-priced - that is the whole sumac case) and falls back to the basis.
function Get-LineCarriage {
  param($Line, $ItemBids, $FeedCarried, $Ledger)
  $item = [string]$Line.item
  $bid = $null
  if ($ItemBids -and $ItemBids.ContainsKey($item)) { $bid = [string]$ItemBids[$item] }
  if (-not $bid) { $bid = Get-BidFromBasis ([string]$Line.basis) }
  return Get-Carriage -Bid $bid -Item $item -FeedCarried $FeedCarried -Ledger $Ledger
}

function Invoke-CarriageLibSelfTest {
  $bad = 0
  function TT([string]$n, [bool]$ok, [string]$got) { if ($ok) { Write-Output "  ok  $n" } else { Write-Output "  X   $n  ($got)"; $script:__cbad++ } }
  $script:__cbad = 0

  $feedDoc = [pscustomobject]@{
    'chicken-breast' = [pscustomobject]@{ cheapest = 2.5; stores = [pscustomobject]@{ 'Walmart' = 2.5; 'Aldi' = 2.7 } }
    'dead-bid'       = [pscustomobject]@{ cheapest = 0;   stores = [pscustomobject]@{ 'Walmart' = 0 } }
  }
  $fc = Get-FeedCarriedSet $feedDoc
  TT 'feed with a real price is CARRIED' ((Get-Carriage -Bid 'chicken-breast' -Item 'Chicken Breast' -FeedCarried $fc -Ledger @{}).verdict -eq 'CARRIED') 'not carried'
  TT 'feed row with no price is not CARRIED' ((Get-Carriage -Bid 'dead-bid' -Item 'X' -FeedCarried $fc -Ledger @{}).verdict -eq 'UNKNOWN') 'not unknown'
  TT 'a bid nobody has heard of is UNKNOWN, never NOT-CARRIED' ((Get-Carriage -Bid 'doubanjiang' -Item 'Doubanjiang' -FeedCarried $fc -Ledger @{}).verdict -eq 'UNKNOWN') 'not unknown'

  # basis parsing
  TT 'board basis yields its bid'  ((Get-BidFromBasis 'board:pork-loin:recipeboard-walmart') -eq 'pork-loin') 'wrong'
  TT 'feed basis yields its bid'   ((Get-BidFromBasis 'feed:penne-pasta') -eq 'penne-pasta') 'wrong'
  TT 'label basis yields no bid'   ($null -eq (Get-BidFromBasis 'label:The Spice Way 8 oz')) 'wrong'
  TT '+drained is stripped'        ((Get-BidFromBasis 'feed:cannellini-beans+drained') -eq 'cannellini-beans') 'wrong'

  # bid-less items key by name - the Korean Rice Cakes / Keto Bun case
  TT 'a bid-less item still gets a key' ((Get-CarriageKey -Bid $null -Item 'Keto Bun') -eq 'item:Keto Bun') 'wrong key'
  $led = @{ 'item:Keto Bun' = [pscustomobject]@{ verdict='CARRIED'; store='Walmart'; item='bettergoods Keto Friendly Hamburger Buns 14 oz 8 ct'; price=4.78; as_of='2026-08-01'; why='captured 3x' } }
  TT 'a bid-less item can be CARRIED by the ledger' ((Get-Carriage -Bid $null -Item 'Keto Bun' -FeedCarried $fc -Ledger $led).verdict -eq 'CARRIED') 'not carried'

  # ledger evidence bar
  $weak = @{ 'x-bid' = [pscustomobject]@{ verdict='CARRIED'; store='Walmart' } }
  TT 'MUST FIRE  CARRIED with no price/product/date degrades to UNKNOWN' ((Get-Carriage -Bid 'x-bid' -Item 'X' -FeedCarried $fc -Ledger $weak).verdict -eq 'UNKNOWN') 'honoured a bare claim'

  function New-Stores([hashtable]$m) {
    $o = [pscustomobject]@{}
    foreach ($k in $m.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{ state = $m[$k]; terms_tried = @('t') }) }
    return $o
  }
  $all7 = @{}; foreach ($s in $script:CARRIAGE_STORES) { $all7[$s] = 'not-carried' }
  $good = @{ 'gone-bid' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = (New-Stores $all7) } }
  TT 'all seven answered none carrying is NOT-CARRIED' ((Get-Carriage -Bid 'gone-bid' -Item 'G' -FeedCarried $fc -Ledger $good).verdict -eq 'NOT-CARRIED') 'not not-carried'

  $six = $all7.Clone(); $six["Hy-Vee"] = 'blocked'
  $blocked = @{ 'gone-bid' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = (New-Stores $six) } }
  TT 'MUST FIRE  six not-carried + one BLOCKED is UNKNOWN, never NOT-CARRIED' ((Get-Carriage -Bid 'gone-bid' -Item 'G' -FeedCarried $fc -Ledger $blocked).verdict -eq 'UNKNOWN') 'called a bot wall an absence'

  $six2 = $all7.Clone(); $six2["Fareway"] = 'error'
  $errd = @{ 'gone-bid' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = (New-Stores $six2) } }
  TT 'MUST FIRE  an errored store does not count as checked' ((Get-Carriage -Bid 'gone-bid' -Item 'G' -FeedCarried $fc -Ledger $errd).verdict -eq 'UNKNOWN') 'called an error an absence'

  $contra = $all7.Clone(); $contra['Aldi'] = 'carried'
  $cont = @{ 'gone-bid' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = (New-Stores $contra) } }
  TT 'MUST FIRE  NOT-CARRIED contradicted by a carried store degrades' ((Get-Carriage -Bid 'gone-bid' -Item 'G' -FeedCarried $fc -Ledger $cont).verdict -eq 'UNKNOWN') 'honoured a self-contradiction'

  $noTerms = [pscustomobject]@{}
  foreach ($s in $script:CARRIAGE_STORES) { $noTerms | Add-Member -NotePropertyName $s -NotePropertyValue ([pscustomobject]@{ state = 'not-carried' }) }
  $nt = @{ 'gone-bid' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = $noTerms } }
  TT 'MUST FIRE  NOT-CARRIED with no term ever tried degrades' ((Get-Carriage -Bid 'gone-bid' -Item 'G' -FeedCarried $fc -Ledger $nt).verdict -eq 'UNKNOWN') 'honoured a termless absence'

  # the feed wins over a stale ledger absence: this is the revival path
  $stale = @{ 'chicken-breast' = [pscustomobject]@{ verdict='NOT-CARRIED'; stores = (New-Stores $all7) } }
  TT 'a live feed price overrides a stale NOT-CARRIED' ((Get-Carriage -Bid 'chicken-breast' -Item 'C' -FeedCarried $fc -Ledger $stale).verdict -eq 'CARRIED') 'stale absence won'

  # line-level resolution: sumac is label-priced but its ITEM ROW has the bid
  $itemBids = @{ 'Sumac' = 'ground-sumac' }
  $sumacLed = @{ 'ground-sumac' = [pscustomobject]@{ verdict='CARRIED'; store="Baker's"; item='Morton & Bassett All Natural Sumac'; price=12.79; as_of='2026-08-22' } }
  $line = [pscustomobject]@{ item='Sumac'; basis='label:The Spice Way 8 oz' }
  TT 'a label-priced line is judged by its item row bid' ((Get-LineCarriage -Line $line -ItemBids $itemBids -FeedCarried $fc -Ledger $sumacLed).verdict -eq 'CARRIED') 'label line not resolved'

  Write-Output ("carriage-lib self-test: " + $(if ($script:__cbad -eq 0) { 'ALL PASS' } else { "$($script:__cbad) FAILED" }))
  return $script:__cbad
}
