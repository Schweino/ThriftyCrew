<#
  rollback-ttl-lib.ps1 - the durable "when did we FIRST see this rollback?" ledger.

  BRAD'S RULE (2026-08-21): "for walmart and sams, a rollback price we just stick with a 30 day TTL
  from when we first detect".

  THE WHOLE DIFFICULTY IS IN THE WORD *FIRST*. Walmart and Sam's publish no end date for a rollback -
  measured 2026-08-21: Walmart's ROLLBACK badge carries __typename/key/text/type/id/styleId and
  nothing temporal, promoData is Affirm financing only, promoDiscount is null; Sam's payload contains
  zero date-shaped values at all. So the window has to come from us, and the only honest anchor is the
  first day we observed it.

  IF THE ANCHOR MOVES, THE TTL IS INFINITE. A rollback is re-observed on every capture that covers its
  term. Stamping "today + 30" each time an observation lands would push the expiry forward forever and
  the price would never revert - a 30-day rule that silently means "never", which is strictly worse
  than no rule because it reads as governed. So first_seen is written ONCE per (store, item) and is
  NEVER advanced; only last_seen moves. That is the same discipline as `dates written, not measured`
  and as the FF cursor-commit rule: the durable fact is recorded when it happens and is not re-derived
  from the clock afterwards.

  KEYED BY THE STORE'S OWN ITEM ID, not the product name. A name changes when the merchant re-lists or
  re-titles an item and a name-keyed ledger would silently mint a new first_seen and restart the
  clock - the re-listing escape that `a ruling a store can escape by re-listing is not a ruling`
  describes. Walmart gives usItemId, Sam's gives productId; both are already captured.

  THE PRICE IS PART OF THE IDENTITY OF A ROLLBACK. If the rolled-back price CHANGES, that is a new
  rollback, not a continuation of the old one, and it earns a fresh 30 days. A store that cuts $5.96
  to $4.87 and later to $3.99 has run two promotions; carrying the first anchor forward would expire
  the second one early. Recorded as price_changed in the ledger so the reason is visible.

  DETECTION IS THE CAPTURE, NOT THE LEDGER (Brad, 2026-08-22). "30 days from when we first detect" means
  the day the store's feed first SHOWED the cut price - the row's as_of - not the day this ledger first
  processed the row. Pass -AsOf; the anchor is min(as_of, today). first_seen still never advances on a
  re-observation; it may move EARLIER when a capture proves the price was already there.

  Usage:
      . rollback-ttl-lib.ps1
      $w = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 4.87 -Today '2026-08-21' -AsOf '2026-08-11'
      # -> @{ ad_from = '2026-08-11'; ad_to = '2026-09-10'; first_seen = '2026-08-11'; is_new = $true }
      Save-RollbackLedger        # once, after a build, to persist what the run observed
#>

# The TTL itself. Brad's number, and it is a POLICY value rather than a measurement: neither store
# publishes a window, so this is the length we are choosing to stand behind, not one they gave us.
# Kept here beside the ledger it governs so the two can never disagree.
$script:RollbackTtlDays = 30

# Which stores this applies to. A store that PUBLISHES a window must never be given a TTL instead -
# Baker's states expirationDate per item and Family Fare states finish_date per offer, and inventing
# a 30-day guess over either would be replacing a fact with a worse one.
# FAREWAY JOINED THIS LIST 2026-08-21, on Brad's rule: "if product page shows a sale price, but it
# doesn't match a weekly or monthly ad, give it a 30 day TTL." It is the store with by far the most
# undated sales - 178 cells after ad-matching had already dated everything it could - and its own
# storefront publishes no end date for them (itemPromotions empty, secondaryPromotion null,
# promotionGroupId null, and on_sale_ind reports retailer:false, i.e. not a retailer promotion).
# ORDER MATTERS AND IS ENFORCED BY THE CALLER: a TTL is the LAST resort. A cell is dated by the
# store's own feed if it can be, then by the ad it was traced to, and only then by this. Fareway also
# states "Sale ends in N days" in saleDisclaimerString on SOME items; where that is captured it is a
# real date and must beat this guess.
$script:RollbackTtlStores = @('Walmart', "Sam's Club", 'Fareway')

$script:RbLedger = $null
$script:RbLedgerPath = $null
$script:RbDirty = $false

function Get-RollbackLedgerPath([string]$Root) {
  if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' } }
  return (Join-Path $Root 'rollback-first-seen.json')
}

function Import-RollbackLedger([string]$Root = '') {
  if ($null -ne $script:RbLedger) { return }
  $script:RbLedgerPath = Get-RollbackLedgerPath $Root
  $script:RbLedger = @{}
  if (Test-Path $script:RbLedgerPath) {
    try {
      $doc = ConvertFrom-Json ([IO.File]::ReadAllText($script:RbLedgerPath))
      foreach ($e in @($doc.entries)) {
        $script:RbLedger[[string]$e.key] = [ordered]@{
          store = [string]$e.store; item_id = [string]$e.item_id
          price = [double]$e.price; first_seen = [string]$e.first_seen
          last_seen = [string]$e.last_seen; price_changed = [int]$e.price_changed
        }
      }
    } catch { }
  }
}

function Test-RollbackTtlStore([string]$Store) { return ($script:RollbackTtlStores -contains $Store) }
function Get-RollbackTtlDays { return $script:RollbackTtlDays }

function Get-RollbackWindow {
  <#
    .SYNOPSIS The window for one observed rollback, anchored to the day we FIRST saw it.
    .DESCRIPTION Returns $null for a store that publishes its own dates - the caller must use those.
                 Pure apart from the in-memory ledger; call Save-RollbackLedger to persist.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Store,
    # NOT Mandatory, deliberately. A row with no item id must come back as $null - "we cannot anchor
    # this honestly" - not as a parameter-binding crash. Mandatory rejects '' at the binder, before
    # the guard below can give that answer, which turns a legitimate no-op into a failed build.
    [string]$ItemId = '',
    [Parameter(Mandatory)][double]$Price,
    [string]$Today = '',
    [string]$Root = '',
    # THE DAY THE CAPTURE SHOWED THIS PRICE (the row's as_of), which is NOT the day the ledger met it.
    # BRAD'S RULING (2026-08-22): the TTL is 30 days FROM DETECTION, and detection is the capture that
    # first showed the discounted price. The ledger was born on 2026-08-21 and stamped every one of its
    # 368 entries with that day, while the rows it was reading carried as_of dates back to 2026-07-14 -
    # a rollback captured five weeks earlier was handed a fresh 30 days on the day the bookkeeping
    # started. Anchoring to min(as_of, today) makes the anchor a fact about the STORE, not about us.
    [string]$AsOf = ''
  )
  if (-not (Test-RollbackTtlStore $Store)) { return $null }
  if (-not $ItemId) { return $null }        # no stable key -> no honest anchor -> no window
  Import-RollbackLedger $Root
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  # The honest anchor: the capture date when it is a real date and not in the future; otherwise today.
  # A future as_of is a clock or file-naming fault, and must not start a window that has not opened.
  $anchor = $todayS
  if ($AsOf -match '^\d{4}-\d{2}-\d{2}$' -and $AsOf -lt $todayS) { $anchor = $AsOf }
  $key = "$Store|$ItemId"

  $e = $script:RbLedger[$key]
  $isNew = $false
  if (-not $e) {
    $e = [ordered]@{ store = $Store; item_id = $ItemId; price = $Price; first_seen = $anchor; last_seen = $todayS; price_changed = 0 }
    $script:RbLedger[$key] = $e; $script:RbDirty = $true; $isNew = $true
  }
  elseif ([math]::Abs([double]$e.price - $Price) -gt 0.005) {
    # A DIFFERENT ROLLED-BACK PRICE IS A DIFFERENT PROMOTION. Re-anchor and say so.
    $e.price = $Price; $e.first_seen = $anchor; $e.price_changed = [int]$e.price_changed + 1
    $e.last_seen = $todayS; $script:RbDirty = $true; $isNew = $true
  }
  else {
    # SAME ROLLBACK, SEEN AGAIN. last_seen moves; first_seen MUST NOT ADVANCE - that is the whole rule.
    if ([string]$e.last_seen -ne $todayS) { $e.last_seen = $todayS; $script:RbDirty = $true }
    # ...but it MAY move BACKWARD, to a capture that provably showed this price earlier than the ledger
    # knew. Earlier is the safe direction: it can only shorten the window, never extend it, so the
    # infinite-TTL failure this file exists to prevent cannot arrive through it.
    if ($anchor -lt [string]$e.first_seen) { $e.first_seen = $anchor; $script:RbDirty = $true }
  }

  $from = [string]$e.first_seen
  $to = ''
  try { $to = ([datetime]::ParseExact($from, 'yyyy-MM-dd', $null)).AddDays($script:RollbackTtlDays).ToString('yyyy-MM-dd') } catch { }
  return [ordered]@{
    ad_from = $from; ad_to = $to; first_seen = $from; last_seen = [string]$e.last_seen
    is_new = $isNew; ttl_days = $script:RollbackTtlDays
    basis = "TTL - neither store publishes a rollback end date; anchored to first detection (the capture's as_of)"
  }
}

function Save-RollbackLedger([string]$Root = '') {
  if ($null -eq $script:RbLedger) { return $false }
  if (-not $script:RbDirty) { return $true }
  if (-not $script:RbLedgerPath) { $script:RbLedgerPath = Get-RollbackLedgerPath $Root }
  $doc = [ordered]@{
    updated = (Get-Date).ToString('s')
    ttl_days = $script:RollbackTtlDays
    note = 'When each Walmart / Sam''s / Fareway rollback was FIRST observed. first_seen is the as_of of the capture that first showed the cut price (detection = the capture, not the day this ledger met the row - Brad, 2026-08-22) and is NEVER advanced - re-observing a rollback moves last_seen only, because an anchor that moves makes a 30-day TTL infinite; it may move EARLIER when a capture proves the price was already there. A CHANGED rolled-back price is a new promotion and re-anchors, counted in price_changed. Keyed by the store''s own item id, never the name, so a re-listing cannot restart the clock.'
    entries = @($script:RbLedger.Keys | Sort-Object | ForEach-Object {
      $v = $script:RbLedger[$_]
      [ordered]@{ key = $_; store = $v.store; item_id = $v.item_id; price = $v.price
                  first_seen = $v.first_seen; last_seen = $v.last_seen; price_changed = $v.price_changed }
    })
  }
  $tmp = "$($script:RbLedgerPath).tmp"
  [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $script:RbLedgerPath -Force
  $script:RbDirty = $false
  return $true
}
